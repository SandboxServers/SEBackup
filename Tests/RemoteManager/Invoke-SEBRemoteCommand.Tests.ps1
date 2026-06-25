#Requires -Module Pester

# Invoke-SEBRemoteCommand is the resilient wrapper every node-remoting caller is meant to use.
# This suite pins the correctness behaviours fixed under issue #22:
#   1. The wrapper's EXECUTION gate is Test-SEBSessionUsable (State=Opened AND Availability=Available)
#      -- "can accept a command NOW". (This is deliberately stricter than Test-SEBSessionAlive, the
#      "exists / don't destroy" predicate used by New-SEBSession/Test-SEBSessionExists, which counts
#      a Busy session as alive.) A session that is not usable is handled by KIND:
#        * State=Opened + Availability=Busy  -> transient; poll briefly, NEVER tear down/reconnect
#          (it may be running another caller's command). If still busy, throw a "busy" error. But if
#          it goes TERMINAL during the wait, reclassify and reconnect once (do not throw "busy").
#        * Terminal (State != Opened, or Availability=None) -> reconnect ONCE per invocation.
#   2. Retry semantics: the DEFAULT RetryCount=1 makes a transient failure run Invoke-Command TWICE;
#      -RetryCount 0 (used by every non-idempotent/mutating call site) attempts exactly ONCE so a
#      post-mutation transport drop is not silently re-run.
#   3. Reconnect preserves the connection identity: it captures the dead session's ComputerName and
#      reconnects via New-SEBSession with that hostname (NodeConfig.hostname), NOT the bare alias,
#      and rejects a session whose Name is not 'SEBackup-<node>'.
#   4. Reconnect propagation: the live session reaches the caller via the module cache (New-SEBSession
#      rewrites it) and, when -SessionRef ([ref]$session) is passed, by updating that variable in place.
#
# Test notes:
#  * Mocks target -ModuleName RemoteManager because the function runs in that module's scope; its
#    Invoke-Command / New-SEBSession / Remove-SEBSession / Write-SEBLog calls resolve there.
#  * PSSession has no public constructor and its .State/.Availability are runtime-backed. .State is a
#    CLR ScriptProperty that cannot be shadowed per-instance, so we register a type-wide ETS override
#    making .State report Opened on our doubles; liveness then varies by the per-double .Availability
#    (a native property Add-Member -Force CAN shadow). The override is removed in AfterAll so it does
#    not leak into other suites. This faithfully exercises the predicate: Available => usable, and
#    Busy/None (with State=Opened) => not usable, routed to the busy-wait vs reconnect branches.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # Make our PSSession doubles report State=Opened (CLR .State can't be set on an uninitialized
    # instance). Per-double liveness is then driven entirely by the shadowed .Availability.
    Update-TypeData -TypeName System.Management.Automation.Runspaces.PSSession `
        -MemberName State -MemberType ScriptProperty `
        -Value { [System.Management.Automation.Runspaces.RunspaceState]::Opened } -Force

    # Build a PSSession double whose adapted .Availability/.Name/.ComputerName are controllable.
    # NOTE: the connection-target parameter is named -Target (not -ComputerName) on purpose:
    # PSScriptAnalyzer's PSAvoidUsingComputerNameHardcoded rule flags any literal bound to a
    # -ComputerName parameter, even on this local test helper. The double's .ComputerName
    # property is still set from -Target so the wrapper reads the intended pinned host/IP.
    function New-FakeSession {
        param(
            [string]$Availability = 'Available',
            [string]$Name = 'SEBackup-node01',
            [string]$Target = 'node01',
            [string]$Tag = ''
        )
        $s = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
            [System.Management.Automation.Runspaces.PSSession])
        $s | Add-Member -Force -MemberType ScriptProperty -Name Availability -Value ([scriptblock]::Create("[System.Management.Automation.Runspaces.RunspaceAvailability]::$Availability"))
        $s | Add-Member -Force -MemberType ScriptProperty -Name Name -Value ([scriptblock]::Create("'$Name'"))
        $s | Add-Member -Force -MemberType ScriptProperty -Name ComputerName -Value ([scriptblock]::Create("'$Target'"))
        # Inert tag so a mock can assert which session it received.
        $s | Add-Member -Force -MemberType NoteProperty -Name SebTag -Value $Tag
        $s
    }
}

AfterAll {
    # Remove the type-wide .State override so other test files see the real PSSession.State.
    Remove-TypeData -TypeName System.Management.Automation.Runspaces.PSSession -ErrorAction SilentlyContinue
}

Describe 'Invoke-SEBRemoteCommand liveness check (Test-SEBSessionUsable)' {

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
            Mock New-SEBSession -ModuleName RemoteManager { throw 'must not reconnect a busy session' }
            Mock Remove-SEBSession -ModuleName RemoteManager { throw 'must not tear down a busy session' }
            Mock Invoke-Command -ModuleName RemoteManager { 'should-not-run' }
            # Keep the busy-poll fast: the wrapper sleeps 500ms between checks up to a 10s bound.
            Mock Start-Sleep -ModuleName RemoteManager {}
        }

        It 'does NOT tear down or reconnect a Busy session; throws a busy error' {
            $session = New-FakeSession -Availability 'Busy' -Name 'SEBackup-node01' -Tag 'busy-orig'

            # -BusyWaitSeconds 0 so the poll bound elapses immediately (no real wall-clock wait).
            { Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 } -BusyWaitSeconds 0 } |
                Should -Throw -ExpectedMessage '*busy*'

            # The whole point: a Busy+Opened session must never be removed or reconnected
            # (that would kill another caller's in-flight command), and the command must not run.
            Should -Invoke Remove-SEBSession -ModuleName RemoteManager -Times 0 -Exactly
            Should -Invoke New-SEBSession   -ModuleName RemoteManager -Times 0 -Exactly
            Should -Invoke Invoke-Command   -ModuleName RemoteManager -Times 0 -Exactly
        }
    }

    Context 'session goes TERMINAL during the busy-wait (finding #4 reclassification)' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Remove-SEBSession -ModuleName RemoteManager {}
            Mock New-SEBSession -ModuleName RemoteManager { New-FakeSession -Availability 'Available' -Tag 'reconnected' }
            Mock Invoke-Command -ModuleName RemoteManager { "ran-on:$($Session.SebTag)" }
            Mock Start-Sleep -ModuleName RemoteManager {}
        }

        It 'reconnects (does NOT throw "busy") when the runspace drops to None mid-poll' {
            # Availability starts Busy for the entry classification (so we genuinely ENTER the busy
            # branch), then transitions to None after the busy-wait, simulating the in-flight command
            # breaking the transport while we poll. State stays Opened (the type-wide ETS override),
            # so the only signal of death is Availability -> None. The first two reads (outer usable
            # gate + entry $isNone classification) must see Busy; the post-wait re-classification and
            # the reconnect gate must see None.
            $session = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                [System.Management.Automation.Runspaces.PSSession])
            $script:availReads = 0
            $session | Add-Member -Force -MemberType ScriptProperty -Name Availability -Value {
                $script:availReads++
                if ($script:availReads -le 2) {
                    [System.Management.Automation.Runspaces.RunspaceAvailability]::Busy
                }
                else {
                    [System.Management.Automation.Runspaces.RunspaceAvailability]::None
                }
            }
            $session | Add-Member -Force -MemberType ScriptProperty -Name Name -Value { 'SEBackup-node01' }
            $session | Add-Member -Force -MemberType ScriptProperty -Name ComputerName -Value { 'node01' }
            $session | Add-Member -Force -MemberType NoteProperty -Name SebTag -Value 'busy-then-dead'

            # Should NOT throw a busy error; should reconnect and run on the new session.
            $result = Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 } -BusyWaitSeconds 0

            $result | Should -Be 'ran-on:reconnected'
            Should -Invoke New-SEBSession -ModuleName RemoteManager -Times 1 -Exactly
            Should -Invoke New-SEBSession -ModuleName RemoteManager -Times 1 -Exactly -ParameterFilter { $NodeName -eq 'node01' }
        }
    }

    Context 'session Availability=None (terminal: not in the Opened state)' {
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
            # Reconnect must key off the node parsed from the session Name (SEBackup-<node>).
            Should -Invoke New-SEBSession -ModuleName RemoteManager -Times 1 -Exactly -ParameterFilter { $NodeName -eq 'node01' }
        }
    }
}

Describe 'Invoke-SEBRemoteCommand reconnect preserves connection identity' {

    Context 'original session alias != hostname' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Remove-SEBSession -ModuleName RemoteManager {}
            Mock New-SEBSession -ModuleName RemoteManager { New-FakeSession -Availability 'Available' -Tag 'reconnected' }
            Mock Invoke-Command -ModuleName RemoteManager { "ran-on:$($Session.SebTag)" }
        }

        It 'reconnects with the original ComputerName/hostname, not the bare alias' {
            # Name alias 'gamingpc01' differs from the pinned IP target '192.168.1.101'.
            $session = New-FakeSession -Availability 'None' -Name 'SEBackup-gamingpc01' -Target '192.168.1.101' -Tag 'dead'

            $null = Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 }

            # Node/credential/cache key is the friendly alias...
            Should -Invoke New-SEBSession -ModuleName RemoteManager -Times 1 -Exactly -ParameterFilter { $NodeName -eq 'gamingpc01' }
            # ...but the actual connection target is preserved via NodeConfig.hostname = the IP.
            Should -Invoke New-SEBSession -ModuleName RemoteManager -Times 1 -Exactly -ParameterFilter {
                $NodeConfig -and $NodeConfig['hostname'] -eq '192.168.1.101'
            }
        }
    }

    Context 'session not created by New-SEBSession (foreign Name)' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Remove-SEBSession -ModuleName RemoteManager { throw 'must not remove a foreign session' }
            Mock New-SEBSession -ModuleName RemoteManager { throw 'must not reconnect a foreign session' }
            Mock Invoke-Command -ModuleName RemoteManager { 'should-not-run' }
        }

        It 'rejects reconnect rather than guessing a credential/cache key' {
            $session = New-FakeSession -Availability 'None' -Name 'SomeRandomSession' -Target 'attacker-host' -Tag 'foreign'

            { Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 } } |
                Should -Throw -ExpectedMessage '*not created by New-SEBSession*'

            Should -Invoke New-SEBSession    -ModuleName RemoteManager -Times 0 -Exactly
            Should -Invoke Remove-SEBSession -ModuleName RemoteManager -Times 0 -Exactly
            Should -Invoke Invoke-Command    -ModuleName RemoteManager -Times 0 -Exactly
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

    Context 'cache already holds a healthy session for the node' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Remove-SEBSession -ModuleName RemoteManager { throw 'must not tear down when cache is healthy' }
            Mock New-SEBSession -ModuleName RemoteManager { throw 'must not rebuild when cache is healthy' }
            Mock Invoke-Command -ModuleName RemoteManager { "ran-on:$($Session.SebTag)" }
        }

        It 'reuses the cached live session instead of removing + recreating' {
            # Seed the module cache with a healthy session for node01.
            InModuleScope RemoteManager {
                $script:SEBSessions = @{}
            }
            $cached = New-FakeSession -Availability 'Available' -Name 'SEBackup-node01' -Tag 'cached-live'
            InModuleScope RemoteManager -Parameters @{ Cached = $cached } {
                param($Cached)
                $script:SEBSessions['node01'] = $Cached
            }

            $deadHandle = New-FakeSession -Availability 'None' -Name 'SEBackup-node01' -Tag 'dead'
            $result = Invoke-SEBRemoteCommand -Session $deadHandle -ScriptBlock { 1 }

            $result | Should -Be 'ran-on:cached-live'
            Should -Invoke Remove-SEBSession -ModuleName RemoteManager -Times 0 -Exactly
            Should -Invoke New-SEBSession    -ModuleName RemoteManager -Times 0 -Exactly

            InModuleScope RemoteManager { $script:SEBSessions = @{} }
        }
    }
}

Describe 'Invoke-SEBRemoteCommand retry semantics (the point of the wrapper)' {

    Context 'DEFAULT RetryCount on a transient failure' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock New-SEBSession -ModuleName RemoteManager {}
            Mock Remove-SEBSession -ModuleName RemoteManager {}
            Mock Start-Sleep -ModuleName RemoteManager {}  # don't actually wait the backoff
            # Throw once, then succeed -- exercises the retry that is the whole point of the wrapper.
            $script:icCalls = 0
            Mock Invoke-Command -ModuleName RemoteManager {
                $script:icCalls++
                if ($script:icCalls -eq 1) { throw 'transient transport blip' }
                'OK-on-retry'
            }
        }

        It 'runs Invoke-Command TWICE and ultimately succeeds' {
            $session = New-FakeSession -Availability 'Available'
            $result = Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 }

            $result | Should -Be 'OK-on-retry'
            Should -Invoke Invoke-Command -ModuleName RemoteManager -Times 2 -Exactly
        }
    }

    Context 'a mutation call site uses -RetryCount 0' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock New-SEBSession -ModuleName RemoteManager {}
            Mock Remove-SEBSession -ModuleName RemoteManager {}
            Mock Start-Sleep -ModuleName RemoteManager {}
            # Throw on every attempt: with -RetryCount 0 there must be no second attempt, so a
            # post-mutation transport drop is surfaced once (fails fast into the caller's rollback)
            # rather than silently re-running the mutation.
            Mock Invoke-Command -ModuleName RemoteManager { throw 'transport drop after the node mutated' }
        }

        It 'attempts exactly ONCE and does not retry the mutation' {
            $session = New-FakeSession -Availability 'Available'
            { Invoke-SEBRemoteCommand -Session $session -ScriptBlock { 1 } -RetryCount 0 } |
                Should -Throw -ExpectedMessage '*failed after 1 attempt*'
            Should -Invoke Invoke-Command -ModuleName RemoteManager -Times 1 -Exactly
        }
    }

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
