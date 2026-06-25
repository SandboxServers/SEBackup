#Requires -Module Pester

# Invoke-SEBWithShadowCopy wraps a remote operation in a VSS create -> mount -> run -> (always)
# dismount + remove lifecycle. This suite pins the issue #22 re-review fix for the VSS LEAK:
#
#   The finally block refreshes $Session from the cache before cleanup. New-SEBSession can THROW
#   (cache miss whose recreate fails -- e.g. the node went unreachable, the very failure that just
#   killed the capture). If that throw escaped the finally it would skip Dismount/Remove and LEAK
#   the mounted snapshot symlink + the VSS shadow copy. The fix wraps the refresh in a non-throwing
#   helper so cleanup ALWAYS runs. This test proves: user block throws + New-SEBSession throws in
#   the finally => Dismount-SEBShadowCopy AND Remove-SEBShadowCopy are STILL invoked.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # PSSession double with a SEBackup-<node> Name so the function parses a $cacheNode and therefore
    # ENTERS the cache-refresh path (incl. the finally refresh under test).
    function New-FakeSession {
        param([string]$Name = 'SEBackup-node01', [string]$Target = '192.168.1.101')
        $s = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
            [System.Management.Automation.Runspaces.PSSession])
        $s | Add-Member -Force -MemberType ScriptProperty -Name Name -Value ([scriptblock]::Create("'$Name'"))
        $s | Add-Member -Force -MemberType ScriptProperty -Name ComputerName -Value ([scriptblock]::Create("'$Target'"))
        $s
    }
}

Describe 'Invoke-SEBWithShadowCopy always cleans up even if the finally refresh throws' {

    Context 'user block throws AND New-SEBSession throws in the finally (node unreachable)' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName VSSManager
            # Create + mount succeed so we reach the user block and arm the cleanup flags.
            Mock New-SEBShadowCopy -ModuleName VSSManager { @{ DeviceObject = '\\?\GLOBALROOT\Device\X'; ShadowID = '{SHADOW-1}' } }
            Mock Mount-SEBShadowCopy -ModuleName VSSManager { $true }
            # The raw central capture (Invoke-Command on $Session) dies mid-capture.
            Mock Invoke-Command -ModuleName VSSManager { throw 'transport dropped during world capture' }
            # Every cache refresh (post-create, post-mount, and the finally) throws -- the exact
            # unreachable-node failure the fix must tolerate without skipping cleanup.
            Mock New-SEBSession -ModuleName VSSManager { throw 'WinRM unreachable: cannot recreate session' }
            # Cleanup sub-calls: record that they were reached. Return $true (success path).
            Mock Dismount-SEBShadowCopy -ModuleName VSSManager { $true }
            Mock Remove-SEBShadowCopy -ModuleName VSSManager { $true }
        }

        It 'STILL invokes Dismount-SEBShadowCopy and Remove-SEBShadowCopy (no VSS leak)' {
            $session = New-FakeSession -Name 'SEBackup-node01' -Target '192.168.1.101'

            # The user block's throw propagates out (the function does not swallow it), but the
            # finally must have run cleanup first. Assert the throw, then the cleanup invocations.
            { Invoke-SEBWithShadowCopy -Volume 'C:\' -MountBase 'C:\Temp\SEBMounts' -Session $session -ScriptBlock {
                param($MountPoint) throw 'user block boom'
            } } | Should -Throw

            Should -Invoke Dismount-SEBShadowCopy -ModuleName VSSManager -Times 1 -Exactly
            Should -Invoke Remove-SEBShadowCopy   -ModuleName VSSManager -Times 1 -Exactly
            # Sanity: the finally refresh really did attempt (and throw) -- proving the non-throwing
            # guard is what kept cleanup alive, not an absence of the refresh.
            Should -Invoke New-SEBSession -ModuleName VSSManager -Times 1
        }
    }

    Context 'happy path still dismounts and removes' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName VSSManager
            Mock New-SEBShadowCopy -ModuleName VSSManager { @{ DeviceObject = '\\?\GLOBALROOT\Device\X'; ShadowID = '{SHADOW-2}' } }
            Mock Mount-SEBShadowCopy -ModuleName VSSManager { $true }
            Mock Invoke-Command -ModuleName VSSManager { 'capture-ok' }
            # Refresh succeeds and returns the same live handle.
            Mock New-SEBSession -ModuleName VSSManager { New-FakeSession -Name 'SEBackup-node01' -Target '192.168.1.101' }
            Mock Dismount-SEBShadowCopy -ModuleName VSSManager { $true }
            Mock Remove-SEBShadowCopy -ModuleName VSSManager { $true }
        }

        It 'returns the capture result and cleans up' {
            $session = New-FakeSession
            $result = Invoke-SEBWithShadowCopy -Volume 'C:\' -MountBase 'C:\Temp\SEBMounts' -Session $session -ScriptBlock {
                param($MountPoint) 'unused'
            }
            $result | Should -Be 'capture-ok'
            Should -Invoke Dismount-SEBShadowCopy -ModuleName VSSManager -Times 1 -Exactly
            Should -Invoke Remove-SEBShadowCopy   -ModuleName VSSManager -Times 1 -Exactly
        }
    }
}
