#Requires -Module Pester

# Invoke-SEBBackup is the backup orchestrator -- the DATA PATH. It is responsible for sequencing
# the whole pipeline (configs -> session -> lock -> load check -> preflight -> VRage save -> VSS
# capture -> manifest -> compress -> transfer -> integrity -> NAS -> metrics -> notify -> retention
# -> staging cleanup) and, critically, for ALWAYS releasing the per-instance lock and tearing down
# the node PSSession in its finally block no matter which step failed. These tests mock the infra
# boundary (the SEB seam functions) and assert REAL orchestration behavior: that the pipeline runs
# in order on the happy path, that a failure in any one seam aborts correctly without reporting
# partial success, and that the lock/session are released on every path.
#
# Test notes:
#  * Mocks target -ModuleName BackupEngine because Invoke-SEBBackup runs in that module's scope.
#    Seams that live OUTSIDE BackupEngine (New-SEBSession, Invoke-SEBWithShadowCopy, New-SEBManifest,
#    Compress-SEBArchive, Copy-SEBThrottled, Send-SEBBackupNotification, ...) are imported into that
#    scope at module load, so mocking them -ModuleName BackupEngine intercepts the engine's calls.
#    Seams INSIDE BackupEngine (Test-SEBPreFlight, Get-SEBBackupType, New-SEBLockFile,
#    Remove-SEBExpiredBackups) are mocked the same way.
#  * Each It calls Invoke-SEBBackup then asserts in the SAME block: Pester 5 scopes a mock's call
#    history to the block that produced it, so invoke-in-BeforeAll / assert-in-It records zero calls.
#  * cc_backup_root / nas_backup_path point at real temp dirs because the orchestrator does real
#    New-Item / Test-Path / Rename-Item on the C&C side (only the NODE side is mocked).
#  * New-FakeSession returns a type-satisfying but uninitialized PSSession (no transport); every
#    consumer of it is mocked, so its internals are never touched.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null
    . "$repoRoot/Tests/_TestHelpers/Test-Doubles.ps1"

    # A C&C temp root for this file's on-disk side effects (transfer dest, manifest write, NAS).
    $script:ccRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sebbk_cc_" + [guid]::NewGuid().ToString('n'))
    $script:nasRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sebbk_nas_" + [guid]::NewGuid().ToString('n'))
    New-Item -Path $script:ccRoot, $script:nasRoot -ItemType Directory -Force | Out-Null

    # Build the global-config hashtable the orchestrator reads many nested keys from. Returned by the
    # Get-SEBGlobalConfig mock. notifications.enabled/on_failure drive the notification assertions.
    function New-GlobalConfig {
        param([bool]$NotificationsEnabled = $true, [bool]$OnFailure = $true, [string]$Nas = $null)
        @{
            load_awareness = @{ enabled = $false }
            storage        = @{ cc_backup_root = $script:ccRoot; nas_backup_path = $Nas }
            compression    = @{ engine = 'dotnet'; level_7zip = 5 }
            network        = @{ max_bandwidth_mbps = 0; robocopy_ipg_ms = 0 }
            notifications  = @{ enabled = $NotificationsEnabled; on_failure = $OnFailure }
            defaults       = @{
                vrage_api = @{ port = 8080; save_timeout_seconds = 60 }
                vss       = @{ mount_base = 'C:\SEBackup\vss_mount' }
            }
        }
    }

    # A v2-shaped manifest hashtable, as New-SEBManifest returns it. The orchestrator mutates
    # archive_path/_archive_path and reads files/chain_id/chain_sequence.
    function New-ManifestObj {
        param([string]$Type = 'full', [string]$ChainId = 'chain-aaa', [int]$Seq = 0)
        @{
            version        = 2
            type           = $Type
            chain_id       = $ChainId
            chain_sequence = $Seq
            timestamp      = [datetime]::UtcNow.ToString('o')
            files          = @{ 'Sandbox.sbc' = @{ size = 10; sha256 = ('a' * 64); last_write = [datetime]::UtcNow.ToString('o') } }
            deleted_files  = @()
        }
    }

    # Install the full set of "everything succeeds" mocks. Individual Contexts re-Mock one seam to
    # fail. $BackupTypeObj lets a Context choose full vs incremental decision output.
    function Set-HappyMocks {
        param(
            [hashtable]$GlobalConfig,
            [PSCustomObject]$BackupTypeObj,
            [hashtable]$ManifestObj
        )

        Mock Write-SEBLog {} -ModuleName BackupEngine

        Mock Get-SEBGlobalConfig -ModuleName BackupEngine { $GlobalConfig }.GetNewClosure()
        Mock Get-SEBNodeConfig   -ModuleName BackupEngine { @{ node = @{ hostname = 'node01' } } }
        Mock New-SEBSession      -ModuleName BackupEngine { New-FakeSession -Name 'SEBackup-node01' -Target 'node01' }
        Mock Remove-SEBSession   -ModuleName BackupEngine {}
        Mock Get-SEBInstanceConfig -ModuleName BackupEngine {
            @{
                world_path   = 'D:\Torch\Instance\Saves\MyWorld'
                staging_path = 'C:\SEBackup\staging'
                share_name   = 'SEBackup$'
                vrage_api    = @{ port = 8080; security_key = 'k' }
            }
        }

        Mock New-SEBLockFile -ModuleName BackupEngine {
            [PSCustomObject]@{ Acquired = $true; LockFilePath = 'X:\lock'; Reason = $null; StaleLockBroken = $false }
        }
        Mock Remove-SEBLockFile -ModuleName BackupEngine { $true }

        Mock Get-SEBBackupType -ModuleName BackupEngine { $BackupTypeObj }.GetNewClosure()

        Mock Test-SEBPreFlight -ModuleName BackupEngine {
            [PSCustomObject]@{ Passed = $true; Failures = @(); Warnings = @() }
        }

        Mock Save-SEBVRageWorld -ModuleName BackupEngine {
            [PSCustomObject]@{ Success = $true; Duration = [timespan]::FromSeconds(1); ErrorMessage = $null }
        }

        Mock Get-SEBCompressionEngine -ModuleName BackupEngine { [PSCustomObject]@{ Engine = 'dotnet'; Version = '1'; Path = $null } }

        # VSS capture (node-local copy into staging). Returns nothing; just needs to not throw.
        Mock Invoke-SEBWithShadowCopy -ModuleName BackupEngine {}

        # New-SEBManifest produces the manifest the rest of the pipeline carries.
        Mock New-SEBManifest -ModuleName BackupEngine { $ManifestObj }.GetNewClosure()
        Mock Compare-SEBManifest -ModuleName BackupEngine {
            # Only called for incrementals. One changed file so the prune branch runs with content.
            @{ Added = @('Sandbox.sbc'); Modified = @(); Deleted = @(); AddedCount = 1; ModifiedCount = 0; DeletedCount = 0; UnchangedCount = 0 }
        }

        # Return the REAL .OUTPUTS shapes the production seams emit (not a fictional @{Success=$true}),
        # so the single-object contract assertions actually exercise the orchestrator's `| Out-Null`
        # discards: if an Out-Null is removed, the (now realistic) object leaks into the output stream
        # and @($r).Count -ne 1 (mutation-checked).
        #   Compress-SEBArchive -> @{ ArchivePath; SizeBytes; Engine; Duration }
        Mock Compress-SEBArchive -ModuleName BackupEngine {
            [PSCustomObject]@{ ArchivePath = $DestinationPath; SizeBytes = 12345; Engine = 'dotnet'; Duration = [timespan]::FromSeconds(2) }
        }
        Mock Get-SEBSharePath -ModuleName BackupEngine { '\\node01\SEBackup$' }
        #   Copy-SEBThrottled -> @{ Source; Destination; SizeBytes; DurationSeconds; AverageMbps; Method }
        Mock Copy-SEBThrottled -ModuleName BackupEngine {
            [PSCustomObject]@{ Source = $Source; Destination = $Destination; SizeBytes = 12345; DurationSeconds = 1.0; AverageMbps = 98.7; Method = 'Robocopy' }
        }
        Mock Write-SEBManifest -ModuleName BackupEngine {}

        # Real .OUTPUTS shapes (orchestrator reads .Passed / .ErrorMessage):
        #   Test-SEBArchiveIntegrity  -> @{ Level; Passed; ArchivePath; CheckedAt; ErrorMessage }
        #   Test-SEBManifestIntegrity -> @{ Level; Passed; ArchivePath; ManifestPath; FileCountMatch; HashMatch; Mismatches; CheckedAt; ErrorMessage }
        Mock Test-SEBArchiveIntegrity  -ModuleName BackupEngine {
            [PSCustomObject]@{ Level = 1; Passed = $true; ArchivePath = $ArchivePath; CheckedAt = [datetime]::UtcNow; ErrorMessage = $null }
        }
        Mock Test-SEBManifestIntegrity -ModuleName BackupEngine {
            [PSCustomObject]@{ Level = 2; Passed = $true; ArchivePath = $ArchivePath; ManifestPath = $ManifestPath; FileCountMatch = $true; HashMatch = $true; Mismatches = @(); CheckedAt = [datetime]::UtcNow; ErrorMessage = $null }
        }
        Mock Add-SEBMetric -ModuleName BackupEngine {}
        Mock Send-SEBBackupNotification -ModuleName BackupEngine {}
        Mock Remove-SEBExpiredBackups -ModuleName BackupEngine {}

        # Invoke-SEBRemoteCommand is called several times with DIFFERENT script blocks. Route by the
        # block text so each call gets the shape the orchestrator expects to read back:
        #   * pathInfo   (Split-Path -Qualifier)  -> @{ VolumeRoot; WorldRelative }
        #   * archiveInfo (Get-Item .Length)      -> @{ SizeBytes; Exists }
        #   * prune / staging-cleanup             -> $null (side-effect only on the node)
        #
        # FRAGILITY (intentional, documented): these ParameterFilters disambiguate the remote calls by
        # matching INCIDENTAL literals in each block's source text ('Split-Path .*-Qualifier' in the
        # path-probe block; 'SizeBytes' in the archive-size block). Those literals are the only stable
        # markers available without re-architecting the orchestrator to tag its remote blocks, but they
        # are NOT a contract: if Invoke-SEBBackup.ps1 rewrites either block so the literal disappears
        # (e.g. computes the qualifier differently, or renames the size field), the matching filter
        # silently stops matching and that call falls through to the catch-all `$null` mock -- the
        # backup then reads a $null pathInfo/archiveInfo and fails in a confusing way. If you touch
        # those remote blocks, update the markers here in lock-step. The catch-all below is keyed as
        # the NEGATION of the two specific markers for the same reason.
        Mock Invoke-SEBRemoteCommand -ModuleName BackupEngine -ParameterFilter { $ScriptBlock.ToString() -match 'Split-Path .*-Qualifier' } {
            @{ VolumeRoot = 'D:\'; WorldRelative = 'Torch\Instance\Saves\MyWorld' }
        }
        Mock Invoke-SEBRemoteCommand -ModuleName BackupEngine -ParameterFilter { $ScriptBlock.ToString() -match 'SizeBytes' } {
            @{ SizeBytes = 12345; Exists = $true }
        }
        Mock Invoke-SEBRemoteCommand -ModuleName BackupEngine -ParameterFilter {
            $ScriptBlock.ToString() -notmatch 'Split-Path .*-Qualifier' -and $ScriptBlock.ToString() -notmatch 'SizeBytes'
        } { $null }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:ccRoot  -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:nasRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ===========================================================================================
# HAPPY PATHS
# ===========================================================================================
Describe 'Invoke-SEBBackup happy path (FULL)' {
    BeforeAll {
        $cfg = New-GlobalConfig -Nas $script:nasRoot
        $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'forced'; LastFullManifest = $null; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
        Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj -Type 'full' -ChainId 'chain-aaa' -Seq 0)
    }

    It 'returns Success with the populated result object (archive/manifest/chain fields)' {
        $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull

        # The function's documented .OUTPUTS is a SINGLE PSCustomObject. Assert it is not an array:
        # the data-path seams (Compress-SEBArchive, Copy-SEBThrottled, the side-effect remote blocks)
        # return objects that, if left uncaptured, leak into this output stream and make the caller's
        # $result an array -- silently breaking $result.Success for every caller. Pin the single-object
        # contract here so that regression cannot return.
        @($r).Count       | Should -Be 1
        $r                | Should -BeOfType ([System.Management.Automation.PSCustomObject])
        $r.Success         | Should -BeTrue
        $r.BackupType      | Should -Be 'full'
        $r.InstanceName    | Should -Be 'PvPArena'
        $r.NodeName        | Should -Be 'node01'
        $r.ArchiveFile     | Should -Not -BeNullOrEmpty
        $r.ManifestFile    | Should -Not -BeNullOrEmpty
        $r.ArchiveSizeBytes | Should -Be 12345
        $r.FileCount       | Should -Be 1
        $r.ChainId         | Should -Be 'chain-aaa'
        $r.ChainSequence   | Should -Be 0
        $r.IntegrityPassed | Should -BeTrue
        $r.ErrorMessage    | Should -BeNullOrEmpty
        $r.Duration        | Should -Not -BeNullOrEmpty
    }

    It 'invokes each pipeline stage exactly once (lock, preflight, VSS, compress, manifest write, transfer, integrity, retention, notify)' {
        Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull | Out-Null

        # Each stage actually ran -- the assertions below are the "real orchestration" proof that the
        # happy-path is not vacuous: if the orchestrator short-circuited, these would be 0. (This test
        # asserts COUNTS only; the order-sensitive pairs are pinned in the next test.)
        Should -Invoke New-SEBLockFile          -ModuleName BackupEngine -Times 1 -Exactly -ParameterFilter { $InstanceName -eq 'PvPArena' }
        Should -Invoke Test-SEBPreFlight        -ModuleName BackupEngine -Times 1 -Exactly
        Should -Invoke Invoke-SEBWithShadowCopy -ModuleName BackupEngine -Times 1 -Exactly
        Should -Invoke New-SEBManifest          -ModuleName BackupEngine -Times 1 -Exactly
        Should -Invoke Compress-SEBArchive      -ModuleName BackupEngine -Times 1 -Exactly
        Should -Invoke Write-SEBManifest        -ModuleName BackupEngine -Times 1 -Exactly
        Should -Invoke Copy-SEBThrottled        -ModuleName BackupEngine -Times 2 -Exactly   # C&C transfer + NAS copy
        Should -Invoke Test-SEBArchiveIntegrity -ModuleName BackupEngine -Times 1 -Exactly
        Should -Invoke Remove-SEBExpiredBackups -ModuleName BackupEngine -Times 1 -Exactly
        Should -Invoke Send-SEBBackupNotification -ModuleName BackupEngine -Times 1 -Exactly
    }

    It 'orders the data path correctly: compress BEFORE the manifest write, and integrity BEFORE the NAS publish' {
        # Counts alone cannot catch a reordering that, say, published to NAS before integrity ran.
        # Record the ACTUAL call order: re-mock the ordered seams (on top of the happy mocks) so each
        # appends its stage name to a script-scoped list, then assert the order-sensitive pairs. Each
        # recorder still returns the real .OUTPUTS shape so the orchestrator runs through unchanged.
        $script:order = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-SEBWithShadowCopy -ModuleName BackupEngine { $script:order.Add('vss') }
        Mock Compress-SEBArchive      -ModuleName BackupEngine {
            $script:order.Add('compress')
            [PSCustomObject]@{ ArchivePath = $DestinationPath; SizeBytes = 12345; Engine = 'dotnet'; Duration = [timespan]::FromSeconds(1) }
        }
        Mock Write-SEBManifest        -ModuleName BackupEngine { $script:order.Add('manifest_write') }
        Mock Test-SEBArchiveIntegrity -ModuleName BackupEngine {
            $script:order.Add('integrity')
            [PSCustomObject]@{ Level = 1; Passed = $true; ArchivePath = $ArchivePath; CheckedAt = [datetime]::UtcNow; ErrorMessage = $null }
        }
        Mock Copy-SEBThrottled -ModuleName BackupEngine {
            # Tag the NAS copy distinctly from the C&C transfer so the integrity<NAS pair is precise.
            $tag = if ($Destination -like "$script:nasRoot*") { 'nas_copy' } else { 'cc_transfer' }
            $script:order.Add($tag)
            [PSCustomObject]@{ Source = $Source; Destination = $Destination; SizeBytes = 12345; DurationSeconds = 1.0; AverageMbps = 9.9; Method = 'Robocopy' }
        }

        Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull | Out-Null

        $idx = @{}
        foreach ($name in @('vss', 'compress', 'manifest_write', 'integrity', 'cc_transfer', 'nas_copy')) {
            $idx[$name] = $script:order.IndexOf($name)
            $idx[$name] | Should -BeGreaterThan -1 -Because "stage '$name' must have run"
        }
        # The load-bearing order constraints in the data path:
        $idx['vss']            | Should -BeLessThan $idx['compress']        -Because 'the snapshot must be captured before it is compressed'
        $idx['compress']       | Should -BeLessThan $idx['cc_transfer']     -Because 'the archive must exist on the node before it is transferred to C&C'
        $idx['cc_transfer']    | Should -BeLessThan $idx['manifest_write']  -Because 'the manifest is written after the archive lands on C&C'
        $idx['manifest_write'] | Should -BeLessThan $idx['integrity']       -Because 'integrity checks read the written manifest + archive'
        $idx['integrity']      | Should -BeLessThan $idx['nas_copy']        -Because 'a corrupt archive must never be published to NAS -- integrity gates the NAS copy'
    }

    It 'releases the lock and tears down the session on the success path' {
        Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull | Out-Null
        Should -Invoke Remove-SEBLockFile -ModuleName BackupEngine -Times 1 -Exactly -ParameterFilter { $InstanceName -eq 'PvPArena' }
        Should -Invoke Remove-SEBSession  -ModuleName BackupEngine -Times 1 -Exactly -ParameterFilter { $NodeName -eq 'node01' }
    }

    It 'for a FULL does NOT pass a previous manifest to New-SEBManifest (would corrupt the chain)' {
        Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull | Out-Null
        # The full branch must never set PreviousManifest, and must not diff. (In a Should -Invoke
        # -ParameterFilter the bound argument is exposed as the variable $PreviousManifest; checking
        # it for $null is the reliable test -- $PSBoundParameters here is the filter's own, not the call's.)
        Should -Invoke New-SEBManifest -ModuleName BackupEngine -Times 1 -Exactly -ParameterFilter {
            $null -eq $PreviousManifest
        }
        Should -Invoke Compare-SEBManifest -ModuleName BackupEngine -Times 0 -Exactly
    }

    It 'does NOT publish to NAS until after integrity passes (copies the C&C archive, never a _BAD name)' {
        Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull | Out-Null
        # The NAS copy (2nd Copy-SEBThrottled) sources the clean C&C archive, not a _BAD-renamed one.
        Should -Invoke Copy-SEBThrottled -ModuleName BackupEngine -ParameterFilter { $Destination -like "$script:nasRoot*" -and $Source -notlike '*_BAD*' }
    }
}

Describe 'Invoke-SEBBackup happy path (INCREMENTAL)' {
    BeforeAll {
        $cfg = New-GlobalConfig
        $prevManifest = New-ManifestObj -Type 'full' -ChainId 'chain-bbb' -Seq 0
        # Incremental decision carries the parent manifest in .LastManifest -- the orchestrator wires
        # it into New-SEBManifest -PreviousManifest AND into Compare-SEBManifest -PreviousManifest.
        $bt = [PSCustomObject]@{ Type = 'incremental'; Reason = 'within interval'; LastFullManifest = $prevManifest; LastManifest = $prevManifest; ChainId = 'chain-bbb'; ChainSequence = 1 }
        Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj -Type 'incremental' -ChainId 'chain-bbb' -Seq 1)
    }

    It 'reports BackupType incremental and Success' {
        $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'Creative'
        $r.Success    | Should -BeTrue
        $r.BackupType | Should -Be 'incremental'
        $r.ChainId    | Should -Be 'chain-bbb'
        $r.ChainSequence | Should -Be 1
    }

    It 'wires the parent manifest into New-SEBManifest -PreviousManifest and diffs via Compare-SEBManifest' {
        Invoke-SEBBackup -NodeName 'node01' -InstanceName 'Creative' | Out-Null
        # The incremental branch MUST pass the previous manifest (the whole point of incremental).
        # The bound argument surfaces as $PreviousManifest in the filter scope.
        Should -Invoke New-SEBManifest -ModuleName BackupEngine -Times 1 -Exactly -ParameterFilter {
            $null -ne $PreviousManifest
        }
        Should -Invoke Compare-SEBManifest -ModuleName BackupEngine -Times 1 -Exactly
    }

    It 'prunes unchanged files from staging on the node before compressing (the incremental delta)' {
        Invoke-SEBBackup -NodeName 'node01' -InstanceName 'Creative' | Out-Null
        # The prune call is the remote block that builds a HashSet of files to keep.
        Should -Invoke Invoke-SEBRemoteCommand -ModuleName BackupEngine -ParameterFilter { $ScriptBlock.ToString() -match 'HashSet' }
    }

    Context 'incremental with an EMPTY delta (no added/modified files) still succeeds and still prunes' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $prevManifest = New-ManifestObj -Type 'full' -ChainId 'chain-empty' -Seq 0
            $bt = [PSCustomObject]@{ Type = 'incremental'; Reason = 'within interval'; LastFullManifest = $prevManifest; LastManifest = $prevManifest; ChainId = 'chain-empty'; ChainSequence = 1 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj -Type 'incremental' -ChainId 'chain-empty' -Seq 1)
            # The diff finds NOTHING changed since the parent: Added/Modified empty, counts zero. The
            # orchestrator must warn that the archive will be empty but STILL prune staging and produce
            # the (manifest-only) backup -- the empty-delta branch must not abort or short-circuit.
            Mock Compare-SEBManifest -ModuleName BackupEngine {
                @{ Added = @(); Modified = @(); Deleted = @(); AddedCount = 0; ModifiedCount = 0; DeletedCount = 0; UnchangedCount = 5 }
            }
        }

        It 'succeeds, records the empty-archive warning, and still runs the staging prune' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'CreativeEmpty'
            $r.Success    | Should -BeTrue
            $r.BackupType | Should -Be 'incremental'
            ($r.Warnings -join ' ') | Should -Match 'No file changes|empty'
            # The diff ran, and the prune (HashSet keep-set) STILL ran even though nothing changed --
            # the prune block sits after the empty-delta warning, not behind it.
            Should -Invoke Compare-SEBManifest     -ModuleName BackupEngine -Times 1 -Exactly
            Should -Invoke Invoke-SEBRemoteCommand  -ModuleName BackupEngine -ParameterFilter { $ScriptBlock.ToString() -match 'HashSet' }
            # And the pipeline still completed the compress/transfer and ran retention.
            Should -Invoke Compress-SEBArchive      -ModuleName BackupEngine -Times 1 -Exactly
            Should -Invoke Remove-SEBExpiredBackups -ModuleName BackupEngine -Times 1 -Exactly
        }
    }
}

# ===========================================================================================
# FAILURE INJECTION -- one seam fails at a time; assert abort + cleanup, no partial success
# ===========================================================================================
Describe 'Invoke-SEBBackup failure injection' {

    Context 'pre-flight fails -> aborts BEFORE acquiring infra-heavy work; lock/session still released' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            Mock Test-SEBPreFlight -ModuleName BackupEngine {
                [PSCustomObject]@{ Passed = $false; Failures = @('insufficient disk space on node'); Warnings = @() }
            }
        }

        It 'returns failure with the preflight reason and never runs VSS/compress/manifest' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull

            $r.Success      | Should -BeFalse
            $r.ErrorMessage | Should -Match 'Pre-flight'
            $r.ErrorMessage | Should -Match 'insufficient disk space'

            Should -Invoke Invoke-SEBWithShadowCopy -ModuleName BackupEngine -Times 0 -Exactly
            Should -Invoke Compress-SEBArchive      -ModuleName BackupEngine -Times 0 -Exactly
            Should -Invoke New-SEBManifest          -ModuleName BackupEngine -Times 0 -Exactly
        }

        It 'still releases the lock and tears down the session (finally runs)' {
            Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull | Out-Null
            Should -Invoke Remove-SEBLockFile -ModuleName BackupEngine -Times 1 -Exactly
            Should -Invoke Remove-SEBSession  -ModuleName BackupEngine -Times 1 -Exactly
        }
    }

    Context 'lock already held -> aborts with a clear result and does NOT run the backup' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            Mock New-SEBLockFile -ModuleName BackupEngine {
                [PSCustomObject]@{ Acquired = $false; LockFilePath = 'X:\lock'; Reason = 'a backup is already running'; StaleLockBroken = $false }
            }
        }

        It 'returns failure mentioning the lock and runs none of the data-path seams' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull

            $r.Success      | Should -BeFalse
            $r.ErrorMessage | Should -Match 'lock'
            $r.ErrorMessage | Should -Match 'already running'

            Should -Invoke Test-SEBPreFlight        -ModuleName BackupEngine -Times 0 -Exactly
            Should -Invoke Invoke-SEBWithShadowCopy -ModuleName BackupEngine -Times 0 -Exactly
            Should -Invoke Compress-SEBArchive      -ModuleName BackupEngine -Times 0 -Exactly
        }

        It 'does NOT release a lock it never acquired (lockAcquired stays $false)' {
            Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull | Out-Null
            # The lock was never ours, so finally must not call Remove-SEBLockFile.
            Should -Invoke Remove-SEBLockFile -ModuleName BackupEngine -Times 0 -Exactly
            # But the session WAS created before the lock check, so it is still torn down.
            Should -Invoke Remove-SEBSession  -ModuleName BackupEngine -Times 1 -Exactly
        }
    }

    Context 'VSS capture fails -> aborts; no compress/manifest; lock released + session torn down in finally' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            Mock Invoke-SEBWithShadowCopy -ModuleName BackupEngine { throw 'VSS snapshot creation failed on node' }
        }

        It 'returns failure with the VSS error and skips compress + manifest generation' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull

            $r.Success      | Should -BeFalse
            $r.IntegrityPassed | Should -BeFalse
            $r.ErrorMessage | Should -Match 'VSS'

            Should -Invoke New-SEBManifest     -ModuleName BackupEngine -Times 0 -Exactly
            Should -Invoke Compress-SEBArchive -ModuleName BackupEngine -Times 0 -Exactly
            Should -Invoke Write-SEBManifest   -ModuleName BackupEngine -Times 0 -Exactly
        }

        It 'releases the lock and tears down the session even though VSS threw (finally)' {
            Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull | Out-Null
            Should -Invoke Remove-SEBLockFile -ModuleName BackupEngine -Times 1 -Exactly -ParameterFilter { $InstanceName -eq 'PvPArena' }
            Should -Invoke Remove-SEBSession  -ModuleName BackupEngine -Times 1 -Exactly -ParameterFilter { $NodeName -eq 'node01' }
        }
    }

    Context 'compress fails -> aborts; no manifest write/transfer; lock + session released' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            Mock Compress-SEBArchive -ModuleName BackupEngine { throw 'compression engine returned a nonzero exit code' }
        }

        It 'returns failure and never writes the manifest or transfers the archive' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull
            $r.Success | Should -BeFalse
            $r.ErrorMessage | Should -Match 'compression'
            # Manifest WAS generated (before compress) but never written/transferred after the failure.
            Should -Invoke Write-SEBManifest -ModuleName BackupEngine -Times 0 -Exactly
            Should -Invoke Copy-SEBThrottled -ModuleName BackupEngine -Times 0 -Exactly
        }

        It 'releases the lock and tears down the session after a compress failure' {
            Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull | Out-Null
            Should -Invoke Remove-SEBLockFile -ModuleName BackupEngine -Times 1 -Exactly
            Should -Invoke Remove-SEBSession  -ModuleName BackupEngine -Times 1 -Exactly
        }
    }

    Context 'archive missing after compress (Exists=$false) -> aborts before transfer' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            # archiveInfo reports the archive does not exist on the node.
            Mock Invoke-SEBRemoteCommand -ModuleName BackupEngine -ParameterFilter { $ScriptBlock.ToString() -match 'SizeBytes' } {
                @{ SizeBytes = 0; Exists = $false }
            }
        }

        It 'throws "Archive was not created" and does not transfer or write the manifest' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull
            $r.Success | Should -BeFalse
            $r.ErrorMessage | Should -Match 'Archive was not created'
            Should -Invoke Copy-SEBThrottled -ModuleName BackupEngine -Times 0 -Exactly
            Should -Invoke Write-SEBManifest -ModuleName BackupEngine -Times 0 -Exactly
            Should -Invoke Remove-SEBLockFile -ModuleName BackupEngine -Times 1 -Exactly
            Should -Invoke Remove-SEBSession  -ModuleName BackupEngine -Times 1 -Exactly
        }
    }

    Context 'transfer fails -> aborts; lock + session released' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            # The FIRST Copy-SEBThrottled is the C&C transfer; make it throw.
            Mock Copy-SEBThrottled -ModuleName BackupEngine { throw 'robocopy failed transferring archive from share' }
        }

        It 'returns failure from the transfer and never writes the C&C manifest' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull
            $r.Success | Should -BeFalse
            $r.ErrorMessage | Should -Match 'robocopy|transfer'
            Should -Invoke Write-SEBManifest -ModuleName BackupEngine -Times 0 -Exactly
        }

        It 'releases the lock and tears down the session after a transfer failure' {
            Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull | Out-Null
            Should -Invoke Remove-SEBLockFile -ModuleName BackupEngine -Times 1 -Exactly
            Should -Invoke Remove-SEBSession  -ModuleName BackupEngine -Times 1 -Exactly
        }
    }

    Context 'manifest generation fails (New-SEBManifest returns $null) -> aborts before compress' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            Mock New-SEBManifest -ModuleName BackupEngine { $null }
        }

        It 'throws "Manifest generation failed" and never compresses' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull
            $r.Success | Should -BeFalse
            $r.ErrorMessage | Should -Match 'Manifest generation failed'
            Should -Invoke Compress-SEBArchive -ModuleName BackupEngine -Times 0 -Exactly
            Should -Invoke Remove-SEBLockFile  -ModuleName BackupEngine -Times 1 -Exactly
            Should -Invoke Remove-SEBSession   -ModuleName BackupEngine -Times 1 -Exactly
        }
    }

    Context 'integrity fails -> NOT a hard error, but Success=$false, archive renamed _BAD, NO NAS publish' {
        BeforeAll {
            $cfg = New-GlobalConfig -Nas $script:nasRoot
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = 'chain-int'; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj -ChainId 'chain-int')
            # The _BAD rename operates on the REAL on-disk C&C archive, so the C&C transfer mock must
            # actually create that file for the rename to have something to act on (Copy-SEBThrottled
            # is otherwise a no-op). The orchestrator transfers TO $ccArchivePath; create it there.
            Mock Copy-SEBThrottled -ModuleName BackupEngine {
                if ($Destination -and (Split-Path $Destination -Parent | Test-Path)) {
                    Set-Content -LiteralPath $Destination -Value 'corrupt-archive-bytes' -NoNewline -ErrorAction SilentlyContinue
                }
                [PSCustomObject]@{ Source = $Source; Destination = $Destination; SizeBytes = 21; DurationSeconds = 0.1; AverageMbps = 1.0; Method = 'Robocopy' }
            }
            # Level-1 integrity fails. The orchestrator does NOT throw -- it marks the backup BAD,
            # renames archive+manifest, suppresses the NAS publish, and reports Success=$false.
            # Real .OUTPUTS: @{ Level; Passed; ArchivePath; CheckedAt; ErrorMessage }.
            Mock Test-SEBArchiveIntegrity -ModuleName BackupEngine {
                [PSCustomObject]@{ Level = 1; Passed = $false; ArchivePath = $ArchivePath; CheckedAt = [datetime]::UtcNow; ErrorMessage = 'CRC mismatch' }
            }
        }

        # NOTE: each It uses a UNIQUE instance name. The orchestrator writes a REAL archive to
        # {cc}\{Instance}\full\{Instance}_FULL_{yyyyMMdd_HHmmss}.zip and (on integrity failure)
        # renames it to _BAD. Two calls in the same wall-clock second with the same instance name
        # would produce the same path and the second _BAD rename would collide with the first run's
        # _BAD file. Distinct instance names keep each It's on-disk side effects independent.
        It 'reports IntegrityPassed=$false and Success=$false (no false-positive success)' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'IntgA' -ForceFull
            $r.IntegrityPassed | Should -BeFalse
            $r.Success         | Should -BeFalse
        }

        It 'renames the produced archive to a _BAD name on the result' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'IntgB' -ForceFull
            # The real archive was written and renamed; the result must point at the _BAD artifact so
            # retention/restore never treat the failed backup as a valid chain parent.
            $r.ArchiveFile | Should -Match '_BAD'
            Test-Path -LiteralPath $r.ArchiveFile | Should -BeTrue
        }

        It 'does NOT copy the failed archive to NAS (integrity gate before NAS publish)' {
            Invoke-SEBBackup -NodeName 'node01' -InstanceName 'IntgC' -ForceFull | Out-Null
            # Only the single C&C transfer should have happened -- the NAS Copy is gated on integrity.
            Should -Invoke Copy-SEBThrottled -ModuleName BackupEngine -ParameterFilter { $Destination -like "$script:nasRoot*" } -Times 0 -Exactly
        }

        It 'still releases the lock and session' {
            Invoke-SEBBackup -NodeName 'node01' -InstanceName 'IntgD' -ForceFull | Out-Null
            Should -Invoke Remove-SEBLockFile -ModuleName BackupEngine -Times 1 -Exactly
            Should -Invoke Remove-SEBSession  -ModuleName BackupEngine -Times 1 -Exactly
        }

        It 'still runs retention on the integrity-failed path (a _BAD backup must not stop the sweep)' {
            Invoke-SEBBackup -NodeName 'node01' -InstanceName 'IntgRet' -ForceFull | Out-Null
            # Integrity failure is the SOFT path (no throw): the orchestrator runs to completion through
            # metrics/notify/retention, so the expired-backup sweep must still fire exactly once.
            Should -Invoke Remove-SEBExpiredBackups -ModuleName BackupEngine -Times 1 -Exactly -ParameterFilter { $InstanceName -eq 'IntgRet' }
        }
    }

    Context 'integrity fails AND the _BAD rename itself fails -> partial state surfaced as a warning, not a crash' {
        BeforeAll {
            $cfg = New-GlobalConfig -Nas $script:nasRoot
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = 'chain-badren'; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj -ChainId 'chain-badren')
            # The C&C transfer writes the REAL archive, then pre-creates the _BAD destination as a
            # NON-EMPTY DIRECTORY at exactly the path the orchestrator will try to rename onto. A
            # file->file Rename-Item -Force onto an existing directory of that name throws ("Cannot
            # create a file when that file already exists"), exercising the catch that the happy _BAD
            # rename never reaches.
            Mock Copy-SEBThrottled -ModuleName BackupEngine {
                if ($Destination -and (Split-Path $Destination -Parent | Test-Path)) {
                    Set-Content -LiteralPath $Destination -Value 'corrupt-archive-bytes' -NoNewline -ErrorAction SilentlyContinue
                    $badPath = $Destination -replace '(\.\w+)$', '_BAD$1'
                    New-Item -ItemType Directory -Path $badPath -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-Content -LiteralPath (Join-Path $badPath 'blocker.txt') -Value 'x' -NoNewline -ErrorAction SilentlyContinue
                }
                [PSCustomObject]@{ Source = $Source; Destination = $Destination; SizeBytes = 21; DurationSeconds = 0.1; AverageMbps = 1.0; Method = 'Robocopy' }
            }
            Mock Test-SEBArchiveIntegrity -ModuleName BackupEngine {
                [PSCustomObject]@{ Level = 1; Passed = $false; ArchivePath = $ArchivePath; CheckedAt = [datetime]::UtcNow; ErrorMessage = 'CRC mismatch' }
            }
        }

        It 'reports Success=$false, records the rename failure as a warning, and does NOT throw out of the function' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'IntgRenFail' -ForceFull
            # The function must STILL return a structured result (the rename failure is caught, not
            # propagated): integrity failed so Success/IntegrityPassed are false, and a warning records
            # that the _BAD rename could not complete.
            $r.Success         | Should -BeFalse
            $r.IntegrityPassed | Should -BeFalse
            ($r.Warnings -join ' ') | Should -Match 'rename failed archive to BAD'
            # Because the rename failed, ArchiveFile keeps the ORIGINAL (non-_BAD) path -- and that
            # original file is still on disk (it was never moved).
            $r.ArchiveFile | Should -Not -Match '_BAD'
            Test-Path -LiteralPath $r.ArchiveFile | Should -BeTrue
        }

        It 'still gates NAS publish off (a failed-integrity archive is never published even if its _BAD rename failed)' {
            Invoke-SEBBackup -NodeName 'node01' -InstanceName 'IntgRenFail2' -ForceFull | Out-Null
            Should -Invoke Copy-SEBThrottled -ModuleName BackupEngine -ParameterFilter { $Destination -like "$script:nasRoot*" } -Times 0 -Exactly
        }

        It 'still releases the lock and tears down the session on the partial-state path' {
            Invoke-SEBBackup -NodeName 'node01' -InstanceName 'IntgRenFail3' -ForceFull | Out-Null
            Should -Invoke Remove-SEBLockFile -ModuleName BackupEngine -Times 1 -Exactly
            Should -Invoke Remove-SEBSession  -ModuleName BackupEngine -Times 1 -Exactly
        }
    }
}

# ===========================================================================================
# NOTIFICATION GATING
# ===========================================================================================
Describe 'Invoke-SEBBackup notification gating' {

    Context 'a hard failure with notifications.on_failure=$true sends a failure notification' {
        BeforeAll {
            $cfg = New-GlobalConfig -OnFailure $true
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            Mock Compress-SEBArchive -ModuleName BackupEngine { throw 'boom' }
        }

        It 'sends exactly one notification, carrying the failed result (Success=$false)' {
            Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull | Out-Null
            Should -Invoke Send-SEBBackupNotification -ModuleName BackupEngine -Times 1 -Exactly -ParameterFilter {
                $BackupResult.Success -eq $false
            }
        }
    }

    Context 'a hard failure with notifications.on_failure=$false sends NO notification' {
        BeforeAll {
            $cfg = New-GlobalConfig -OnFailure $false
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            Mock Compress-SEBArchive -ModuleName BackupEngine { throw 'boom' }
        }

        It 'suppresses the failure notification per the on_failure gate' {
            Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull | Out-Null
            Should -Invoke Send-SEBBackupNotification -ModuleName BackupEngine -Times 0 -Exactly
        }
    }

    Context '-SkipNotify suppresses the notification on the success path' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
        }

        It 'does not notify when -SkipNotify is set even though the backup succeeds' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull -SkipNotify
            $r.Success | Should -BeTrue
            Should -Invoke Send-SEBBackupNotification -ModuleName BackupEngine -Times 0 -Exactly
        }
    }
}

# ===========================================================================================
# RE-ENTRANT CONTRACT (-SkipLock / -KeepSession) used by Invoke-SEBRestore's safety backup
# ===========================================================================================
Describe 'Invoke-SEBBackup re-entrant flags (-SkipLock / -KeepSession)' {
    BeforeAll {
        $cfg = New-GlobalConfig
        $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
        Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
    }

    It '-SkipLock does not acquire or release the per-instance lock (caller already holds it)' {
        $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull -SkipLock -SkipNotify
        $r.Success | Should -BeTrue
        Should -Invoke New-SEBLockFile    -ModuleName BackupEngine -Times 0 -Exactly
        Should -Invoke Remove-SEBLockFile -ModuleName BackupEngine -Times 0 -Exactly
    }

    It '-KeepSession does not tear down the node session (caller owns its lifecycle)' {
        $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull -KeepSession -SkipNotify
        $r.Success | Should -BeTrue
        Should -Invoke Remove-SEBSession -ModuleName BackupEngine -Times 0 -Exactly
    }
}

# ===========================================================================================
# LOAD-AWARENESS GATE + VRAGE BRANCHES
# ===========================================================================================
Describe 'Invoke-SEBBackup load-awareness gate' {

    Context 'node under high load, then waits and proceeds (records the delay as a warning)' {
        BeforeAll {
            # load_awareness.enabled = $true triggers the Test-SEBNodeLoad / Wait-SEBNodeLoad path.
            $cfg = New-GlobalConfig
            $cfg.load_awareness = @{ enabled = $true }
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            Mock Test-SEBNodeLoad -ModuleName BackupEngine { [PSCustomObject]@{ CanProceed = $false } }
            Mock Wait-SEBNodeLoad -ModuleName BackupEngine { [PSCustomObject]@{ CanProceed = $true; WaitedSeconds = 12 } }
        }

        It 'consults Test-SEBNodeLoad, waits via Wait-SEBNodeLoad, then completes with a delay warning' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull -SkipNotify
            $r.Success | Should -BeTrue
            Should -Invoke Test-SEBNodeLoad -ModuleName BackupEngine -Times 1 -Exactly
            Should -Invoke Wait-SEBNodeLoad -ModuleName BackupEngine -Times 1 -Exactly
            ($r.Warnings -join ' ') | Should -Match 'high node load'
        }
    }

    Context 'node never reaches safe load -> backup deferred (aborts) but lock/session released' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $cfg.load_awareness = @{ enabled = $true }
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            Mock Test-SEBNodeLoad -ModuleName BackupEngine { [PSCustomObject]@{ CanProceed = $false } }
            Mock Wait-SEBNodeLoad -ModuleName BackupEngine { [PSCustomObject]@{ CanProceed = $false; WaitedSeconds = 600 } }
        }

        It 'aborts with a deferral message and never reaches VSS, releasing the lock and session' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull -SkipNotify
            $r.Success      | Should -BeFalse
            $r.ErrorMessage | Should -Match 'deferred'
            Should -Invoke Invoke-SEBWithShadowCopy -ModuleName BackupEngine -Times 0 -Exactly
            Should -Invoke Remove-SEBLockFile -ModuleName BackupEngine -Times 1 -Exactly
            Should -Invoke Remove-SEBSession  -ModuleName BackupEngine -Times 1 -Exactly
        }
    }

    Context '-SkipLoadCheck bypasses the load gate even when load_awareness is enabled' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $cfg.load_awareness = @{ enabled = $true }
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            Mock Test-SEBNodeLoad -ModuleName BackupEngine { [PSCustomObject]@{ CanProceed = $false } }
            Mock Wait-SEBNodeLoad -ModuleName BackupEngine { [PSCustomObject]@{ CanProceed = $false; WaitedSeconds = 600 } }
        }

        It 'never calls the load checks and completes the backup' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull -SkipLoadCheck -SkipNotify
            $r.Success | Should -BeTrue
            Should -Invoke Test-SEBNodeLoad -ModuleName BackupEngine -Times 0 -Exactly
            Should -Invoke Wait-SEBNodeLoad -ModuleName BackupEngine -Times 0 -Exactly
        }
    }
}

Describe 'Invoke-SEBBackup VRage save branch' {

    Context 'no VRage security_key configured -> warns and skips the world save, still succeeds' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            # Instance config WITHOUT a vrage_api.security_key -> the save-trigger branch is skipped.
            Mock Get-SEBInstanceConfig -ModuleName BackupEngine {
                @{ world_path = 'D:\Torch\Instance\Saves\MyWorld'; staging_path = 'C:\SEBackup\staging'; share_name = 'SEBackup$' }
            }
        }

        It 'does not call Save-SEBVRageWorld, adds a no-key warning, and still backs up' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull -SkipNotify
            $r.Success | Should -BeTrue
            Should -Invoke Save-SEBVRageWorld -ModuleName BackupEngine -Times 0 -Exactly
            ($r.Warnings -join ' ') | Should -Match 'security_key'
        }
    }

    Context 'VRage save fails -> warning only, the backup continues (non-fatal)' {
        BeforeAll {
            $cfg = New-GlobalConfig
            $bt = [PSCustomObject]@{ Type = 'full'; Reason = 'x'; LastManifest = $null; ChainId = $null; ChainSequence = 0 }
            Set-HappyMocks -GlobalConfig $cfg -BackupTypeObj $bt -ManifestObj (New-ManifestObj)
            Mock Save-SEBVRageWorld -ModuleName BackupEngine {
                [PSCustomObject]@{ Success = $false; Duration = [timespan]::Zero; ErrorMessage = 'API connection refused' }
            }
        }

        It 'records the save failure as a warning but completes the backup successfully' {
            $r = Invoke-SEBBackup -NodeName 'node01' -InstanceName 'PvPArena' -ForceFull -SkipNotify
            $r.Success | Should -BeTrue
            ($r.Warnings -join ' ') | Should -Match 'world save failed'
            # The pipeline still proceeded past the save into the capture/compress steps.
            Should -Invoke Invoke-SEBWithShadowCopy -ModuleName BackupEngine -Times 1 -Exactly
        }
    }
}

# ===========================================================================================
# DRY-RUN CONTRACT: the engine orchestrator deliberately does NOT implement -WhatIf.
# ===========================================================================================
Describe 'Invoke-SEBBackup does not implement -WhatIf (dry-run lives at the Scripts layer)' {
    # The engine is the data path; the -WhatIf/-Confirm risk gate is implemented by the entry-point
    # script (Scripts/Invoke-Restore.ps1 has SupportsShouldProcess), NOT duplicated in the engine.
    # This test pins that contract so a future half-wired WhatIf on the engine (which would guard
    # only SOME mutating seams and silently no-op others) is caught in review.
    It 'does not advertise SupportsShouldProcess (no -WhatIf parameter)' {
        (Get-Command Invoke-SEBBackup).Parameters.ContainsKey('WhatIf') | Should -BeFalse
    }
}
