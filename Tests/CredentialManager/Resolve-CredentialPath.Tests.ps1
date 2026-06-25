#Requires -Module Pester

# A node name is used as a credential filename component, so it must be validated to prevent
# path traversal (e.g. '../../etc/x') from reading or writing credentials outside Credentials/.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null
}

Describe 'Resolve-CredentialPath node-name validation' {
    It 'returns a credential file path inside Credentials/ for a valid node name' {
        InModuleScope CredentialManager {
            $p = Resolve-CredentialPath -NodeName 'GameServer01'
            $p | Should -Match 'GameServer01\.cred\.xml$'
            (Split-Path $p -Leaf) | Should -Be 'GameServer01.cred.xml'
        }
    }

    It 'accepts dotted hostnames' {
        InModuleScope CredentialManager {
            { Resolve-CredentialPath -NodeName 'node.example.com' } | Should -Not -Throw
        }
    }

    It 'rejects path traversal and separators' {
        InModuleScope CredentialManager {
            foreach ($bad in @('../evil', '..\evil', 'a/b', 'a\b', '..', '.', 'C:\x')) {
                { Resolve-CredentialPath -NodeName $bad } | Should -Throw -ExpectedMessage '*Invalid node name*'
            }
        }
    }
}
