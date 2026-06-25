#Requires -Module Pester

# Remove-SEBCredential deletes a DPAPI-encrypted credential file. Because deletion is
# destructive, the function must honor the standard risk-mitigation parameters: -WhatIf must
# preview without deleting, -Force must delete non-interactively, and removing a credential
# that does not exist must be a graceful no-op (warning, no throw). These tests use a real
# temp file placed at the path the module itself resolves (via Resolve-CredentialPath) so the
# delete path under test is exercised end to end without depending on real DPAPI credentials.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # A unique node name keeps these tests from colliding with any real credential file.
    # GUID 'n' format is hex-only, so it satisfies Resolve-CredentialPath's name validation.
    $script:testNode = "PesterRemoveCredTest_$([guid]::NewGuid().ToString('n'))"
    $script:credFile = InModuleScope CredentialManager -Parameters @{ Node = $script:testNode } {
        param($Node)
        Resolve-CredentialPath -NodeName $Node
    }
}

Describe 'Remove-SEBCredential' {
    AfterEach {
        if (Test-Path -LiteralPath $script:credFile) {
            Remove-Item -LiteralPath $script:credFile -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'when the credential file exists' {
        BeforeEach {
            # Stand in for a real DPAPI cred file; content is irrelevant to deletion.
            Set-Content -LiteralPath $script:credFile -Value '<dummy-credential/>' -Force
            Test-Path -LiteralPath $script:credFile | Should -BeTrue
        }

        It '-WhatIf leaves the credential file intact' {
            Remove-SEBCredential -NodeName $script:testNode -WhatIf
            Test-Path -LiteralPath $script:credFile | Should -BeTrue
        }

        It '-WhatIf does not throw' {
            { Remove-SEBCredential -NodeName $script:testNode -WhatIf } | Should -Not -Throw
        }

        It '-Force deletes the credential file without prompting' {
            Remove-SEBCredential -NodeName $script:testNode -Force
            Test-Path -LiteralPath $script:credFile | Should -BeFalse
        }

        It '-Confirm:$false deletes the credential file' {
            # -Confirm:$false suppresses the ShouldProcess prompt, so deletion proceeds
            # non-interactively without relying on -Force.
            Remove-SEBCredential -NodeName $script:testNode -Confirm:$false
            Test-Path -LiteralPath $script:credFile | Should -BeFalse
        }

        It '-What:$false takes precedence over an ambient $WhatIfPreference and deletes' {
            # Even if the session globally requested -WhatIf, an explicit -Force must delete.
            Remove-SEBCredential -NodeName $script:testNode -Force -WhatIf:$false
            Test-Path -LiteralPath $script:credFile | Should -BeFalse
        }
    }

    Context 'when the credential file does not exist' {
        BeforeEach {
            if (Test-Path -LiteralPath $script:credFile) {
                Remove-Item -LiteralPath $script:credFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'does not throw' {
            { Remove-SEBCredential -NodeName $script:testNode -Force 3>$null } | Should -Not -Throw
        }

        It 'writes a warning' {
            # Capture the warning stream (3) so the message can be asserted without surfacing it.
            $warning = Remove-SEBCredential -NodeName $script:testNode -Force 3>&1
            $warning | Should -Not -BeNullOrEmpty
            [string]$warning | Should -Match 'No credential file found'
        }

        It 'returns nothing' {
            $result = Remove-SEBCredential -NodeName $script:testNode -Force 3>$null
            $result | Should -BeNullOrEmpty
        }
    }
}
