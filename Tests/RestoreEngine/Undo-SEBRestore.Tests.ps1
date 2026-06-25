#Requires -Module Pester

# Undo-SEBRestore reverts a restore by renaming the most recent _prerestore_ dir back over the
# live world. Because it renames the live world, it MUST hold the same per-instance lock the
# backup/restore engines use (so a scheduled backup can't run mid-rename), and it MUST always
# release that lock and tear down the PSSession it created -- even when the undo fails. An
# unacquirable lock must abort BEFORE any world rename is attempted.
#
# Test notes:
#  * Mocks target -ModuleName RestoreEngine because Undo-SEBRestore runs in that module's scope.
#  * Each assertion calls Undo-SEBRestore inside its own It and then asserts in the same block:
#    Pester 5 scopes a mock's *call history* to the block that produced it, so invoking in
#    BeforeAll and asserting in a sibling It records zero calls. Calling per-It keeps the
#    invocation and the Should -Invoke in the same history scope.
#  * The downstream helpers (Get-SEBInstanceConfig, Stop/Start-SEBTorchServer, Invoke-SEBRemoteCommand)
#    strongly type -Session as [System.Management.Automation.Runspaces.PSSession]; PowerShell
#    enforces that cast during parameter binding even for mocked commands, and the type has no
#    public constructor, so New-FakeSession (Tests/_TestHelpers/Test-Doubles.ps1) returns an
#    *uninitialized* PSSession instance (which satisfies the cast). Its internals are never touched
#    because every consumer is mocked.
#  * The two Invoke-SEBRemoteCommand calls (prerestore-find, then rename-undo) are routed by their
#    script-block SOURCE TEXT via ParameterFilter. That text is the disambiguation marker: the find
#    block contains the 'prerestore_*' Get-ChildItem filter literal; the rename block contains the
#    'postrestore' suffix literal. These markers are load-bearing -- if the production source ever
#    renames those literals, update the filters here in lock-step (a stale filter would silently
#    route BOTH calls to one mock and quietly defeat the step-sequencing assertions).

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null
    . "$repoRoot/Tests/_TestHelpers/Test-Doubles.ps1"

    # Hoisted shared mock preamble for the locking/session-lifecycle contexts. Every context
    # previously re-inlined the same ~12 mocks; this installs the full "undo succeeds" set so a
    # context only re-Mocks the ONE seam it wants to vary. Parameters:
    #   -Notifications      drives the best-effort restore-notification gate (default off).
    #   -SessionPreexisted  $true => a session was already cached, so Undo borrows the caller's and
    #                       must NOT tear it down; $false => Undo creates (and thus owns) it.
    #   -FindResult / -UndoResult  override the two routed Invoke-SEBRemoteCommand return shapes.
    function Set-UndoHappyMocks {
        param(
            [bool]$Notifications = $false,
            [bool]$SessionPreexisted = $false,
            [hashtable]$FindResult,
            [hashtable]$UndoResult,
            [hashtable]$StopResult,
            [hashtable]$StartResult
        )

        if (-not $FindResult) {
            $FindResult = @{ Found = $true; Path = 'C:\Torch\Instance\Saves\MyWorld_prerestore_20260101_010101'; Name = 'MyWorld_prerestore_20260101_010101'; Error = $null }
        }
        if (-not $UndoResult) {
            $UndoResult = @{ Success = $true; PostRestorePath = 'C:\Torch\Instance\Saves\MyWorld_postrestore_20260101_010102'; Error = $null }
        }
        if (-not $StopResult) {
            $StopResult = @{ Stopped = $true; Method = 'service'; ErrorMessage = $null }
        }
        if (-not $StartResult) {
            $StartResult = @{ Started = $true; APIResponding = $true; ErrorMessage = $null }
        }

        Mock Write-SEBLog {} -ModuleName RestoreEngine

        Mock New-SEBLockFile -ModuleName RestoreEngine {
            [PSCustomObject]@{ Acquired = $true; LockFilePath = 'X:\lock'; Reason = $null; StaleLockBroken = $false }
        }
        Mock Remove-SEBLockFile -ModuleName RestoreEngine { $true }

        Mock Get-SEBGlobalConfig -ModuleName RestoreEngine { @{ notifications = @{ enabled = $Notifications; on_restore = $true } } }.GetNewClosure()
        Mock Get-SEBNodeConfig   -ModuleName RestoreEngine { @{ node = @{ hostname = 'node01' } } }
        Mock Test-SEBSessionExists -ModuleName RestoreEngine { $SessionPreexisted }.GetNewClosure()
        Mock New-SEBSession      -ModuleName RestoreEngine { New-FakeSession -Name 'SEBackup-node01' -Target 'node01' }
        Mock Remove-SEBSession   -ModuleName RestoreEngine {}
        Mock Get-SEBInstanceConfig -ModuleName RestoreEngine { @{ world_path = 'C:\Torch\Instance\Saves\MyWorld' } }
        Mock Stop-SEBTorchServer  -ModuleName RestoreEngine { $StopResult }.GetNewClosure()
        Mock Start-SEBTorchServer -ModuleName RestoreEngine { $StartResult }.GetNewClosure()
        Mock Send-SEBRestoreNotification -ModuleName RestoreEngine {}

        # Two Invoke-SEBRemoteCommand calls: the prerestore-find, then the rename undo. Distinguish
        # them by the script-block SOURCE TEXT via ParameterFilter (see file header for the markers).
        Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'prerestore_\*' } { $FindResult }.GetNewClosure()
        Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'postrestore' } { $UndoResult }.GetNewClosure()
    }

    # Builds a fresh on-disk sandbox (live world dir + a sibling _prerestore_ dir, each seeded with
    # sentinel content) for the rename/rollback body tests below. Defined here in the file-level
    # BeforeAll so it is visible inside the run-time It blocks (a function defined in a Describe body
    # would only exist at discovery time). Sentinel content lets each assertion tell whether the world
    # name ends up holding the LIVE world (rollback won) or the prerestore content.
    $script:liveContent = 'LIVE-WORLD-CONTENT'
    $script:preContent  = 'PRERESTORE-CONTENT'
    function New-UndoSandbox {
        $base = Join-Path ([System.IO.Path]::GetTempPath()) ("sebundo_" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $base -Force | Out-Null
        $worldDir = Join-Path $base 'MyWorld'
        $preDir   = Join-Path $base 'MyWorld_prerestore_20260101_010101'
        New-Item -ItemType Directory -Path $worldDir, $preDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $worldDir 'live.txt') -Value $script:liveContent -NoNewline
        Set-Content -LiteralPath (Join-Path $preDir  'pre.txt')   -Value $script:preContent  -NoNewline
        [PSCustomObject]@{ Base = $base; WorldDir = $worldDir; PreDir = $preDir }
    }
}

Describe 'Undo-SEBRestore locking and session lifecycle' {

    Context 'happy path (undo succeeds)' {
        BeforeAll {
            Set-UndoHappyMocks
        }

        It 'succeeds, acquires and releases the lock, and tears down its session' {
            $result = Undo-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena'

            $result.Success | Should -BeTrue
            Should -Invoke New-SEBLockFile  -ModuleName RestoreEngine -Times 1 -Exactly -ParameterFilter { $InstanceName -eq 'PvPArena' }
            Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 1 -Exactly -ParameterFilter { $InstanceName -eq 'PvPArena' }
            Should -Invoke Remove-SEBSession -ModuleName RestoreEngine -Times 1 -Exactly -ParameterFilter { $NodeName -eq 'node01' }
        }
    }

    Context 'undo fails partway (rename throws) but cleanup still runs' {
        BeforeAll {
            # The rename undo returns a failure result, which the function turns into a throw.
            Set-UndoHappyMocks -UndoResult @{ Success = $false; PostRestorePath = $null; Error = 'Failed to rename prerestore directory back: simulated' }
        }

        It 'reports failure but still releases the lock and tears down the session in finally' {
            $result = Undo-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena'

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Not -BeNullOrEmpty
            Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 1 -Exactly -ParameterFilter { $InstanceName -eq 'PvPArena' }
            Should -Invoke Remove-SEBSession -ModuleName RestoreEngine -Times 1 -Exactly -ParameterFilter { $NodeName -eq 'node01' }
        }
    }

    Context 'lock cannot be acquired' {
        BeforeAll {
            Set-UndoHappyMocks
            # Re-Mock the lock to be unacquirable; everything downstream must be unreached.
            Mock New-SEBLockFile -ModuleName RestoreEngine {
                [PSCustomObject]@{ Acquired = $false; LockFilePath = 'X:\lock'; Reason = 'already locked'; StaleLockBroken = $false }
            }
        }

        It 'aborts before touching the world and never creates a session or releases a lock it never held' {
            $result = Undo-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena'

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Match 'lock'

            # Never created a session, never ran a remote command against the world.
            Should -Invoke New-SEBSession  -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Invoke-SEBRemoteCommand  -ModuleName RestoreEngine -Times 0 -Exactly
            # Did not try to release a lock it never held, nor tear down a session it never made.
            Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Remove-SEBSession  -ModuleName RestoreEngine -Times 0 -Exactly
        }
    }

    Context 'no prerestore directory found -> structured failure before any rename' {
        BeforeAll {
            # The find returns Found=$false; the undo must NOT proceed to stop the server or rename.
            Set-UndoHappyMocks -FindResult @{ Found = $false; Path = $null; Error = "No prerestore directories found for 'MyWorld'." } `
                -UndoResult @{ Success = $true; PostRestorePath = 'unexpected'; Error = $null }
        }

        It 'fails with the no-prerestore error and never stops the server or runs the rename' {
            $result = Undo-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena'
            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Match 'No prerestore'
            # The find ran, but the server stop and the rename undo must not.
            Should -Invoke Stop-SEBTorchServer -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Invoke-SEBRemoteCommand -ModuleName RestoreEngine -Times 0 -Exactly -ParameterFilter { $ScriptBlock.ToString() -match 'postrestore' }
            # Lock + session still cleaned up.
            Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 1 -Exactly
            Should -Invoke Remove-SEBSession  -ModuleName RestoreEngine -Times 1 -Exactly
        }
    }

    Context 'stop server fails (non-manual) -> aborts before the rename, structured failure' {
        BeforeAll {
            # Stop fails with a non-manual method -> must abort before the world rename.
            Set-UndoHappyMocks -StopResult @{ Stopped = $false; Method = 'service'; ErrorMessage = 'service would not stop' } `
                -UndoResult @{ Success = $true; PostRestorePath = 'should-not-happen'; Error = $null }
        }

        It 'fails citing the stop and never runs the rename undo' {
            $result = Undo-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena'
            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Match 'stop Torch server'
            Should -Invoke Invoke-SEBRemoteCommand -ModuleName RestoreEngine -Times 0 -Exactly -ParameterFilter { $ScriptBlock.ToString() -match 'postrestore' }
            Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 1 -Exactly
            Should -Invoke Remove-SEBSession  -ModuleName RestoreEngine -Times 1 -Exactly
        }
    }

    Context 'caller already owned a session (preexisting cached session is preserved)' {
        BeforeAll {
            # A session for this node was ALREADY cached before Undo ran. New-SEBSession therefore
            # hands back the caller's existing session; Undo does NOT own it and must not remove it.
            Set-UndoHappyMocks -SessionPreexisted $true
        }

        It 'succeeds and releases the lock but does NOT tear down the caller-owned session' {
            $result = Undo-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena'

            $result.Success | Should -BeTrue
            # The lock is still always released.
            Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 1 -Exactly -ParameterFilter { $InstanceName -eq 'PvPArena' }
            # But the preexisting session belongs to the caller, so finally must leave it alone.
            Should -Invoke Remove-SEBSession -ModuleName RestoreEngine -Times 0 -Exactly
        }
    }

    Context 'happy path with notifications enabled sends an Undo restore notification' {
        BeforeAll {
            # notifications.enabled = $true so the best-effort restore notification fires.
            Set-UndoHappyMocks -Notifications $true
        }

        It 'succeeds and sends the Undo restore notification with InitiatedBy=Undo-SEBRestore' {
            $result = Undo-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena'
            $result.Success | Should -BeTrue
            $result.PostRestorePath | Should -Not -BeNullOrEmpty
            Should -Invoke Send-SEBRestoreNotification -ModuleName RestoreEngine -Times 1 -Exactly -ParameterFilter {
                $InstanceName -eq 'PvPArena' -and $InitiatedBy -eq 'Undo-SEBRestore' -and $RestorePoint -match 'Undo'
            }
        }
    }

    Context 'start server fails after a successful rename -> still reports Success (undo already done)' {
        BeforeAll {
            # The rename already completed; a failed START must NOT flip the undo to a failure (the
            # world was already swapped back -- reporting failure would be misleading).
            Set-UndoHappyMocks -StartResult @{ Started = $false; APIResponding = $false; ErrorMessage = 'torch.exe did not launch' }
        }

        It 'reports Success despite the start failure and still releases the lock + session' {
            $result = Undo-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena'
            # Decisive: the rename undo succeeded, so the overall undo is a success even though the
            # server failed to come back up (the operator restarts it manually).
            $result.Success | Should -BeTrue
            $result.PostRestorePath | Should -Not -BeNullOrEmpty
            Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 1 -Exactly
            Should -Invoke Remove-SEBSession  -ModuleName RestoreEngine -Times 1 -Exactly
        }
    }
}

# ===========================================================================================
# THE ROLLBACK SCRIPT BLOCK -- the single most dangerous path in the system, run for real.
# ===========================================================================================
# The undo's rename body (Undo-SEBRestore.ps1: move the live world aside to a _postrestore_ name,
# rename the _prerestore_ dir back to the world name, and ON A RENAME-BACK FAILURE roll the current
# world back into place) is node-local and runs inside a script block handed to Invoke-SEBRemoteCommand.
# The locking/lifecycle contexts above mock Invoke-SEBRemoteCommand to RETURN a canned result, so that
# body never executes there: deleting the rollback Rename-Item would not fail any of them.
#
# Pin the REAL body the way New-SEBManifest.Tests.ps1 pins its remote scan block: lift the literal
# script block out of the source via the AST and invoke it against REAL temp directories, with the
# rename-back FORCED to fail (an exclusive handle on a file inside the _prerestore_ dir makes Windows
# refuse to rename that directory). The decisive assertion is that the rollback puts the ORIGINAL live
# world content back under the world name -- NOT stranded under a _postrestore_ name. This runs the
# production code, not a copy: remove the rollback Rename-Item in the source and these go red (the
# live content ends up orphaned under _postrestore_ and the world name is left holding the prerestore
# dir's content, or nothing).
Describe 'Undo-SEBRestore rename/rollback body (real script block over temp dirs)' {

    BeforeAll {
        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $src = Join-Path $repoRoot 'Modules/RestoreEngine/Public/Undo-SEBRestore.ps1'

        # Lift the rename/rollback script block (the SECOND Invoke-SEBRemoteCommand call) straight out
        # of the source. Disambiguate from the prerestore-find block by the rename-specific markers
        # ('postRestoreName' + 'Rename-Item'); both are stable literals in the rollback body.
        $tokens = $null; $parseErrors = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$parseErrors)
        $invokeCalls = $fileAst.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-SEBRemoteCommand' },
            $true)
        $script:renameBlock = $null
        foreach ($call in $invokeCalls) {
            $sbExpr = $call.CommandElements |
                Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } |
                Select-Object -First 1
            if ($sbExpr -and $sbExpr.Extent.Text -match 'postRestoreName' -and $sbExpr.Extent.Text -match 'Rename-Item') {
                # GetScriptBlock() yields a real, invokable [scriptblock] from the AST node.
                $script:renameBlock = $sbExpr.ScriptBlock.GetScriptBlock()
                break
            }
        }
        if ($null -eq $script:renameBlock) {
            throw "Could not lift the rename/rollback script block from Undo-SEBRestore.ps1 (markers 'postRestoreName' + 'Rename-Item')."
        }
    }

    Context 'rename-back FAILS -> the live world is rolled back into place (not stranded)' {
        It 'returns a structured failure citing the rename-back' {
            $sb = New-UndoSandbox
            # Force the prerestore -> worldName rename to fail: hold an exclusive handle on a file
            # inside the prerestore dir so Windows refuses to rename that directory.
            $lockFile = Join-Path $sb.PreDir 'locked.bin'
            Set-Content -LiteralPath $lockFile -Value 'x' -NoNewline
            $fs = [System.IO.File]::Open($lockFile, 'Open', 'Read', 'None')
            try {
                $r = & $script:renameBlock -worldDir $sb.WorldDir -preRestorePath $sb.PreDir
            }
            finally { $fs.Close(); $fs.Dispose() }

            $r.Success | Should -BeFalse
            $r.Error   | Should -Match 'rename prerestore directory back'

            Remove-Item -LiteralPath $sb.Base -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'restores the ORIGINAL live world content under the world name (rollback ran)' {
            $sb = New-UndoSandbox
            $lockFile = Join-Path $sb.PreDir 'locked.bin'
            Set-Content -LiteralPath $lockFile -Value 'x' -NoNewline
            $fs = [System.IO.File]::Open($lockFile, 'Open', 'Read', 'None')
            try {
                & $script:renameBlock -worldDir $sb.WorldDir -preRestorePath $sb.PreDir | Out-Null
            }
            finally { $fs.Close(); $fs.Dispose() }

            $liveFile = Join-Path $sb.WorldDir 'live.txt'
            # DECISIVE (mutation target): the rollback Rename-Item must move the live world back under
            # the world name. Remove that line in the source and this fails -- the live content is
            # left orphaned under _postrestore_ and the world name no longer holds it.
            Test-Path -LiteralPath $sb.WorldDir | Should -BeTrue -Because 'the world directory must exist again after rollback'
            Test-Path -LiteralPath $liveFile    | Should -BeTrue -Because 'the original live world content must be rolled back under the world name'
            (Get-Content -LiteralPath $liveFile -Raw) | Should -Be $script:liveContent

            Remove-Item -LiteralPath $sb.Base -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'does NOT leave the original world stranded under a _postrestore_ name' {
            $sb = New-UndoSandbox
            $lockFile = Join-Path $sb.PreDir 'locked.bin'
            Set-Content -LiteralPath $lockFile -Value 'x' -NoNewline
            $fs = [System.IO.File]::Open($lockFile, 'Open', 'Read', 'None')
            try {
                & $script:renameBlock -worldDir $sb.WorldDir -preRestorePath $sb.PreDir | Out-Null
            }
            finally { $fs.Close(); $fs.Dispose() }

            # After a successful rollback the moved-aside copy is gone (renamed back), so no
            # _postrestore_ directory remains holding the live world.
            $stranded = @(Get-ChildItem -LiteralPath $sb.Base -Directory -Filter 'MyWorld_postrestore_*' -ErrorAction SilentlyContinue)
            $stranded.Count | Should -Be 0 -Because 'the rollback renamed the postrestore copy back to the world name'

            Remove-Item -LiteralPath $sb.Base -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'happy rename (both renames succeed) -> prerestore content lands under the world name' {
        It 'reports Success and the world now holds the prerestore content with a postrestore copy of the old world' {
            $sb = New-UndoSandbox
            $r = & $script:renameBlock -worldDir $sb.WorldDir -preRestorePath $sb.PreDir

            $r.Success         | Should -BeTrue
            $r.PostRestorePath | Should -Not -BeNullOrEmpty

            # The world name now holds what WAS the prerestore content (pre.txt), and the old live
            # world was moved aside under the returned _postrestore_ path.
            $preFileNowInWorld = Join-Path $sb.WorldDir 'pre.txt'
            Test-Path -LiteralPath $preFileNowInWorld | Should -BeTrue
            (Get-Content -LiteralPath $preFileNowInWorld -Raw) | Should -Be $script:preContent

            Test-Path -LiteralPath $r.PostRestorePath | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $r.PostRestorePath 'live.txt') -Raw) | Should -Be $script:liveContent

            Remove-Item -LiteralPath $sb.Base -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'no current world dir present -> renames prerestore back with no postrestore copy' {
        It 'reports Success with a null PostRestorePath (nothing to move aside)' {
            $sb = New-UndoSandbox
            # Remove the live world entirely: the block must skip the move-aside and just rename the
            # prerestore back, returning a null PostRestorePath.
            Remove-Item -LiteralPath $sb.WorldDir -Recurse -Force
            $r = & $script:renameBlock -worldDir $sb.WorldDir -preRestorePath $sb.PreDir

            $r.Success         | Should -BeTrue
            $r.PostRestorePath | Should -BeNullOrEmpty
            # The prerestore content is now under the world name.
            Test-Path -LiteralPath (Join-Path $sb.WorldDir 'pre.txt') | Should -BeTrue

            Remove-Item -LiteralPath $sb.Base -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
