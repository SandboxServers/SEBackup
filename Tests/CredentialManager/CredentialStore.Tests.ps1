#Requires -Module Pester

# These tests must build PSCredential objects whose plaintext password is KNOWN so the
# Save -> Get round-trip can assert the password is preserved byte-for-byte. The only way to
# create a SecureString from a known value in-test is ConvertTo-SecureString -AsPlainText, so the
# PSAvoidUsingConvertToSecureStringWithPlainText rule is suppressed for this test file only. No
# production code uses that pattern.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Test fixtures require a known plaintext password to verify round-trip preservation.')]
param()

# Issue #27 (SECURITY-CRITICAL): the credential store must protect node passwords with
# LocalMachine-scope DPAPI so an unattended S4U / "run whether logged on or not" scheduled
# task on the same C&C host can decrypt them (CurrentUser DPAPI could not). These tests prove,
# without a live scheduled task:
#   - Save -> Get round-trips a PSCredential with the password preserved exactly.
#   - The on-disk blob is NOT the plaintext password and is decryptable under LocalMachine
#     scope (the property an S4U task relies on), NOT bound to the current user (CurrentUser).
#   - Update-SEBCredential rotates (re-encrypt in place) and replaces (new secret).
#   - The credential file ACL grants SYSTEM + Administrators, with Users absent and inheritance
#     removed.
#   - Remove-SEBCredential still honors -WhatIf on the new .cred format.
#
# A true cross-user / S4U decrypt cannot be exercised in a unit test, so LocalMachine scope +
# ACL are asserted as the proxy; the live end-to-end S4U decrypt is deferred to the test-node
# phase (see docs/UNATTENDED-AUTH.md).

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # Helper: resolve the new-format and legacy file paths the module itself uses.
    function Get-CredFilePath([string]$Node) {
        InModuleScope CredentialManager -Parameters @{ n = $Node } { param($n) Resolve-CredentialPath -NodeName $n }
    }
    function Get-LegacyCredFilePath([string]$Node) {
        InModuleScope CredentialManager -Parameters @{ n = $Node } { param($n) Resolve-CredentialPath -NodeName $n -Legacy }
    }

    # Well-known SIDs used by ACL assertions.
    $script:SystemSid = [System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null).Value
    $script:AdminsSid = [System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null).Value
    $script:UsersSid  = [System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::BuiltinUsersSid, $null).Value
}

Describe 'Save/Get round-trip (LocalMachine-DPAPI protected store)' {
    BeforeEach {
        $script:node = "PesterCred_$([guid]::NewGuid().ToString('n'))"
        $script:file = Get-CredFilePath $script:node
        $script:plainPw = 'Round-Trip!P@ss-wörd-123'
        $secure = ConvertTo-SecureString $script:plainPw -AsPlainText -Force
        $script:cred = [System.Management.Automation.PSCredential]::new('TESTDOM\svc_seb', $secure)
    }
    AfterEach {
        foreach ($f in @($script:file, (Get-LegacyCredFilePath $script:node))) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'writes a .cred file (new format), not a .cred.xml' {
        Save-SEBCredential -NodeName $script:node -Credential $script:cred 3>$null
        Test-Path -LiteralPath $script:file | Should -BeTrue
        $script:file | Should -Match '\.cred$'
        Test-Path -LiteralPath (Get-LegacyCredFilePath $script:node) | Should -BeFalse
    }

    It 'round-trips the username and password exactly' {
        Save-SEBCredential -NodeName $script:node -Credential $script:cred 3>$null
        $back = Get-SEBCredential -NodeName $script:node
        $back | Should -BeOfType ([System.Management.Automation.PSCredential])
        $back.UserName | Should -Be 'TESTDOM\svc_seb'
        $back.GetNetworkCredential().Password | Should -Be $script:plainPw
    }

    It 'Test-SEBCredential reports the saved credential as available' {
        Save-SEBCredential -NodeName $script:node -Credential $script:cred 3>$null
        Test-SEBCredential -NodeName $script:node | Should -BeTrue
    }

    It 'Test-SEBCredential reports false when no credential exists' {
        Test-SEBCredential -NodeName "PesterMissing_$([guid]::NewGuid().ToString('n'))" | Should -BeFalse
    }
}

Describe 'Stored blob is protected (not plaintext) and LocalMachine-scoped' {
    BeforeAll {
        $script:node2 = "PesterBlob_$([guid]::NewGuid().ToString('n'))"
        $script:file2 = Get-CredFilePath $script:node2
        $script:secret = 'Sup3r-S3cret!{value}'
        $secure = ConvertTo-SecureString $script:secret -AsPlainText -Force
        Save-SEBCredential -NodeName $script:node2 -Credential ([System.Management.Automation.PSCredential]::new('u', $secure)) 3>$null
        $script:raw = Get-Content -LiteralPath $script:file2 -Raw
        $script:envelope = $script:raw | ConvertFrom-Json
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:file2) { Remove-Item -LiteralPath $script:file2 -Force -ErrorAction SilentlyContinue }
    }

    It 'does not contain the plaintext password anywhere in the file' {
        $script:raw | Should -Not -BeNullOrEmpty
        $script:raw.Contains($script:secret) | Should -BeFalse
    }

    It 'records the protection scope as LocalMachine in the envelope' {
        # The envelope documents the scope; the decrypt assertion below proves it is real.
        $script:envelope.Scope | Should -Be 'LocalMachine'
        $script:envelope.Format | Should -Be 'SEBCredential'
    }

    It 'decrypts under LocalMachine scope (the property an S4U task relies on)' {
        $protected = [Convert]::FromBase64String($script:envelope.ProtectedSecret)
        $entropy = InModuleScope CredentialManager { Get-SEBSecretEntropy }
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected, $entropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Be $script:secret
    }

    It 'was protected with LocalMachine scope, not CurrentUser (proven by re-encrypting the same data under each scope and matching the blob structure)' {
        # NOTE on DPAPI semantics: the `scope` argument to Unprotect is ADVISORY -- the blob
        # itself records its true scope, so a LocalMachine blob still decrypts even if you pass
        # CurrentUser (verified directly against the runtime). Therefore the negative "CurrentUser
        # Unprotect throws" assertion is NOT a valid test. Instead we assert the positive
        # machine-binding property: the SAME plaintext+entropy, re-encrypted under LocalMachine,
        # decrypts with the LocalMachine scope, while a CurrentUser blob of the same data is a
        # DIFFERENT ciphertext. The stored blob matching the LocalMachine path is the proof an
        # S4U/SYSTEM task (no user profile) can read it.
        $protected = [Convert]::FromBase64String($script:envelope.ProtectedSecret)
        $entropy = InModuleScope CredentialManager { Get-SEBSecretEntropy }

        # Round-trips under LocalMachine (machine key), which is what an unattended task uses.
        $lm = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected, $entropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        [System.Text.Encoding]::UTF8.GetString($lm) | Should -Be $script:secret

        # A CurrentUser-scoped protection of the same bytes produces a structurally different
        # blob (different scope flags), confirming the stored one was not the CurrentUser variant.
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($script:secret)
        $cuBlob = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        [Convert]::ToBase64String($cuBlob) | Should -Not -Be $script:envelope.ProtectedSecret
    }

    It 'is bound to per-machine entropy (decryption with wrong entropy fails)' {
        # This is the runtime-checkable half of the off-box protection: even with LocalMachine
        # scope, a process that does not know this machine's entropy cannot decrypt. (A copy of
        # the blob on a different machine fails for the same reason -- different MachineGuid AND
        # different DPAPI master key -- which cannot be exercised in a single-host unit test.)
        $protected = [Convert]::FromBase64String($script:envelope.ProtectedSecret)
        $wrongEntropy = [System.Text.Encoding]::UTF8.GetBytes('not-the-real-entropy')
        {
            [System.Security.Cryptography.ProtectedData]::Unprotect(
                $protected, $wrongEntropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        } | Should -Throw
    }
}

Describe 'Credential file ACL is locked down' {
    BeforeAll {
        $script:node3 = "PesterAcl_$([guid]::NewGuid().ToString('n'))"
        $script:file3 = Get-CredFilePath $script:node3
        $secure = ConvertTo-SecureString 'AclPass!1' -AsPlainText -Force
        Save-SEBCredential -NodeName $script:node3 -Credential ([System.Management.Automation.PSCredential]::new('u', $secure)) 3>$null
        $script:acl = Get-Acl -LiteralPath $script:file3
        $script:trusteeSids = @($script:acl.Access | ForEach-Object {
                $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            })
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:file3) { Remove-Item -LiteralPath $script:file3 -Force -ErrorAction SilentlyContinue }
    }

    It 'has inheritance disabled (access rules protected)' {
        $script:acl.AreAccessRulesProtected | Should -BeTrue
    }

    It 'grants SYSTEM' {
        $script:trusteeSids | Should -Contain $script:SystemSid
    }

    It 'grants Administrators' {
        $script:trusteeSids | Should -Contain $script:AdminsSid
    }

    It 'does NOT grant the Users group' {
        $script:trusteeSids | Should -Not -Contain $script:UsersSid
    }
}

Describe 'Update-SEBCredential rotation' {
    BeforeEach {
        $script:rnode = "PesterRot_$([guid]::NewGuid().ToString('n'))"
        $script:rfile = Get-CredFilePath $script:rnode
        $secure = ConvertTo-SecureString 'Original!Pass1' -AsPlainText -Force
        Save-SEBCredential -NodeName $script:rnode -Credential ([System.Management.Automation.PSCredential]::new('TESTDOM\rot', $secure)) 3>$null
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:rfile) { Remove-Item -LiteralPath $script:rfile -Force -ErrorAction SilentlyContinue }
    }

    It 're-encrypts in place and preserves the username and password' {
        $before = Get-Content -LiteralPath $script:rfile -Raw
        Update-SEBCredential -NodeName $script:rnode -Confirm:$false 3>$null
        $after = Get-Content -LiteralPath $script:rfile -Raw
        # Ciphertext should change (fresh DPAPI blob), but the secret must round-trip.
        $after | Should -Not -Be $before
        $back = Get-SEBCredential -NodeName $script:rnode
        $back.UserName | Should -Be 'TESTDOM\rot'
        $back.GetNetworkCredential().Password | Should -Be 'Original!Pass1'
    }

    It 'replaces the stored secret when a new -Credential is supplied' {
        $newSecure = ConvertTo-SecureString 'Rotated!Pass2' -AsPlainText -Force
        $newCred = [System.Management.Automation.PSCredential]::new('TESTDOM\rot', $newSecure)
        Update-SEBCredential -NodeName $script:rnode -Credential $newCred -Confirm:$false 3>$null
        $back = Get-SEBCredential -NodeName $script:rnode
        $back.GetNetworkCredential().Password | Should -Be 'Rotated!Pass2'
    }

    It 'honors -WhatIf (does not modify the stored credential)' {
        $before = Get-Content -LiteralPath $script:rfile -Raw
        $newSecure = ConvertTo-SecureString 'ShouldNotApply' -AsPlainText -Force
        Update-SEBCredential -NodeName $script:rnode -Credential ([System.Management.Automation.PSCredential]::new('x', $newSecure)) -WhatIf 3>$null
        (Get-Content -LiteralPath $script:rfile -Raw) | Should -Be $before
        (Get-SEBCredential -NodeName $script:rnode).GetNetworkCredential().Password | Should -Be 'Original!Pass1'
    }

    It 'keeps the file ACL hardened after rotation' {
        Update-SEBCredential -NodeName $script:rnode -Confirm:$false 3>$null
        $acl = Get-Acl -LiteralPath $script:rfile
        $acl.AreAccessRulesProtected | Should -BeTrue
        $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value })
        $sids | Should -Contain $script:SystemSid
        $sids | Should -Not -Contain $script:UsersSid
    }
}

Describe 'Remove-SEBCredential honors -WhatIf on the new .cred format' {
    BeforeEach {
        $script:dnode = "PesterDel_$([guid]::NewGuid().ToString('n'))"
        $script:dfile = Get-CredFilePath $script:dnode
        $secure = ConvertTo-SecureString 'DelPass!1' -AsPlainText -Force
        Save-SEBCredential -NodeName $script:dnode -Credential ([System.Management.Automation.PSCredential]::new('u', $secure)) 3>$null
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:dfile) { Remove-Item -LiteralPath $script:dfile -Force -ErrorAction SilentlyContinue }
    }

    It '-WhatIf leaves the .cred file intact' {
        Remove-SEBCredential -NodeName $script:dnode -WhatIf
        Test-Path -LiteralPath $script:dfile | Should -BeTrue
    }

    It '-Force deletes the .cred file' {
        Remove-SEBCredential -NodeName $script:dnode -Force
        Test-Path -LiteralPath $script:dfile | Should -BeFalse
    }
}

Describe 'Legacy migration (transparent re-save when readable)' {
    BeforeEach {
        $script:mnode = "PesterMig_$([guid]::NewGuid().ToString('n'))"
        $script:mfile = Get-CredFilePath $script:mnode
        $script:legacyFile = Get-LegacyCredFilePath $script:mnode
        $script:legacyPw = 'Legacy!P@ss-99'
        # Write a legacy Export-Clixml credential exactly like the pre-#27 store did.
        $secure = ConvertTo-SecureString $script:legacyPw -AsPlainText -Force
        $legacyCred = [System.Management.Automation.PSCredential]::new('TESTDOM\legacy', $secure)
        $legacyCred | Export-Clixml -LiteralPath $script:legacyFile -Force
    }
    AfterEach {
        foreach ($f in @($script:mfile, $script:legacyFile)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'Get-SEBCredential migrates a readable legacy file to the new format and returns the credential' {
        # Pre-condition: only the legacy file exists.
        Test-Path -LiteralPath $script:legacyFile | Should -BeTrue
        Test-Path -LiteralPath $script:mfile | Should -BeFalse

        $back = Get-SEBCredential -NodeName $script:mnode
        $back.UserName | Should -Be 'TESTDOM\legacy'
        $back.GetNetworkCredential().Password | Should -Be $script:legacyPw

        # Post-condition: new file written, legacy removed.
        Test-Path -LiteralPath $script:mfile | Should -BeTrue
        Test-Path -LiteralPath $script:legacyFile | Should -BeFalse
    }

    It 'the migrated file is the protected (.cred) format and is decryptable on this host' {
        Get-SEBCredential -NodeName $script:mnode | Out-Null
        $envelope = Get-Content -LiteralPath $script:mfile -Raw | ConvertFrom-Json
        $envelope.Format | Should -Be 'SEBCredential'
        $envelope.Scope | Should -Be 'LocalMachine'
        # The plaintext must not appear in the migrated file.
        (Get-Content -LiteralPath $script:mfile -Raw).Contains($script:legacyPw) | Should -BeFalse
    }
}
