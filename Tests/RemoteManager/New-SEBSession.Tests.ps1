#Requires -Module Pester

# The mocked Get-SEBCredential returns a PSCredential built from a throwaway in-test password; the
# only way to make a SecureString from a literal in a test is ConvertTo-SecureString -AsPlainText,
# so suppress that rule for this fixture file only (the credential is never used -- New-PSSession is
# mocked). No production code uses this pattern.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Test fixture credential; New-PSSession is mocked so the secret is inert.')]
param()

# New-SEBSession is the single point that opens (or reuses) a per-node PSSession. This suite pins
# the issue #22 re-review fixes:
#   1. HOSTNAME MEMORY (the root fix for the NodeConfig-drop bug class): New-SEBSession remembers
#      each node's resolved connection target in $script:SEBSessionHosts. When it is later called
#      WITHOUT -NodeConfig and must (re)create (cache miss or a DEAD cache entry), it connects to the
#      remembered host -- NOT the bare friendly alias. This is what makes every NodeConfig-less
#      refresh/reconnect site target the pinned IP/FQDN.
#   2. ALIVE-not-USABLE cache reuse: a cached session that is Busy (State=Opened, Availability=Busy)
#      because another caller is mid-command on the shared handle is REUSED (Test-SEBSessionAlive),
#      not torn down and rebuilt (which would abort that command and re-key the cache).
#
# Test mechanics mirror Invoke-SEBRemoteCommand.Tests.ps1: PSSession has no public ctor, so we build
# uninitialized doubles and shadow .State (type-wide ETS) / .Availability / .Name / .ComputerName.
# New-PSSession and Get-SEBCredential are mocked in RemoteManager scope so no real WinRM is touched.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    Update-TypeData -TypeName System.Management.Automation.Runspaces.PSSession `
        -MemberName State -MemberType ScriptProperty `
        -Value { [System.Management.Automation.Runspaces.RunspaceState]::Opened } -Force

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
        $s | Add-Member -Force -MemberType NoteProperty -Name SebTag -Value $Tag
        $s
    }
}

AfterAll {
    Remove-TypeData -TypeName System.Management.Automation.Runspaces.PSSession -ErrorAction SilentlyContinue
    InModuleScope RemoteManager {
        $script:SEBSessions = @{}
        $script:SEBSessionHosts = @{}
    }
}

Describe 'New-SEBSession remembers the pinned host (kills the NodeConfig-drop class)' {

    Context 'NodeConfig-less recreate after a DEAD cache entry' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Get-SEBCredential -ModuleName RemoteManager {
                [System.Management.Automation.PSCredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
            }
            # New-PSSession returns a fresh live double; -ComputerName is captured by the ParameterFilter.
            Mock New-PSSession -ModuleName RemoteManager { New-FakeSession -Availability 'Available' -Tag 'fresh' }
        }

        It 'reconnects to the stored hostname, NOT the bare alias' {
            # Seed: a DEAD cached session for alias 'gamingpc01' whose real target was the pinned IP,
            # and the remembered-host map pointing the alias at that IP. State=Opened (ETS) but
            # Availability=None makes it terminal, forcing New-SEBSession to remove + recreate.
            InModuleScope RemoteManager {
                $script:SEBSessions = @{}
                $script:SEBSessionHosts = @{}
            }
            $dead = New-FakeSession -Availability 'None' -Name 'SEBackup-gamingpc01' -Target '192.168.1.101' -Tag 'dead'
            InModuleScope RemoteManager -Parameters @{ Dead = $dead } {
                param($Dead)
                $script:SEBSessions['gamingpc01'] = $Dead
                $script:SEBSessionHosts['gamingpc01'] = '192.168.1.101'
            }

            # NodeConfig-less recreate -- exactly what the by-value refresh/reconnect sites do.
            $result = New-SEBSession -NodeName 'gamingpc01'

            $result.SebTag | Should -Be 'fresh'
            # The connection target must be the pinned IP from the host map, never the alias.
            Should -Invoke New-PSSession -ModuleName RemoteManager -Times 1 -Exactly -ParameterFilter {
                $ComputerName -eq '192.168.1.101'
            }
            Should -Invoke New-PSSession -ModuleName RemoteManager -Times 0 -Exactly -ParameterFilter {
                $ComputerName -eq 'gamingpc01'
            }
        }
    }

    Context 'NodeConfig-less create on a cache MISS but with a remembered host' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Get-SEBCredential -ModuleName RemoteManager {
                [System.Management.Automation.PSCredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
            }
            Mock New-PSSession -ModuleName RemoteManager { New-FakeSession -Availability 'Available' -Tag 'fresh2' }
        }

        It 'uses the remembered host when there is no cache entry at all' {
            InModuleScope RemoteManager {
                $script:SEBSessions = @{}
                $script:SEBSessionHosts = @{ 'gamingpc01' = '10.0.0.7' }
            }

            $null = New-SEBSession -NodeName 'gamingpc01'

            Should -Invoke New-PSSession -ModuleName RemoteManager -Times 1 -Exactly -ParameterFilter {
                $ComputerName -eq '10.0.0.7'
            }
        }
    }

    Context 'a successful create populates the host map' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Get-SEBCredential -ModuleName RemoteManager {
                [System.Management.Automation.PSCredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
            }
            Mock New-PSSession -ModuleName RemoteManager { New-FakeSession -Availability 'Available' -Tag 'fresh3' }
        }

        It 'records hostname from -NodeConfig so a later NodeConfig-less call reuses it' {
            InModuleScope RemoteManager {
                $script:SEBSessions = @{}
                $script:SEBSessionHosts = @{}
            }

            # First create WITH NodeConfig (alias 'gamingpc01' -> IP).
            $null = New-SEBSession -NodeName 'gamingpc01' -NodeConfig @{ hostname = '172.16.5.5' }

            $stored = InModuleScope RemoteManager { $script:SEBSessionHosts['gamingpc01'] }
            $stored | Should -Be '172.16.5.5'
        }
    }
}

Describe 'New-SEBSession reuses an ALIVE (incl. Busy) cached session' {

    Context 'cached session is Busy (another caller mid-command on the shared handle)' {
        BeforeAll {
            Mock Write-SEBLog {} -ModuleName RemoteManager
            Mock Get-SEBCredential -ModuleName RemoteManager { throw 'must not fetch credential when reusing' }
            Mock New-PSSession -ModuleName RemoteManager { throw 'must not rebuild an alive Busy session' }
        }

        It 'returns the Busy session instead of tearing it down and recreating' {
            InModuleScope RemoteManager {
                $script:SEBSessions = @{}
                $script:SEBSessionHosts = @{}
            }
            $busy = New-FakeSession -Availability 'Busy' -Name 'SEBackup-node01' -Target 'node01' -Tag 'busy-shared'
            InModuleScope RemoteManager -Parameters @{ Busy = $busy } {
                param($Busy)
                $script:SEBSessions['node01'] = $Busy
            }

            $result = New-SEBSession -NodeName 'node01'

            $result.SebTag | Should -Be 'busy-shared'
            Should -Invoke New-PSSession -ModuleName RemoteManager -Times 0 -Exactly
        }
    }
}
