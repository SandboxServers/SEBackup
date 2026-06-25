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
#    public constructor, so the New-SEBSession mock returns an *uninitialized* PSSession instance
#    (which satisfies the cast). Its internals are never touched because every consumer is mocked.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null
}

Describe 'Undo-SEBRestore locking and session lifecycle' {

    Context 'happy path (undo succeeds)' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RestoreEngine

            Mock New-SEBLockFile -ModuleName RestoreEngine {
                [PSCustomObject]@{ Acquired = $true; LockFilePath = 'X:\lock'; Reason = $null; StaleLockBroken = $false }
            }
            Mock Remove-SEBLockFile -ModuleName RestoreEngine { $true }

            Mock Get-SEBGlobalConfig -ModuleName RestoreEngine { @{ notifications = @{ enabled = $false } } }
            Mock Get-SEBNodeConfig -ModuleName RestoreEngine { @{ node = @{ hostname = 'node01' } } }
            # No session was cached before Undo runs, so Undo creates (and thus owns) it.
            Mock Test-SEBSessionExists -ModuleName RestoreEngine { $false }
            Mock New-SEBSession -ModuleName RestoreEngine {
                [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                    [System.Management.Automation.Runspaces.PSSession])
            }
            Mock Remove-SEBSession -ModuleName RestoreEngine {}
            Mock Get-SEBInstanceConfig -ModuleName RestoreEngine { @{ world_path = 'C:\Torch\Instance\Saves\MyWorld' } }
            Mock Stop-SEBTorchServer -ModuleName RestoreEngine { @{ Stopped = $true; Method = 'service'; ErrorMessage = $null } }
            Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $true; APIResponding = $true; ErrorMessage = $null } }

            # Two Invoke-SEBRemoteCommand calls: the prerestore-find, then the rename undo. Distinguish
            # them by the script block text via ParameterFilter.
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'prerestore_\*' } {
                @{ Found = $true; Path = 'C:\Torch\Instance\Saves\MyWorld_prerestore_20260101_010101'; Name = 'MyWorld_prerestore_20260101_010101'; Error = $null }
            }
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'postrestore' } {
                @{ Success = $true; PostRestorePath = 'C:\Torch\Instance\Saves\MyWorld_postrestore_20260101_010102'; Error = $null }
            }
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
            Mock Write-SEBLog {} -ModuleName RestoreEngine

            Mock New-SEBLockFile -ModuleName RestoreEngine {
                [PSCustomObject]@{ Acquired = $true; LockFilePath = 'X:\lock'; Reason = $null; StaleLockBroken = $false }
            }
            Mock Remove-SEBLockFile -ModuleName RestoreEngine { $true }

            Mock Get-SEBGlobalConfig -ModuleName RestoreEngine { @{ notifications = @{ enabled = $false } } }
            Mock Get-SEBNodeConfig -ModuleName RestoreEngine { @{ node = @{ hostname = 'node01' } } }
            # No session was cached before Undo runs, so Undo creates (and thus owns) it.
            Mock Test-SEBSessionExists -ModuleName RestoreEngine { $false }
            Mock New-SEBSession -ModuleName RestoreEngine {
                [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                    [System.Management.Automation.Runspaces.PSSession])
            }
            Mock Remove-SEBSession -ModuleName RestoreEngine {}
            Mock Get-SEBInstanceConfig -ModuleName RestoreEngine { @{ world_path = 'C:\Torch\Instance\Saves\MyWorld' } }
            Mock Stop-SEBTorchServer -ModuleName RestoreEngine { @{ Stopped = $true; Method = 'service'; ErrorMessage = $null } }
            Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $true; APIResponding = $true; ErrorMessage = $null } }

            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'prerestore_\*' } {
                @{ Found = $true; Path = 'C:\Torch\Instance\Saves\MyWorld_prerestore_20260101_010101'; Name = 'MyWorld_prerestore_20260101_010101'; Error = $null }
            }
            # The rename undo returns a failure result, which the function turns into a throw.
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'postrestore' } {
                @{ Success = $false; PostRestorePath = $null; Error = 'Failed to rename prerestore directory back: simulated' }
            }
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
            Mock Write-SEBLog {} -ModuleName RestoreEngine

            Mock New-SEBLockFile -ModuleName RestoreEngine {
                [PSCustomObject]@{ Acquired = $false; LockFilePath = 'X:\lock'; Reason = 'already locked'; StaleLockBroken = $false }
            }
            Mock Remove-SEBLockFile -ModuleName RestoreEngine { $true }

            # None of these must be reached when the lock cannot be acquired.
            Mock Get-SEBGlobalConfig -ModuleName RestoreEngine { @{ notifications = @{ enabled = $false } } }
            Mock Get-SEBNodeConfig -ModuleName RestoreEngine { @{ node = @{ hostname = 'node01' } } }
            Mock Test-SEBSessionExists -ModuleName RestoreEngine { $false }
            Mock New-SEBSession -ModuleName RestoreEngine {
                [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                    [System.Management.Automation.Runspaces.PSSession])
            }
            Mock Remove-SEBSession -ModuleName RestoreEngine {}
            Mock Get-SEBInstanceConfig -ModuleName RestoreEngine { @{ world_path = 'C:\Torch\Instance\Saves\MyWorld' } }
            Mock Stop-SEBTorchServer -ModuleName RestoreEngine { @{ Stopped = $true; Method = 'service'; ErrorMessage = $null } }
            Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $true; APIResponding = $true; ErrorMessage = $null } }
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine { @{} }
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
            Mock Write-SEBLog {} -ModuleName RestoreEngine
            Mock New-SEBLockFile -ModuleName RestoreEngine {
                [PSCustomObject]@{ Acquired = $true; LockFilePath = 'X:\lock'; Reason = $null; StaleLockBroken = $false }
            }
            Mock Remove-SEBLockFile -ModuleName RestoreEngine { $true }
            Mock Get-SEBGlobalConfig -ModuleName RestoreEngine { @{ notifications = @{ enabled = $false } } }
            Mock Get-SEBNodeConfig -ModuleName RestoreEngine { @{ node = @{ hostname = 'node01' } } }
            Mock Test-SEBSessionExists -ModuleName RestoreEngine { $false }
            Mock New-SEBSession -ModuleName RestoreEngine {
                [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                    [System.Management.Automation.Runspaces.PSSession])
            }
            Mock Remove-SEBSession -ModuleName RestoreEngine {}
            Mock Get-SEBInstanceConfig -ModuleName RestoreEngine { @{ world_path = 'C:\Torch\Instance\Saves\MyWorld' } }
            Mock Stop-SEBTorchServer -ModuleName RestoreEngine { @{ Stopped = $true; Method = 'service'; ErrorMessage = $null } }
            Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $true; APIResponding = $true; ErrorMessage = $null } }

            # The find returns Found=$false; the undo must NOT proceed to stop the server or rename.
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'prerestore_\*' } {
                @{ Found = $false; Path = $null; Error = "No prerestore directories found for 'MyWorld'." }
            }
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'postrestore' } {
                @{ Success = $true; PostRestorePath = 'unexpected'; Error = $null }
            }
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
            Mock Write-SEBLog {} -ModuleName RestoreEngine
            Mock New-SEBLockFile -ModuleName RestoreEngine {
                [PSCustomObject]@{ Acquired = $true; LockFilePath = 'X:\lock'; Reason = $null; StaleLockBroken = $false }
            }
            Mock Remove-SEBLockFile -ModuleName RestoreEngine { $true }
            Mock Get-SEBGlobalConfig -ModuleName RestoreEngine { @{ notifications = @{ enabled = $false } } }
            Mock Get-SEBNodeConfig -ModuleName RestoreEngine { @{ node = @{ hostname = 'node01' } } }
            Mock Test-SEBSessionExists -ModuleName RestoreEngine { $false }
            Mock New-SEBSession -ModuleName RestoreEngine {
                [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                    [System.Management.Automation.Runspaces.PSSession])
            }
            Mock Remove-SEBSession -ModuleName RestoreEngine {}
            Mock Get-SEBInstanceConfig -ModuleName RestoreEngine { @{ world_path = 'C:\Torch\Instance\Saves\MyWorld' } }
            # Stop fails with a non-manual method -> must abort before the world rename.
            Mock Stop-SEBTorchServer -ModuleName RestoreEngine { @{ Stopped = $false; Method = 'service'; ErrorMessage = 'service would not stop' } }
            Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $true; APIResponding = $true; ErrorMessage = $null } }
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'prerestore_\*' } {
                @{ Found = $true; Path = 'C:\Torch\Instance\Saves\MyWorld_prerestore_20260101_010101'; Name = 'MyWorld_prerestore_20260101_010101'; Error = $null }
            }
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'postrestore' } {
                @{ Success = $true; PostRestorePath = 'should-not-happen'; Error = $null }
            }
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
            Mock Write-SEBLog {} -ModuleName RestoreEngine

            Mock New-SEBLockFile -ModuleName RestoreEngine {
                [PSCustomObject]@{ Acquired = $true; LockFilePath = 'X:\lock'; Reason = $null; StaleLockBroken = $false }
            }
            Mock Remove-SEBLockFile -ModuleName RestoreEngine { $true }

            Mock Get-SEBGlobalConfig -ModuleName RestoreEngine { @{ notifications = @{ enabled = $false } } }
            Mock Get-SEBNodeConfig -ModuleName RestoreEngine { @{ node = @{ hostname = 'node01' } } }
            # A session for this node was ALREADY cached before Undo ran. New-SEBSession
            # therefore hands back the caller's existing session; Undo does NOT own it.
            Mock Test-SEBSessionExists -ModuleName RestoreEngine { $true }
            Mock New-SEBSession -ModuleName RestoreEngine {
                [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                    [System.Management.Automation.Runspaces.PSSession])
            }
            Mock Remove-SEBSession -ModuleName RestoreEngine {}
            Mock Get-SEBInstanceConfig -ModuleName RestoreEngine { @{ world_path = 'C:\Torch\Instance\Saves\MyWorld' } }
            Mock Stop-SEBTorchServer -ModuleName RestoreEngine { @{ Stopped = $true; Method = 'service'; ErrorMessage = $null } }
            Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $true; APIResponding = $true; ErrorMessage = $null } }

            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'prerestore_\*' } {
                @{ Found = $true; Path = 'C:\Torch\Instance\Saves\MyWorld_prerestore_20260101_010101'; Name = 'MyWorld_prerestore_20260101_010101'; Error = $null }
            }
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'postrestore' } {
                @{ Success = $true; PostRestorePath = 'C:\Torch\Instance\Saves\MyWorld_postrestore_20260101_010102'; Error = $null }
            }
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
            Mock Write-SEBLog {} -ModuleName RestoreEngine
            Mock New-SEBLockFile -ModuleName RestoreEngine {
                [PSCustomObject]@{ Acquired = $true; LockFilePath = 'X:\lock'; Reason = $null; StaleLockBroken = $false }
            }
            Mock Remove-SEBLockFile -ModuleName RestoreEngine { $true }
            # notifications.enabled = $true so the best-effort restore notification fires.
            Mock Get-SEBGlobalConfig -ModuleName RestoreEngine { @{ notifications = @{ enabled = $true; on_restore = $true } } }
            Mock Get-SEBNodeConfig -ModuleName RestoreEngine { @{ node = @{ hostname = 'node01' } } }
            Mock Test-SEBSessionExists -ModuleName RestoreEngine { $false }
            Mock New-SEBSession -ModuleName RestoreEngine {
                [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                    [System.Management.Automation.Runspaces.PSSession])
            }
            Mock Remove-SEBSession -ModuleName RestoreEngine {}
            Mock Get-SEBInstanceConfig -ModuleName RestoreEngine { @{ world_path = 'C:\Torch\Instance\Saves\MyWorld' } }
            Mock Stop-SEBTorchServer -ModuleName RestoreEngine { @{ Stopped = $true; Method = 'service'; ErrorMessage = $null } }
            Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $true; APIResponding = $true; ErrorMessage = $null } }
            Mock Send-SEBRestoreNotification -ModuleName RestoreEngine {}
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'prerestore_\*' } {
                @{ Found = $true; Path = 'C:\Torch\Instance\Saves\MyWorld_prerestore_20260101_010101'; Name = 'MyWorld_prerestore_20260101_010101'; Error = $null }
            }
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'postrestore' } {
                @{ Success = $true; PostRestorePath = 'C:\Torch\Instance\Saves\MyWorld_postrestore_20260101_010102'; Error = $null }
            }
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
            Mock Write-SEBLog {} -ModuleName RestoreEngine
            Mock New-SEBLockFile -ModuleName RestoreEngine {
                [PSCustomObject]@{ Acquired = $true; LockFilePath = 'X:\lock'; Reason = $null; StaleLockBroken = $false }
            }
            Mock Remove-SEBLockFile -ModuleName RestoreEngine { $true }
            Mock Get-SEBGlobalConfig -ModuleName RestoreEngine { @{ notifications = @{ enabled = $false } } }
            Mock Get-SEBNodeConfig -ModuleName RestoreEngine { @{ node = @{ hostname = 'node01' } } }
            Mock Test-SEBSessionExists -ModuleName RestoreEngine { $false }
            Mock New-SEBSession -ModuleName RestoreEngine {
                [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                    [System.Management.Automation.Runspaces.PSSession])
            }
            Mock Remove-SEBSession -ModuleName RestoreEngine {}
            Mock Get-SEBInstanceConfig -ModuleName RestoreEngine { @{ world_path = 'C:\Torch\Instance\Saves\MyWorld' } }
            Mock Stop-SEBTorchServer -ModuleName RestoreEngine { @{ Stopped = $true; Method = 'service'; ErrorMessage = $null } }
            # The rename already completed; a failed START must NOT flip the undo to a failure (the
            # world was already swapped back -- reporting failure would be misleading).
            Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $false; APIResponding = $false; ErrorMessage = 'torch.exe did not launch' } }
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'prerestore_\*' } {
                @{ Found = $true; Path = 'C:\Torch\Instance\Saves\MyWorld_prerestore_20260101_010101'; Name = 'MyWorld_prerestore_20260101_010101'; Error = $null }
            }
            Mock Invoke-SEBRemoteCommand -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'postrestore' } {
                @{ Success = $true; PostRestorePath = 'C:\Torch\Instance\Saves\MyWorld_postrestore_20260101_010102'; Error = $null }
            }
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
