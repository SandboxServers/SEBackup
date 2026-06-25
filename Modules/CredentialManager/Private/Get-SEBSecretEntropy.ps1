function Get-SEBSecretEntropy {
    <#
    .SYNOPSIS
        Derives stable, per-machine optional entropy for DPAPI secret protection.

    .DESCRIPTION
        Returns a deterministic 32-byte array used as the optionalEntropy argument
        to [System.Security.Cryptography.ProtectedData]::Protect / Unprotect. The
        entropy is derived by hashing a fixed application salt together with the
        machine's cryptographic MachineGuid
        (HKLM:\SOFTWARE\Microsoft\Cryptography\MachineGuid).

        Why this design:
        - LocalMachine-scope DPAPI lets ANY process on this host decrypt the data
          (that is the whole point -- it enables S4U / "run whether logged on or
          not" scheduled tasks to read the credential). To narrow that exposure,
          a per-machine entropy value is mixed in so the ciphertext can only be
          decrypted by code that knows this application's salt AND is running on
          this specific machine. An attacker who copies the .cred file to another
          machine cannot decrypt it even with LocalMachine scope, because both the
          DPAPI master key and the MachineGuid differ there.
        - The value MUST be stable across reboots and across logon types (the same
          bytes have to be reproducible under an interactive session and under an
          unattended S4U task). MachineGuid satisfies this: it is created at OS
          install time and does not change. It is also readable by SYSTEM and by
          any local process, which an S4U task needs.

        This is intentionally NOT a secret key store -- the security boundary is
        the machine DPAPI key plus the file ACL (see Set-SEBCredentialAcl). The
        entropy raises the bar for off-box decryption and binds the blob to this
        host; it is a hardening layer, not the primary protection.

        If the MachineGuid cannot be read (unusual), a fixed salt-only fallback is
        used and a warning is logged, so protection still works but loses the
        per-machine binding. The same fallback path is taken on both Protect and
        Unprotect, so round-tripping remains consistent within a single host.

        This is an internal helper and is not exported.

    .OUTPUTS
        System.Byte[]
        A 32-byte entropy array (SHA-256 digest).

    .EXAMPLE
        $entropy = Get-SEBSecretEntropy
        [System.Security.Cryptography.ProtectedData]::Protect($bytes, $entropy, 'LocalMachine')
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param()

    # Application-specific, version-tagged salt. Bumping the suffix (e.g. v2) is a
    # deliberate entropy rotation: blobs written under v1 will no longer decrypt and
    # must be re-saved via Update-SEBCredential.
    $salt = 'SEBackup.CredentialStore.Entropy.v1'

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
        return $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
    }
    finally {
        $sha256.Dispose()
    }
}
