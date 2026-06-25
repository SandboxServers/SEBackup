# The single source of truth for the credential-store entropy/envelope version.
# Bumping this is a DELIBERATE entropy rotation: blobs written under the old
# version no longer decrypt with the new one and must be re-saved (see
# Update-SEBCredential). It is the SAME number written to the envelope's
# EntropyVersion field by ConvertTo-SEBProtectedCredential, so the on-disk
# version and the entropy that produced it stay in lockstep, and Unprotect can
# reproduce the entropy that a given blob was written under.
$script:SEBEntropyVersion = 1

function Get-SEBSecretEntropy {
    <#
    .SYNOPSIS
        Derives stable, per-machine optional entropy for DPAPI secret protection.

    .DESCRIPTION
        Returns a deterministic 32-byte array used as the optionalEntropy argument
        to [System.Security.Cryptography.ProtectedData]::Protect / Unprotect. The
        entropy is derived by hashing a fixed, version-tagged application salt
        together with the machine's cryptographic MachineGuid
        (HKLM:\SOFTWARE\Microsoft\Cryptography\MachineGuid).

        Why this design:
        - LocalMachine-scope DPAPI lets ANY process on this host decrypt the data
          (that is the whole point -- it enables S4U / "run whether logged on or
          not" scheduled tasks to read the credential). The per-machine entropy
          binds the ciphertext to THIS host: a .cred copied to another machine
          fails there because both the DPAPI master key and the MachineGuid differ.
        - The value MUST be stable across reboots and across logon types (the same
          bytes have to be reproducible under an interactive session and under an
          unattended S4U task). MachineGuid satisfies this: it is created at OS
          install time and does not change. It is also readable by SYSTEM and by
          any local process, which an S4U task needs.

        SECURITY BOUNDARY -- be honest about what this protects:
        On THIS host the entropy provides essentially NO confidentiality against a
        local attacker who can already read the .cred file: the salt is a literal
        shipped in this source file and the MachineGuid is world-readable to any
        local process with no elevation, so any local code can reproduce the
        entropy and call Unprotect. Its real value is OFF-BOX binding (a copied
        blob fails elsewhere). The file ACL applied by Set-SEBCredentialAcl is the
        ONLY local confidentiality control; the entropy is a hardening / off-box
        binding layer, not the primary protection.

        Memoization: both inputs are immutable for the process lifetime (the salt
        is a literal; MachineGuid does not change at runtime), so the derived
        digest is computed once per (version) and cached in module scope. A clone
        of the cached array is returned so a caller cannot mutate the cache. The
        one-time MachineGuid-fallback warning still fires on the first derivation.

        If the MachineGuid cannot be read (unusual), a fixed salt-only fallback is
        used and a warning is logged, so protection still works but loses the
        per-machine binding. The same fallback path is taken on both Protect and
        Unprotect, so round-tripping remains consistent within a single host.

        This is an internal helper and is not exported.

    .PARAMETER Version
        The entropy/salt version to derive. Defaults to the current
        $script:SEBEntropyVersion. Unprotect-SEBSecret passes the version recorded
        in a blob's envelope so an older blob can still be decrypted after a
        rotation (the salt suffix is derived from this number).

    .OUTPUTS
        System.Byte[]
        A 32-byte entropy array (SHA-256 digest).

    .EXAMPLE
        $entropy = Get-SEBSecretEntropy
        [System.Security.Cryptography.ProtectedData]::Protect($bytes, $entropy, 'LocalMachine')
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Position = 0)]
        [int]$Version = $script:SEBEntropyVersion
    )

    # Per-version memoization. Inputs are immutable for the process lifetime, so a
    # derived digest is cached and reused; return a clone so callers cannot mutate
    # the cached array.
    if ($null -eq $script:SEBSecretEntropyCache) {
        $script:SEBSecretEntropyCache = @{}
    }
    if ($script:SEBSecretEntropyCache.ContainsKey($Version)) {
        return $script:SEBSecretEntropyCache[$Version].Clone()
    }

    # Application-specific, version-tagged salt. The suffix is derived from the
    # version number so it stays in lockstep with the envelope's EntropyVersion.
    $salt = "SEBackup.CredentialStore.Entropy.v$Version"

    $machineGuid = $null
    try {
        $machineGuid = (Get-ItemProperty `
                -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' `
                -Name 'MachineGuid' -ErrorAction Stop).MachineGuid
    }
    catch {
        # Fall back to salt-only entropy. This still encrypts, but the blob is no
        # longer bound to this specific machine's GUID. Surface it so an operator
        # can investigate why the standard machine identity is unavailable.
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message (
            "Could not read MachineGuid for credential entropy; falling back to " +
            "salt-only entropy (credential blobs lose per-machine binding): $_")
    }

    $material = if ([string]::IsNullOrWhiteSpace($machineGuid)) { $salt } else { "$salt|$machineGuid" }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
        $script:SEBSecretEntropyCache[$Version] = $digest
        return $digest.Clone()
    }
    finally {
        $sha256.Dispose()
    }
}
