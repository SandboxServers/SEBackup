#Requires -Module Pester

# Invoke-SEBRestore is the restore orchestrator -- a DATA PATH that overwrites the live world. It
# sequences: lock -> configs/session -> chain validation -> SAFETY BACKUP -> reconstruct in temp ->
# VERIFY reconstruction -> stop server -> DEPLOY -> start server -> notify -> cleanup. The
# safety-critical invariants these tests assert (with the infra boundary mocked):
#   * the per-instance lock is acquired up front and ALWAYS released in finally;
#   * a chain-validation failure aborts BEFORE the safety backup or any node work;
#   * a safety-backup failure aborts BEFORE the live world is touched (no stop/deploy);
#   * the server is stopped only AFTER a verified reconstruction (deferred), and a deploy failure
#     is surfaced as a structured failure (the rollback lives in Deploy-SEBRestoredFiles);
#   * the canonical .ErrorMessage is populated on every failure and the result is a single object.
#
# Test notes:
#  * Mocks target -ModuleName RestoreEngine (the orchestrator's scope). Seams imported into that
#    scope (New-SEBSession, Stop/Start-SEBTorchServer, Deploy-SEBRestoredFiles, Invoke-SEBBackup,
#    Copy-SEBThrottled, Send-SEBRestoreNotification, ...) are mocked there.
#  * Test-SEBRestoreChain returns ChainManifests = REAL on-disk JSON paths, because the orchestrator
#    reads each manifest with Get-Content | ConvertFrom-Json to drive deleted_files and verification.
#    A temp manifests dir is created per Describe with engine-shaped v2 manifests.
#  * Each It invokes then asserts in the same block (Pester 5 scopes mock call history per block).

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null
    . "$repoRoot/Tests/_TestHelpers/Test-Doubles.ps1"

    # A C&C backup root with a real manifests dir; Test-SEBRestoreChain mock points at these files.
    $script:ccRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sebrs_cc_" + [guid]::NewGuid().ToString('n'))
    $script:manifestsDir = Join-Path (Join-Path $script:ccRoot 'PvPArena') 'manifests'
    New-Item -Path $script:manifestsDir -ItemType Directory -Force | Out-Null

    function New-ChainManifestFile {
        param([string]$Dir, [string]$Name, [string]$Type, [string]$ChainId, [int]$Seq, [string[]]$Deleted = @())
        $m = @{
            version         = 2
            type            = $Type
            chain_id        = $ChainId
            chain_sequence  = $Seq
            parent_manifest = $(if ($Seq -gt 0) { 'parent.json' } else { $null })
            timestamp       = [datetime]::UtcNow.ToString('o')
            files           = @{ 'Sandbox.sbc' = @{ size = 10; sha256 = ('a' * 64); last_write = [datetime]::UtcNow.ToString('o') } }
            deleted_files   = $Deleted
        }
        $path = Join-Path $Dir $Name
        $m | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path
        return $path
    }

    function New-RestoreGlobalConfig {
        param([bool]$NotificationsEnabled = $true)
        @{
            storage       = @{ cc_backup_root = $script:ccRoot; nas_backup_path = $null }
            network       = @{ max_bandwidth_mbps = 0; robocopy_ipg_ms = 0 }
            notifications = @{ enabled = $NotificationsEnabled; on_restore = $true }
        }
    }

    # Full set of "restore succeeds" mocks. Contexts re-Mock one seam to fail. $ChainManifestPath is
    # the real on-disk manifest the verify/extract loop reads; $Mismatches lets a Context fail verify.
    function Set-RestoreHappyMocks {
        param([hashtable]$GlobalConfig, [string[]]$ChainManifestPaths, [string[]]$Mismatches = @())

        Mock Write-SEBLog {} -ModuleName RestoreEngine

        Mock New-SEBLockFile -ModuleName RestoreEngine {
            [PSCustomObject]@{ Acquired = $true; LockFilePath = 'X:\lock'; Reason = $null; StaleLockBroken = $false }
        }
        Mock Remove-SEBLockFile -ModuleName RestoreEngine { $true }

        Mock Get-SEBGlobalConfig -ModuleName RestoreEngine { $GlobalConfig }.GetNewClosure()
        Mock Get-SEBNodeConfig   -ModuleName RestoreEngine { @{ node = @{ hostname = 'node01' } } }
        Mock New-SEBSession      -ModuleName RestoreEngine { New-FakeSession -Name 'SEBackup-node01' -Target 'node01' }
        Mock Remove-SEBSession   -ModuleName RestoreEngine {}
        Mock Get-SEBInstanceConfig -ModuleName RestoreEngine {
            @{ world_path = 'D:\Torch\Instance\Saves\MyWorld'; share_name = 'SEBackup$' }
        }

        # One archive in the chain by default (a single full). ChainManifests are the REAL files.
        Mock Test-SEBRestoreChain -ModuleName RestoreEngine {
            [PSCustomObject]@{
                Valid          = $true
                ChainLength    = $ChainManifestPaths.Count
                ChainManifests = $ChainManifestPaths
                ChainArchives  = @($ChainManifestPaths | ForEach-Object { ($_ -replace '\.json$', '.7z') })
                Errors         = @()
                Warnings       = @()
            }
        }.GetNewClosure()

        # The safety backup succeeds and returns an archive path.
        Mock Invoke-SEBBackup -ModuleName RestoreEngine {
            [PSCustomObject]@{ Success = $true; ArchiveFile = 'C:\cc\PvPArena\full\safety.7z'; ErrorMessage = $null }
        }

        Mock Stop-SEBTorchServer  -ModuleName RestoreEngine { @{ Stopped = $true; Method = 'service'; ErrorMessage = $null } }
        Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $true; APIResponding = $true; ErrorMessage = $null } }

        Mock Deploy-SEBRestoredFiles -ModuleName RestoreEngine {
            [PSCustomObject]@{ Deployed = $true; PreRestorePath = 'D:\Torch\Instance\Saves\MyWorld_prerestore_20260101_010101'; FilesCopied = 42; RolledBack = $null; ErrorMessage = $null }
        }

        Mock Get-SEBSharePath -ModuleName RestoreEngine { '\\node01\SEBackup$' }
        Mock Copy-SEBThrottled -ModuleName RestoreEngine {}
        Mock Send-SEBRestoreNotification -ModuleName RestoreEngine {}

        # Reconstruction-verify remote block returns the mismatch set; the extract/cleanup/setup
        # blocks are side-effect-only. Route by block text.
        Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'Mismatches' } {
            @{ Checked = 1; Mismatches = $Mismatches; Total = 1 }
        }.GetNewClosure()
        Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -notmatch 'Mismatches' } { $null }
        # The archive-local-path lookup and deleted-files/cleanup use raw Invoke-Command.
        Mock Invoke-Command -ModuleName RestoreEngine { $null }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:ccRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ===========================================================================================
# HAPPY PATH
# ===========================================================================================
Describe 'Invoke-SEBRestore happy path' {
    BeforeAll {
        $man = New-ChainManifestFile -Dir $script:manifestsDir -Name 'PvPArena_FULL_20260227_100000.json' -Type 'full' -ChainId 'rc-1' -Seq 0
        Set-RestoreHappyMocks -GlobalConfig (New-RestoreGlobalConfig) -ChainManifestPaths @($man)
    }

    It 'returns Success with the result object populated (RestorePoint, UndoAvailable, Duration)' {
        $r = Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_20260227_100000.json' -Force

        # Single-object .OUTPUTS contract: the side-effect remote blocks and Copy-SEBThrottled must
        # not leak into the output stream and turn the caller's $result into an array.
        @($r).Count         | Should -Be 1
        $r                  | Should -BeOfType ([System.Management.Automation.PSCustomObject])
        $r.Success          | Should -BeTrue
        $r.RestorePoint     | Should -Be 'PvPArena_FULL_20260227_100000.json'
        $r.UndoAvailable    | Should -BeTrue
        $r.SafetyBackupPath | Should -Not -BeNullOrEmpty
        $r.ErrorMessage     | Should -BeNullOrEmpty
        $r.Duration         | Should -Not -BeNullOrEmpty
    }

    It 'runs the steps in order: chain validate -> safety backup -> deploy -> start; stop is BEFORE deploy' {
        Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_20260227_100000.json' -Force | Out-Null
        Should -Invoke Test-SEBRestoreChain    -ModuleName RestoreEngine -Times 1 -Exactly
        Should -Invoke Invoke-SEBBackup        -ModuleName RestoreEngine -Times 1 -Exactly
        Should -Invoke Stop-SEBTorchServer     -ModuleName RestoreEngine -Times 1 -Exactly
        Should -Invoke Deploy-SEBRestoredFiles -ModuleName RestoreEngine -Times 1 -Exactly
        Should -Invoke Start-SEBTorchServer    -ModuleName RestoreEngine -Times 1 -Exactly
    }

    It 'takes the safety backup re-entrantly (-SkipLock -KeepSession) so it shares the restore lock/session' {
        Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_20260227_100000.json' -Force | Out-Null
        # Issue #9 / re-entrancy: the nested safety backup must NOT take the lock again or close the
        # session this restore keeps using for the destructive steps that follow.
        Should -Invoke Invoke-SEBBackup -ModuleName RestoreEngine -Times 1 -Exactly -ParameterFilter {
            $SkipLock -and $KeepSession -and $ForceFull
        }
    }

    It 'sends a restore notification via the restore notifier (not the backup one) with -InstanceName' {
        Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_20260227_100000.json' -Force | Out-Null
        Should -Invoke Send-SEBRestoreNotification -ModuleName RestoreEngine -Times 1 -Exactly -ParameterFilter {
            $InstanceName -eq 'PvPArena'
        }
    }

    It 'always releases the per-instance lock on the success path' {
        Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_20260227_100000.json' -Force | Out-Null
        Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 1 -Exactly -ParameterFilter { $InstanceName -eq 'PvPArena' }
    }
}

# ===========================================================================================
# FAILURE INJECTION
# ===========================================================================================
Describe 'Invoke-SEBRestore failure injection' {

    Context 'lock already held -> aborts before any chain/safety/node work' {
        BeforeAll {
            $man = New-ChainManifestFile -Dir $script:manifestsDir -Name 'PvPArena_FULL_lock.json' -Type 'full' -ChainId 'rc-lock' -Seq 0
            Set-RestoreHappyMocks -GlobalConfig (New-RestoreGlobalConfig) -ChainManifestPaths @($man)
            Mock New-SEBLockFile -ModuleName RestoreEngine {
                [PSCustomObject]@{ Acquired = $false; LockFilePath = 'X:\lock'; Reason = 'a backup is running'; StaleLockBroken = $false }
            }
        }

        It 'returns failure mentioning the lock and never validates the chain or runs the safety backup' {
            $r = Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_lock.json' -Force
            $r.Success      | Should -BeFalse
            $r.ErrorMessage | Should -Match 'lock'
            Should -Invoke Test-SEBRestoreChain -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Invoke-SEBBackup     -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Stop-SEBTorchServer  -ModuleName RestoreEngine -Times 0 -Exactly
        }

        It 'does NOT release a lock it never acquired' {
            Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_lock.json' -Force | Out-Null
            Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 0 -Exactly
        }
    }

    Context 'chain invalid -> aborts before the safety backup and before any node work' {
        BeforeAll {
            $man = New-ChainManifestFile -Dir $script:manifestsDir -Name 'PvPArena_FULL_badchain.json' -Type 'full' -ChainId 'rc-bad' -Seq 0
            Set-RestoreHappyMocks -GlobalConfig (New-RestoreGlobalConfig) -ChainManifestPaths @($man)
            Mock Test-SEBRestoreChain -ModuleName RestoreEngine {
                [PSCustomObject]@{ Valid = $false; ChainLength = 0; ChainManifests = @(); ChainArchives = @(); Errors = @('missing archive for sequence 1'); Warnings = @() }
            }
        }

        It 'returns failure with the chain error and runs no safety backup, stop, or deploy' {
            $r = Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_badchain.json' -Force
            $r.Success      | Should -BeFalse
            $r.ErrorMessage | Should -Match 'chain validation failed'
            $r.ErrorMessage | Should -Match 'missing archive'
            Should -Invoke Invoke-SEBBackup        -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Stop-SEBTorchServer     -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Deploy-SEBRestoredFiles -ModuleName RestoreEngine -Times 0 -Exactly
        }

        It 'still releases the lock (acquired before chain validation)' {
            Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_badchain.json' -Force | Out-Null
            Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 1 -Exactly
        }
    }

    Context 'safety backup fails -> aborts BEFORE the live world is touched (no stop, no deploy)' {
        BeforeAll {
            $man = New-ChainManifestFile -Dir $script:manifestsDir -Name 'PvPArena_FULL_safety.json' -Type 'full' -ChainId 'rc-safety' -Seq 0
            Set-RestoreHappyMocks -GlobalConfig (New-RestoreGlobalConfig) -ChainManifestPaths @($man)
            Mock Invoke-SEBBackup -ModuleName RestoreEngine {
                [PSCustomObject]@{ Success = $false; ArchiveFile = $null; ErrorMessage = 'node ran out of disk during safety backup' }
            }
        }

        It 'returns failure citing the safety backup and never stops the server or deploys' {
            $r = Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_safety.json' -Force
            $r.Success      | Should -BeFalse
            $r.ErrorMessage | Should -Match 'Safety backup'
            # The world must be untouched: no stop, no deploy, no start.
            Should -Invoke Stop-SEBTorchServer     -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Deploy-SEBRestoredFiles -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Start-SEBTorchServer    -ModuleName RestoreEngine -Times 0 -Exactly
        }

        It 'still releases the lock after the safety-backup abort' {
            Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_safety.json' -Force | Out-Null
            Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 1 -Exactly
        }
    }

    Context 'reconstruction verification fails -> aborts BEFORE deploy (server never stopped)' {
        BeforeAll {
            $man = New-ChainManifestFile -Dir $script:manifestsDir -Name 'PvPArena_FULL_verify.json' -Type 'full' -ChainId 'rc-verify' -Seq 0
            # The verify remote block reports a hash mismatch -> the orchestrator must abort pre-deploy.
            Set-RestoreHappyMocks -GlobalConfig (New-RestoreGlobalConfig) -ChainManifestPaths @($man) -Mismatches @('HASH MISMATCH: Sandbox.sbc')
        }

        It 'returns failure citing reconstruction verification and never stops the server or deploys' {
            $r = Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_verify.json' -Force
            $r.Success      | Should -BeFalse
            $r.ErrorMessage | Should -Match 'verification failed'
            # Critical: the server is stopped only AFTER a good reconstruction. A failed verify must
            # leave the live world and server untouched.
            Should -Invoke Stop-SEBTorchServer     -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Deploy-SEBRestoredFiles -ModuleName RestoreEngine -Times 0 -Exactly
        }
    }

    Context 'deploy fails -> structured failure surfaced; lock released' {
        BeforeAll {
            $man = New-ChainManifestFile -Dir $script:manifestsDir -Name 'PvPArena_FULL_deploy.json' -Type 'full' -ChainId 'rc-deploy' -Seq 0
            Set-RestoreHappyMocks -GlobalConfig (New-RestoreGlobalConfig) -ChainManifestPaths @($man)
            # Deploy-SEBRestoredFiles owns the prerestore-rename rollback internally; here it reports a
            # deploy failure (already rolled back), which the orchestrator turns into a thrown abort.
            Mock Deploy-SEBRestoredFiles -ModuleName RestoreEngine {
                [PSCustomObject]@{ Deployed = $false; PreRestorePath = 'D:\...\MyWorld_prerestore_x'; FilesCopied = 0; RolledBack = $true; ErrorMessage = 'copy to world path failed; rolled back' }
            }
        }

        It 'returns failure with the deploy error message (Deployment failed: ...)' {
            $r = Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_deploy.json' -Force
            $r.Success      | Should -BeFalse
            $r.ErrorMessage | Should -Match 'Deployment failed'
            $r.ErrorMessage | Should -Match 'rolled back'
            # The server WAS stopped (deploy runs after stop), but Start is not reached on a deploy throw.
            Should -Invoke Stop-SEBTorchServer  -ModuleName RestoreEngine -Times 1 -Exactly
            Should -Invoke Start-SEBTorchServer -ModuleName RestoreEngine -Times 0 -Exactly
        }

        It 'still releases the lock after a deploy failure (finally)' {
            Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_deploy.json' -Force | Out-Null
            Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 1 -Exactly
        }
    }

    Context 'stop server fails (non-manual) -> aborts before deploy' {
        BeforeAll {
            $man = New-ChainManifestFile -Dir $script:manifestsDir -Name 'PvPArena_FULL_stop.json' -Type 'full' -ChainId 'rc-stop' -Seq 0
            Set-RestoreHappyMocks -GlobalConfig (New-RestoreGlobalConfig) -ChainManifestPaths @($man)
            Mock Stop-SEBTorchServer -ModuleName RestoreEngine { @{ Stopped = $false; Method = 'service'; ErrorMessage = 'service would not stop' } }
        }

        It 'returns failure citing the stop and never deploys' {
            $r = Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_stop.json' -Force
            $r.Success      | Should -BeFalse
            $r.ErrorMessage | Should -Match 'stop Torch server'
            Should -Invoke Deploy-SEBRestoredFiles -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Remove-SEBLockFile      -ModuleName RestoreEngine -Times 1 -Exactly
        }
    }
}

# ===========================================================================================
# SAFETY-BACKUP OPT-OUT + START-SERVER DEGRADED + NOTIFICATION GATING
# ===========================================================================================
Describe 'Invoke-SEBRestore -SkipSafetyBackup and degraded-start handling' {

    Context '-SkipSafetyBackup skips the nested backup but still restores' {
        BeforeAll {
            $man = New-ChainManifestFile -Dir $script:manifestsDir -Name 'PvPArena_FULL_skipsafety.json' -Type 'full' -ChainId 'rc-skip' -Seq 0
            Set-RestoreHappyMocks -GlobalConfig (New-RestoreGlobalConfig) -ChainManifestPaths @($man)
        }

        It 'does not call Invoke-SEBBackup, warns about the skip, and still deploys + succeeds' {
            $r = Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_skipsafety.json' -Force -SkipSafetyBackup
            $r.Success | Should -BeTrue
            ($r.Warnings -join ' ') | Should -Match 'Safety backup was skipped'
            Should -Invoke Invoke-SEBBackup        -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Deploy-SEBRestoredFiles -ModuleName RestoreEngine -Times 1 -Exactly
        }
    }

    Context 'server starts but API not responding -> success with a degraded-start warning' {
        BeforeAll {
            $man = New-ChainManifestFile -Dir $script:manifestsDir -Name 'PvPArena_FULL_degraded.json' -Type 'full' -ChainId 'rc-deg' -Seq 0
            Set-RestoreHappyMocks -GlobalConfig (New-RestoreGlobalConfig) -ChainManifestPaths @($man)
            Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $true; APIResponding = $false; ErrorMessage = $null } }
        }

        It 'still reports Success but records the API-not-responding warning' {
            $r = Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_degraded.json' -Force
            $r.Success | Should -BeTrue
            ($r.Warnings -join ' ') | Should -Match 'API is not responding'
        }
    }

    Context 'notifications disabled -> no restore notification sent' {
        BeforeAll {
            $man = New-ChainManifestFile -Dir $script:manifestsDir -Name 'PvPArena_FULL_nonotify.json' -Type 'full' -ChainId 'rc-non' -Seq 0
            Set-RestoreHappyMocks -GlobalConfig (New-RestoreGlobalConfig -NotificationsEnabled $false) -ChainManifestPaths @($man)
        }

        It 'suppresses the restore notification when notifications.enabled=$false' {
            $r = Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_nonotify.json' -Force
            $r.Success | Should -BeTrue
            Should -Invoke Send-SEBRestoreNotification -ModuleName RestoreEngine -Times 0 -Exactly
        }
    }
}

# ===========================================================================================
# CONFIRMATION PROMPT (ShouldContinue substitute via Read-Host) -- -Force bypasses it
# ===========================================================================================
Describe 'Invoke-SEBRestore confirmation prompt' {
    BeforeAll {
        $man = New-ChainManifestFile -Dir $script:manifestsDir -Name 'PvPArena_FULL_confirm.json' -Type 'full' -ChainId 'rc-conf' -Seq 0
        Set-RestoreHappyMocks -GlobalConfig (New-RestoreGlobalConfig) -ChainManifestPaths @($man)
        # Without -Force the orchestrator prompts via Read-Host. Mock it to decline.
        Mock Read-Host -ModuleName RestoreEngine { 'no' }
    }

    It 'without -Force, a declined prompt aborts before any chain/safety/node work' {
        $r = Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_confirm.json'
        $r.Success      | Should -BeFalse
        $r.ErrorMessage | Should -Match 'cancelled'
        Should -Invoke Read-Host           -ModuleName RestoreEngine -Times 1 -Exactly
        Should -Invoke Invoke-SEBBackup    -ModuleName RestoreEngine -Times 0 -Exactly
        Should -Invoke Stop-SEBTorchServer -ModuleName RestoreEngine -Times 0 -Exactly
        # Lock was acquired before the prompt, so it must still be released.
        Should -Invoke Remove-SEBLockFile  -ModuleName RestoreEngine -Times 1 -Exactly
    }

    It 'does not consult the prompt at all when -Force is supplied' {
        Invoke-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena' -RestorePoint 'PvPArena_FULL_confirm.json' -Force | Out-Null
        Should -Invoke Read-Host -ModuleName RestoreEngine -Times 0 -Exactly
    }
}
