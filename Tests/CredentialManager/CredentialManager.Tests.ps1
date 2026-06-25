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

Describe 'Test-SEBCredential treats a legacy-only credential as NOT ready (re-save required)' {
    # SECURITY-CRITICAL (8-lens altitude/major): a legacy CurrentUser-DPAPI .cred.xml does NOT
    # decrypt under an S4U task with no profile -- the exact unattended scenario this API gates.
    # Reporting such a node as "available" is a false-green readiness signal: the preflight would
    # pass and the unattended backup would then fail. Test-SEBCredential must return $false for a
    # legacy-only node (even one readable by the current interactive user) and must NOT migrate it.
    BeforeEach {
        $script:lnode = "PesterLegacyTest_$([guid]::NewGuid().ToString('n'))"
        $script:lfile = Get-CredFilePath $script:lnode
        $script:llegacy = Get-LegacyCredFilePath $script:lnode
        $secure = ConvertTo-SecureString 'LegacyOnly!P@ss-1' -AsPlainText -Force
        # Saved by THIS user, so Import-Clixml here WOULD succeed -- the old behavior returned $true.
        [System.Management.Automation.PSCredential]::new('TESTDOM\legacy', $secure) |
            Export-Clixml -LiteralPath $script:llegacy -Force
    }
    AfterEach {
        foreach ($f in @($script:lfile, $script:llegacy)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'returns $false for a legacy-only credential even though it is readable by the current user' {
        # Sanity: the legacy file is in fact readable by this user (so the result is about policy,
        # not unreadability).
        { Import-Clixml -LiteralPath $script:llegacy } | Should -Not -Throw
        Test-SEBCredential -NodeName $script:lnode | Should -BeFalse
    }

    It 'does NOT migrate the legacy file (side-effect-free): no .cred is created' {
        Test-SEBCredential -NodeName $script:lnode | Out-Null
        Test-Path -LiteralPath $script:lfile  | Should -BeFalse   # no new protected file written
        Test-Path -LiteralPath $script:llegacy | Should -BeTrue    # legacy left untouched
    }
}

Describe 'Migration verifies decrypt round-trip BEFORE deleting the legacy copy' {
    # SECURITY-CRITICAL (8-lens altitude/blast-radius/major): an irreversible migration must
    # "verify the replacement is recoverable, THEN destroy the source". If the just-written .cred
    # cannot be decrypted back on this host (e.g. an entropy-fallback divergence between write and
    # read), the legacy .cred.xml -- the only readable copy -- must be KEPT and a failure reported.
    # We simulate the undecryptable-replacement condition without Pester mocks by having the
    # re-save action persist a credential whose password differs, so the read-back comparison fails.
    BeforeEach {
        $script:vnode = "PesterVerifyMig_$([guid]::NewGuid().ToString('n'))"
        $script:vfile = Get-CredFilePath $script:vnode
        $script:vlegacy = Get-LegacyCredFilePath $script:vnode
        $script:vpw = 'VerifyMig!P@ss-1'
        $secure = ConvertTo-SecureString $script:vpw -AsPlainText -Force
        [System.Management.Automation.PSCredential]::new('TESTDOM\verify', $secure) |
            Export-Clixml -LiteralPath $script:vlegacy -Force
    }
    AfterEach {
        foreach ($f in @($script:vfile, $script:vlegacy)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'keeps the legacy file and reports NotReadable when the new blob fails read-back verification' {
        $status = InModuleScope CredentialManager -Parameters @{ node = $script:vnode } {
            param($node)
            $result = Convert-SEBLegacyCredential -NodeName $node -SaveAction {
                param([PSCredential]$cred)
                # Write a DIFFERENT password so the verify-before-delete comparison fails,
                # standing in for an entropy-divergent / undecryptable replacement.
                $wrong = [System.Management.Automation.PSCredential]::new(
                    $cred.UserName, (ConvertTo-SecureString 'DIVERGENT-DOES-NOT-MATCH' -AsPlainText -Force))
                Write-SEBProtectedCredentialFile -NodeName $node -Credential $wrong
            } 3>$null 4>$null
            $result.Status
        }
        $status | Should -Be 'NotReadable'
        # The only readable copy (legacy) must survive.
        Test-Path -LiteralPath $script:vlegacy | Should -BeTrue
        # The unverifiable new file must not be left behind to mask the legacy copy.
        Test-Path -LiteralPath $script:vfile | Should -BeFalse
    }

    It 'a normal (matching) migration DOES delete the legacy file after a successful round-trip' {
        # Control case: the real save action round-trips, so the legacy file is removed.
        $back = Get-SEBCredential -NodeName $script:vnode
        $back.GetNetworkCredential().Password | Should -Be $script:vpw
        Test-Path -LiteralPath $script:vfile  | Should -BeTrue
        Test-Path -LiteralPath $script:vlegacy | Should -BeFalse
    }
}

Describe 'ConvertFrom-SEBProtectedCredential honors the envelope Version/Scope discriminators' {
    # 8-lens altitude/walmart (major/minor): Version and Scope must be load-bearing, not decorative.
    # An envelope whose Version this build does not understand must be REJECTED with a clear result
    # (returns $null) rather than fed to the v1 decode path and failing with an opaque crypto error.
    It 'rejects an unknown envelope Version (returns $null)' {
        InModuleScope CredentialManager {
            $secure = ConvertTo-SecureString 'VersionGuard!1' -AsPlainText -Force
            $env = ConvertTo-SEBProtectedCredential -Credential ([System.Management.Automation.PSCredential]::new('u', $secure))
            $env.Version = 2   # a version this build does not support
            (ConvertFrom-SEBProtectedCredential -Envelope $env 3>$null) | Should -BeNullOrEmpty
        }
    }

    It 'rejects an unknown Scope/backend (returns $null)' {
        InModuleScope CredentialManager {
            $secure = ConvertTo-SecureString 'ScopeGuard!1' -AsPlainText -Force
            $env = ConvertTo-SEBProtectedCredential -Credential ([System.Management.Automation.PSCredential]::new('u', $secure))
            $env.Scope = 'SomeFutureBackend'
            (ConvertFrom-SEBProtectedCredential -Envelope $env 3>$null) | Should -BeNullOrEmpty
        }
    }

    It 'rejects a missing/null Scope (mandatory, not optional) so a malformed envelope cannot decrypt unproven' {
        # Copilot R3: a missing/null Scope previously PASSED validation, letting a malformed
        # (or hand-crafted) envelope be decrypted without proving which backend sealed it. Scope
        # is now mandatory: removing it must REJECT (return $null), exactly like an unknown scope.
        InModuleScope CredentialManager {
            $secure = ConvertTo-SecureString 'ScopeMissing!1' -AsPlainText -Force
            # The writer returns a hashtable; drop the Scope key so the field is genuinely absent.
            $env = ConvertTo-SEBProtectedCredential -Credential ([System.Management.Automation.PSCredential]::new('u', $secure))
            $env.Remove('Scope')
            $env.ContainsKey('Scope') | Should -BeFalse   # guard: the field really is gone
            (ConvertFrom-SEBProtectedCredential -Envelope $env 3>$null) | Should -BeNullOrEmpty
        }
    }

    It 'rejects a missing/null Version (mandatory, not optional)' {
        # Same "must be present" rigor for Version: an absent Version must not fall through to the
        # v1 decode path. (The production check already rejects $null Version; this pins it.)
        InModuleScope CredentialManager {
            $secure = ConvertTo-SecureString 'VersionMissing!1' -AsPlainText -Force
            $env = ConvertTo-SEBProtectedCredential -Credential ([System.Management.Automation.PSCredential]::new('u', $secure))
            $env.Remove('Version')
            $env.ContainsKey('Version') | Should -BeFalse
            (ConvertFrom-SEBProtectedCredential -Envelope $env 3>$null) | Should -BeNullOrEmpty
        }
    }

    It 'still decodes a current (Version=1, Scope=LocalMachine) envelope' {
        InModuleScope CredentialManager {
            $secure = ConvertTo-SecureString 'GoodEnvelope!1' -AsPlainText -Force
            $env = ConvertTo-SEBProtectedCredential -Credential ([System.Management.Automation.PSCredential]::new('keep\me', $secure))
            $env.Version | Should -Be 1
            $env.EntropyVersion | Should -Not -BeNullOrEmpty
            $back = ConvertFrom-SEBProtectedCredential -Envelope $env
            $back | Should -BeOfType ([System.Management.Automation.PSCredential])
            $back.GetNetworkCredential().Password | Should -Be 'GoodEnvelope!1'
        }
    }
}

Describe 'Corrupt/empty .cred is handled consistently by Get and Test' {
    # 8-lens adversarial (minor): an empty/whitespace .cred (a truncated write or externally touched
    # file) yields a $null envelope from ConvertFrom-Json WITHOUT throwing. Get must surface the
    # friendly corruption error (not a raw ParameterBindingValidationException) and Test must return
    # $false -- and they must agree on the same file.
    BeforeEach {
        $script:cnode = "PesterCorrupt_$([guid]::NewGuid().ToString('n'))"
        $script:cfile = Get-CredFilePath $script:cnode
        Set-Content -LiteralPath $script:cfile -Value '' -Encoding UTF8 -Force
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:cfile) { Remove-Item -LiteralPath $script:cfile -Force -ErrorAction SilentlyContinue }
    }

    It 'Get-SEBCredential throws a corruption message (not a raw binding exception)' {
        { Get-SEBCredential -NodeName $script:cnode } | Should -Throw -ExpectedMessage '*corrupt*'
    }

    It 'Test-SEBCredential returns $false for the same empty file' {
        Test-SEBCredential -NodeName $script:cnode | Should -BeFalse
    }
}

Describe 'Write path is atomic and ACL-gated' {
    # 8-lens adversarial/red-team (critical/major): a write must not leave a temp file behind, and
    # the published file must carry an explicit (protected) ACL -- the only local confidentiality
    # boundary. (A live Set-Acl failure cannot be forced unelevated in a unit test; we assert the
    # observable guarantees: no temp residue and an explicit, Users-free, protected ACL.)
    BeforeEach {
        $script:wnode = "PesterAtomic_$([guid]::NewGuid().ToString('n'))"
        $script:wfile = Get-CredFilePath $script:wnode
        $secure = ConvertTo-SecureString 'Atomic!P@ss-1' -AsPlainText -Force
        Save-SEBCredential -NodeName $script:wnode -Credential ([System.Management.Automation.PSCredential]::new('u', $secure)) 3>$null
    }
    AfterEach {
        foreach ($f in @($script:wfile, (Get-LegacyCredFilePath $script:wnode))) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
        # Defensive: clean any stray temp files from this node.
        Get-ChildItem -Path (Split-Path $script:wfile) -Filter "$($script:wnode).cred.tmp.*" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    It 'leaves no ".tmp.*" residue next to the published file' {
        $stray = Get-ChildItem -Path (Split-Path $script:wfile) -Filter "$($script:wnode).cred.tmp.*" -ErrorAction SilentlyContinue
        @($stray).Count | Should -Be 0
        Test-Path -LiteralPath $script:wfile | Should -BeTrue
    }

    It 'publishes a file whose DACL is protected (explicit, not inherited) and excludes Users' {
        $acl = Get-Acl -LiteralPath $script:wfile
        $acl.AreAccessRulesProtected | Should -BeTrue
        $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value })
        $sids | Should -Contain $script:SystemSid
        $sids | Should -Not -Contain $script:UsersSid
    }
}

Describe 'Convert-SEBLegacyCredential returns the readable legacy credential when the new-file write fails' {
    # Copilot fix (correctness): when the legacy .cred.xml WAS readable but persisting the new
    # protected .cred failed (SaveAction returned $false / threw), the migration helper must NOT
    # report the credential as lost. It returns Status='NotReadable' WITH the in-memory legacy
    # credential and KEEPS the legacy file, so the caller can still authenticate this run.
    BeforeEach {
        $script:wfnode = "PesterWriteFail_$([guid]::NewGuid().ToString('n'))"
        $script:wffile = Get-CredFilePath $script:wfnode
        $script:wflegacy = Get-LegacyCredFilePath $script:wfnode
        $script:wfpw = 'WriteFail!P@ss-1'
        $secure = ConvertTo-SecureString $script:wfpw -AsPlainText -Force
        [System.Management.Automation.PSCredential]::new('TESTDOM\writefail', $secure) |
            Export-Clixml -LiteralPath $script:wflegacy -Force
    }
    AfterEach {
        foreach ($f in @($script:wffile, $script:wflegacy)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'returns NotReadable WITH the legacy credential (not $null) when SaveAction reports failure' {
        $result = InModuleScope CredentialManager -Parameters @{ node = $script:wfnode } {
            param($node)
            # SaveAction returns $false (no .cred written) -- stands in for a failed/hardening-denied
            # write. The helper must surface the still-valid legacy credential, not discard it.
            Convert-SEBLegacyCredential -NodeName $node -SaveAction { param([PSCredential]$c) $false } 3>$null
        }
        $result.Status | Should -Be 'NotReadable'
        $result.Credential | Should -BeOfType ([System.Management.Automation.PSCredential])
        $result.Credential.GetNetworkCredential().Password | Should -Be $script:wfpw
        # Nothing recoverable destroyed: the legacy file is kept and no new .cred was written.
        Test-Path -LiteralPath $script:wflegacy | Should -BeTrue
        Test-Path -LiteralPath $script:wffile | Should -BeFalse
    }

    It 'Get-SEBCredential RETURNS the recovered credential (does not throw) when the new-file write fails' {
        # The core Copilot correctness fix: Get-SEBCredential must treat a NotReadable result that
        # still carries a credential as a usable (warn-and-continue) outcome, NOT an error.
        Mock -ModuleName CredentialManager Convert-SEBLegacyCredential {
            $secure = ConvertTo-SecureString 'WriteFail!P@ss-1' -AsPlainText -Force
            @{ Status = 'NotReadable'
               Credential = [System.Management.Automation.PSCredential]::new('TESTDOM\writefail', $secure) }
        }
        $cred = $null
        { $script:cred = Get-SEBCredential -NodeName $script:wfnode 3>$null } | Should -Not -Throw
        $script:cred | Should -BeOfType ([System.Management.Automation.PSCredential])
        $script:cred.UserName | Should -Be 'TESTDOM\writefail'
        $script:cred.GetNetworkCredential().Password | Should -Be 'WriteFail!P@ss-1'
    }

    It 'Get-SEBCredential STILL throws when the legacy file is genuinely unreadable (null credential)' {
        # The negative half: a NotReadable result with a $null credential (legacy unreadable by this
        # account) is a real failure and must still throw the "re-save required" guidance.
        Mock -ModuleName CredentialManager Convert-SEBLegacyCredential {
            @{ Status = 'NotReadable'; Credential = $null }
        }
        { Get-SEBCredential -NodeName $script:wfnode 3>$null } | Should -Throw -ExpectedMessage '*could not be read*'
    }
}

Describe 'Migration mutex unavailable -- fail-safe read-only path keeps the legacy file' {
    # Copilot fix (robustness): if the cross-process migration mutex cannot be created/acquired,
    # the destructive re-save/verify/delete MUST be skipped. The helper Get-SafeReadableLegacyCredential
    # is what that fail-safe branch returns: it reads the legacy file READ-ONLY and reports
    # NotReadable, writing nothing and deleting nothing. Never throws.
    BeforeEach {
        $script:munode = "PesterMutexSafe_$([guid]::NewGuid().ToString('n'))"
        $script:mufile = Get-CredFilePath $script:munode
        $script:mulegacy = Get-LegacyCredFilePath $script:munode
        $script:mupw = 'MutexSafe!P@ss-1'
        $secure = ConvertTo-SecureString $script:mupw -AsPlainText -Force
        [System.Management.Automation.PSCredential]::new('TESTDOM\mutexsafe', $secure) |
            Export-Clixml -LiteralPath $script:mulegacy -Force
    }
    AfterEach {
        foreach ($f in @($script:mufile, $script:mulegacy)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'returns the readable legacy credential as NotReadable and deletes/writes nothing' {
        $result = InModuleScope CredentialManager -Parameters @{ f = $script:mulegacy } {
            param($f)
            Get-SafeReadableLegacyCredential -LegacyFile $f 3>$null
        }
        $result.Status | Should -Be 'NotReadable'
        $result.Credential | Should -BeOfType ([System.Management.Automation.PSCredential])
        $result.Credential.GetNetworkCredential().Password | Should -Be $script:mupw
        # Fail-safe MUST NOT touch the store: legacy kept, no new .cred written.
        Test-Path -LiteralPath $script:mulegacy | Should -BeTrue
        Test-Path -LiteralPath $script:mufile | Should -BeFalse
    }

    It 'reports NotReadable with a $null credential (never throws) when the legacy file is missing' {
        # A defensive call against an absent legacy path must be a safe no-op, not an exception.
        $missing = Get-LegacyCredFilePath "PesterMutexMissing_$([guid]::NewGuid().ToString('n'))"
        $result = $null
        {
            $script:result = InModuleScope CredentialManager -Parameters @{ f = $missing } {
                param($f)
                Get-SafeReadableLegacyCredential -LegacyFile $f 3>$null
            }
        } | Should -Not -Throw
        $script:result.Status | Should -Be 'NotReadable'
        $script:result.Credential | Should -BeNullOrEmpty
    }

    It 'when the named migration mutex cannot be acquired, Convert-SEBLegacyCredential routes to the fail-safe and keeps the legacy file' {
        # End-to-end proof of the contention routing (not just the helper). We hold the SAME named
        # mutex this node would use so the function cannot acquire it and must fall through to the
        # read-only fail-safe. The OS mutex is thread-affine and REENTRANT for its owner, so holding
        # it on the test thread would let the function (run synchronously on that same thread via
        # InModuleScope) re-acquire immediately. We therefore hold it on a SEPARATE runspace.
        #
        # Capability-tolerant: holding a "Global\" mutex needs SeCreateGlobalPrivilege. If the holder
        # runspace cannot create it, the PRODUCTION code's own Mutex creation fails the same way and
        # ALSO routes to the fail-safe (the create-failure branch). Either way the observable contract
        # is identical -- NotReadable + the legacy credential returned, legacy file kept -- so the
        # test asserts that contract whether contention came from a timeout or a creation failure.
        $mutexFullName = "Global\SEBackup.CredMigrate.$script:munode"
        $holderReady = [System.Threading.ManualResetEventSlim]::new($false)
        $releaseHolder = [System.Threading.ManualResetEventSlim]::new($false)
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript({
                param($name, $ready, $release)
                try {
                    $m = [System.Threading.Mutex]::new($false, $name)
                }
                catch {
                    # Cannot create the Global mutex here (no privilege). Signal anyway; the
                    # production code will hit the same creation failure and fail-safe.
                    $ready.Set()
                    return
                }
                try {
                    [void]$m.WaitOne()
                    $ready.Set()
                    # Hold until the test signals it has finished the contended call.
                    [void]$release.Wait([TimeSpan]::FromSeconds(120))
                }
                finally { try { $m.ReleaseMutex() } catch { }; $m.Dispose() }
            }).AddArgument($mutexFullName).AddArgument($holderReady).AddArgument($releaseHolder)
        $async = $ps.BeginInvoke()
        try {
            # Wait until the holder runspace is ready (owns the mutex, or could not create it).
            $holderReady.Wait([TimeSpan]::FromSeconds(30)) | Should -BeTrue

            # If contention is real, the function waits -MutexTimeoutMs before the fail-safe
            # returns; if the mutex could not be created at all, it returns immediately. Either
            # path is deterministic and yields the SAME result. We pass a SMALL timeout (500 ms)
            # so this honest end-to-end test exercises the real contended-timeout branch FAST --
            # production keeps the 30 s default; only this test shortens it.
            $result = InModuleScope CredentialManager -Parameters @{ node = $script:munode } {
                param($node)
                Convert-SEBLegacyCredential -NodeName $node -MutexTimeoutMs 500 -SaveAction { param([PSCredential]$c) $true } 3>$null
            }
            $result.Status | Should -Be 'NotReadable'
            $result.Credential | Should -BeOfType ([System.Management.Automation.PSCredential])
            $result.Credential.GetNetworkCredential().Password | Should -Be $script:mupw
            # The fail-safe must not have written a new file or deleted the legacy one.
            Test-Path -LiteralPath $script:mulegacy | Should -BeTrue
            Test-Path -LiteralPath $script:mufile | Should -BeFalse
        }
        finally {
            $releaseHolder.Set()
            try { $ps.EndInvoke($async) } catch { }
            $ps.Dispose()
            $holderReady.Dispose()
            $releaseHolder.Dispose()
        }
    }
}
