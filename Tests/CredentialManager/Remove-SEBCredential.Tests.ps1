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

        It '-Force together with -WhatIf does NOT delete (WhatIf always wins)' {
            # Regression guard for the core fix: -Force must never bypass -WhatIf. Previously
            # the guard short-circuited on $Force and skipped ShouldProcess, so -Force -WhatIf
            # deleted the file. Now ShouldProcess is always consulted; an explicit -WhatIf
            # binds on the call (so it DOES reach the module), returns $false, and the file
            # must survive even though -Force was supplied.
            Remove-SEBCredential -NodeName $script:testNode -Force -WhatIf
            Test-Path -LiteralPath $script:credFile | Should -BeTrue
        }

        It '-WhatIf alone (no -Force) does not delete' {
            # Sanity check that the plain -WhatIf path -- which a user is most likely to run
            # first against a destructive command -- previews without deleting.
            Remove-SEBCredential -NodeName $script:testNode -WhatIf
            Test-Path -LiteralPath $script:credFile | Should -BeTrue
        }

        It '-Force -WhatIf:$false deletes (explicit -WhatIf:$false plus -Force)' {
            # The mirror of the regression guard: with WhatIf explicitly disabled, -Force
            # suppresses the ConfirmImpact=High prompt and deletion proceeds non-interactively.
            Remove-SEBCredential -NodeName $script:testNode -Force -WhatIf:$false
            Test-Path -LiteralPath $script:credFile | Should -BeFalse
        }

        It '-Force -Confirm:$false deletes (explicit -Confirm not overridden by -Force)' {
            # -Force lowers $ConfirmPreference only when -Confirm was not explicitly bound;
            # passing -Confirm:$false alongside -Force still suppresses the prompt and deletes.
            Remove-SEBCredential -NodeName $script:testNode -Force -Confirm:$false
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
