#Requires -Module Pester

# A node name is used as a credential filename component, so it must be validated to prevent
# path traversal (e.g. '../../etc/x') from reading or writing credentials outside Credentials/.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null
}

Describe 'Resolve-CredentialPath node-name validation' {
    It 'returns a new-format (.cred) credential file path inside Credentials/ for a valid node name' {
        InModuleScope CredentialManager {
            # Issue #27 changed the default store extension from .cred.xml (Clixml) to
            # .cred (LocalMachine-DPAPI protected JSON envelope).
            $p = Resolve-CredentialPath -NodeName 'GameServer01'
            $p | Should -Match 'GameServer01\.cred$'
            (Split-Path $p -Leaf) | Should -Be 'GameServer01.cred'
        }
    }

    It 'returns the legacy (.cred.xml) path when -Legacy is supplied' {
        InModuleScope CredentialManager {
            $p = Resolve-CredentialPath -NodeName 'GameServer01' -Legacy
            $p | Should -Match 'GameServer01\.cred\.xml$'
            (Split-Path $p -Leaf) | Should -Be 'GameServer01.cred.xml'
        }
    }

    It 'accepts dotted hostnames' {
        InModuleScope CredentialManager {
            { Resolve-CredentialPath -NodeName 'node.example.com' } | Should -Not -Throw
        }
    }

    It 'rejects path traversal and separators: <_>' -ForEach @('../evil', '..\evil', 'a/b', 'a\b', '..', '.', 'C:\x') {
        # One It per bad input (Pester 5 -ForEach): a foreach inside a single It short-circuits
        # on the first failure and hides which input regressed.
        $bad = $_
        InModuleScope CredentialManager -Parameters @{ bad = $bad } {
            param($bad)
            { Resolve-CredentialPath -NodeName $bad } | Should -Throw -ExpectedMessage '*Invalid node name*'
        }
    }
}
