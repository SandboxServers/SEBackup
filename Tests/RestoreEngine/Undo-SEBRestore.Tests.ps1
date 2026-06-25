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
#  * The downstream helpers (Get-SEBInstanceConfig, Stop/Start-SEBTorchServer, Invoke-Command)
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
            Mock New-SEBSession -ModuleName RestoreEngine {
                [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                    [System.Management.Automation.Runspaces.PSSession])
            }
            Mock Remove-SEBSession -ModuleName RestoreEngine {}
            Mock Get-SEBInstanceConfig -ModuleName RestoreEngine { @{ world_path = 'C:\Torch\Instance\Saves\MyWorld' } }
            Mock Stop-SEBTorchServer -ModuleName RestoreEngine { @{ Stopped = $true; Method = 'service'; ErrorMessage = $null } }
            Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $true; APIResponding = $true; ErrorMessage = $null } }

            # Two Invoke-Command calls: the prerestore-find, then the rename undo. Distinguish
            # them by the script block text via ParameterFilter.
            Mock Invoke-Command -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'prerestore_\*' } {
                @{ Found = $true; Path = 'C:\Torch\Instance\Saves\MyWorld_prerestore_20260101_010101'; Name = 'MyWorld_prerestore_20260101_010101'; Error = $null }
            }
            Mock Invoke-Command -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'postrestore' } {
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
            Mock New-SEBSession -ModuleName RestoreEngine {
                [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                    [System.Management.Automation.Runspaces.PSSession])
            }
            Mock Remove-SEBSession -ModuleName RestoreEngine {}
            Mock Get-SEBInstanceConfig -ModuleName RestoreEngine { @{ world_path = 'C:\Torch\Instance\Saves\MyWorld' } }
            Mock Stop-SEBTorchServer -ModuleName RestoreEngine { @{ Stopped = $true; Method = 'service'; ErrorMessage = $null } }
            Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $true; APIResponding = $true; ErrorMessage = $null } }

            Mock Invoke-Command -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'prerestore_\*' } {
                @{ Found = $true; Path = 'C:\Torch\Instance\Saves\MyWorld_prerestore_20260101_010101'; Name = 'MyWorld_prerestore_20260101_010101'; Error = $null }
            }
            # The rename undo returns a failure result, which the function turns into a throw.
            Mock Invoke-Command -ModuleName RestoreEngine -ParameterFilter { $ScriptBlock.ToString() -match 'postrestore' } {
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
            Mock New-SEBSession -ModuleName RestoreEngine {
                [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                    [System.Management.Automation.Runspaces.PSSession])
            }
            Mock Remove-SEBSession -ModuleName RestoreEngine {}
            Mock Get-SEBInstanceConfig -ModuleName RestoreEngine { @{ world_path = 'C:\Torch\Instance\Saves\MyWorld' } }
            Mock Stop-SEBTorchServer -ModuleName RestoreEngine { @{ Stopped = $true; Method = 'service'; ErrorMessage = $null } }
            Mock Start-SEBTorchServer -ModuleName RestoreEngine { @{ Started = $true; APIResponding = $true; ErrorMessage = $null } }
            Mock Invoke-Command -ModuleName RestoreEngine { @{} }
        }

        It 'aborts before touching the world and never creates a session or releases a lock it never held' {
            $result = Undo-SEBRestore -NodeName 'node01' -InstanceName 'PvPArena'

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Match 'lock'

            # Never created a session, never ran a remote command against the world.
            Should -Invoke New-SEBSession  -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Invoke-Command  -ModuleName RestoreEngine -Times 0 -Exactly
            # Did not try to release a lock it never held, nor tear down a session it never made.
            Should -Invoke Remove-SEBLockFile -ModuleName RestoreEngine -Times 0 -Exactly
            Should -Invoke Remove-SEBSession  -ModuleName RestoreEngine -Times 0 -Exactly
        }
    }
}
