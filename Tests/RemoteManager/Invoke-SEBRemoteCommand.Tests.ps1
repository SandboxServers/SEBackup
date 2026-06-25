#Requires -Module Pester

# Invoke-SEBRemoteCommand is the resilient wrapper every node-remoting caller is meant to use.
# This suite pins the two correctness behaviours fixed under issue #22:
#   1. Liveness is decided by .Availability (RunspaceAvailability), not just .State. A session can
#      be State=Opened yet Availability=Busy/None and unable to accept a command; that must trigger
#      the reconnect path, and an Available session must be used as-is.
#   2. Reconnect propagation: when a dead session is reconnected, the live session reaches the
#      caller -- both through the module session cache (which New-SEBSession rewrites) and, when the
#      caller passes -SessionRef ([ref]$session), by updating that variable in place so the caller's
#      subsequent -Session $session calls use the live handle.
#
# Test notes:
#  * Mocks target -ModuleName RemoteManager because the function runs in that module's scope; its
#    Invoke-Command / New-SEBSession / Remove-SEBSession / Write-SEBLog calls resolve there.
#  * PSSession has no public constructor and its .State/.Availability are runtime-backed, so we
#    build doubles with GetUninitializedObject (satisfies the [PSSession] parameter cast) and shadow
#    .State/.Availability/.Name/.ComputerName with Add-Member ScriptProperty (-Force). PowerShell's
#    adapted type system honours the shadow when the wrapper reads $Session.Availability.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # Build a PSSession double whose adapted .Availability/.Name/.ComputerName are controllable.
    # NOTE on .State: on a PSSession it is itself a ScriptProperty (not a native CLR property), so
    # Add-Member -Force cannot shadow it. We deliberately do not set it -- the wrapper decides
    # liveness from .Availability and only reads .State for log text, so leaving it empty is fine.
    # .Availability / .Name / .ComputerName ARE native properties and Add-Member -Force shadows them.
    function New-FakeSession {
        param(
            [string]$Availability = 'Available',
            [string]$Name = 'SEBackup-node01',
            [string]$ComputerName = 'node01',
            [string]$Tag = ''
        )
        $s = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
            [System.Management.Automation.Runspaces.PSSession])
        $s | Add-Member -Force -MemberType ScriptProperty -Name Availability -Value ([scriptblock]::Create("[System.Management.Automation.Runspaces.RunspaceAvailability]::$Availability"))
        $s | Add-Member -Force -MemberType ScriptProperty -Name Name -Value ([scriptblock]::Create("'$Name'"))
        $s | Add-Member -Force -MemberType ScriptProperty -Name ComputerName -Value ([scriptblock]::Create("'$ComputerName'"))
        # Inert tag so a mock can assert which session it received.
        $s | Add-Member -Force -MemberType NoteProperty -Name SebTag -Value $Tag
        $s
    }
}

Describe 'Invoke-SEBRemoteCommand liveness check (.Availability)' {

    Context 'session is Available' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock New-SEBSession -ModuleName RemoteManager { throw 'should not reconnect an Available session' }
            Mock Remove-SEBSession -ModuleName RemoteManager { throw 'should not remove an Available session' }
            Mock Invoke-Command -ModuleName RemoteManager { 'OK-from-original' }
        }

        It 'runs the command directly and does not reconnect' {
            $session = New-FakeSession -Availability 'Available' -Tag 'orig'
            $result = Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 }

            $result | Should -Be 'OK-from-original'
            Should -Invoke Invoke-Command -ModuleName RemoteManager -Times 1 -Exactly
            Should -Invoke New-SEBSession  -ModuleName RemoteManager -Times 0 -Exactly
            Should -Invoke Remove-SEBSession -ModuleName RemoteManager -Times 0 -Exactly
        }
    }

    Context 'session is Opened but Availability=Busy' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Remove-SEBSession -ModuleName RemoteManager {}
            # Reconnect yields a fresh Available session tagged so we can prove the command ran on it.
            Mock New-SEBSession -ModuleName RemoteManager { New-FakeSession -Availability 'Available' -Tag 'reconnected' }
            Mock Invoke-Command -ModuleName RemoteManager {
                # Echo which session the wrapper handed to Invoke-Command.
                "ran-on:$($Session.SebTag)"
            }
        }

        It 'treats Busy as unusable, reconnects, and runs on the new session' {
            $session = New-FakeSession -Availability 'Busy' -Name 'SEBackup-node01' -Tag 'busy-orig'
            $result = Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 }

            $result | Should -Be 'ran-on:reconnected'
            Should -Invoke New-SEBSession   -ModuleName RemoteManager -Times 1 -Exactly
            Should -Invoke Remove-SEBSession -ModuleName RemoteManager -Times 1 -Exactly
            # Reconnect must key off the node parsed from the session Name (SEBackup-<node>).
            Should -Invoke New-SEBSession -ModuleName RemoteManager -Times 1 -Exactly -ParameterFilter { $NodeName -eq 'node01' }
        }
    }

    Context 'session Availability=None (default of an unopened session)' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Remove-SEBSession -ModuleName RemoteManager {}
            Mock New-SEBSession -ModuleName RemoteManager { New-FakeSession -Availability 'Available' -Tag 'reconnected' }
            Mock Invoke-Command -ModuleName RemoteManager { "ran-on:$($Session.SebTag)" }
        }

        It 'reconnects and runs on the new session' {
            $session = New-FakeSession -Availability 'None' -Tag 'none-orig'
            $result = Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 }

            $result | Should -Be 'ran-on:reconnected'
            Should -Invoke New-SEBSession -ModuleName RemoteManager -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-SEBRemoteCommand reconnect propagation' {

    Context 'caller passes -SessionRef and the session is dead' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Remove-SEBSession -ModuleName RemoteManager {}
            Mock New-SEBSession -ModuleName RemoteManager { New-FakeSession -Availability 'Available' -Tag 'reconnected' }
            Mock Invoke-Command -ModuleName RemoteManager { "ran-on:$($Session.SebTag)" }
        }

        It 'writes the live session back into the caller variable' {
            $session = New-FakeSession -Availability 'None' -Tag 'dead-orig'
            $before = $session.SebTag

            $result = Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 } -SessionRef ([ref]$session)

            $before | Should -Be 'dead-orig'
            $result | Should -Be 'ran-on:reconnected'
            # The caller's own variable now references the reconnected, live session.
            $session.SebTag | Should -Be 'reconnected'
            $session.Availability | Should -Be ([System.Management.Automation.Runspaces.RunspaceAvailability]::Available)
        }
    }

    Context 'caller does NOT pass -SessionRef' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Remove-SEBSession -ModuleName RemoteManager {}
            Mock New-SEBSession -ModuleName RemoteManager { New-FakeSession -Availability 'Available' -Tag 'reconnected' }
            Mock Invoke-Command -ModuleName RemoteManager { "ran-on:$($Session.SebTag)" }
        }

        It 'still reconnects and runs successfully (cache-based propagation path)' {
            $session = New-FakeSession -Availability 'None' -Tag 'dead-orig'
            { Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 } } | Should -Not -Throw
            Should -Invoke New-SEBSession -ModuleName RemoteManager -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-SEBRemoteCommand error and retry semantics' {

    Context 'reconnection itself fails' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Remove-SEBSession -ModuleName RemoteManager {}
            Mock New-SEBSession -ModuleName RemoteManager { throw 'WinRM unreachable' }
            Mock Invoke-Command -ModuleName RemoteManager { 'unreached' }
        }

        It 'throws a reconnection-failed error and never runs the command' {
            $session = New-FakeSession -Availability 'None'
            { Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 } } |
                Should -Throw -ExpectedMessage '*reconnection failed*'
            Should -Invoke Invoke-Command -ModuleName RemoteManager -Times 0 -Exactly
        }
    }

    Context 'command fails on an Available session with RetryCount 0' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock New-SEBSession -ModuleName RemoteManager {}
            Mock Remove-SEBSession -ModuleName RemoteManager {}
            Mock Invoke-Command -ModuleName RemoteManager { throw 'remote boom' }
        }

        It 'attempts exactly once and throws an exhausted-attempts error' {
            $session = New-FakeSession -Availability 'Available'
            { Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 } -RetryCount 0 } |
                Should -Throw -ExpectedMessage '*failed after 1 attempt*'
            Should -Invoke Invoke-Command -ModuleName RemoteManager -Times 1 -Exactly
        }
    }

    Context 'passes ArgumentList through to Invoke-Command' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock New-SEBSession -ModuleName RemoteManager {}
            Mock Remove-SEBSession -ModuleName RemoteManager {}
            Mock Invoke-Command -ModuleName RemoteManager { $ArgumentList -join ',' }
        }

        It 'forwards the arguments unchanged' {
            $session = New-FakeSession -Availability 'Available'
            $result = Invoke-SEBRemoteCommand -Session $session -ScriptBlock { param($a, $b) "$a$b" } -ArgumentList 'x', 'y'
            $result | Should -Be 'x,y'
        }
    }
}
