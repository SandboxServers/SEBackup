function Unprotect-SEBSecret {
    <#
    .SYNOPSIS
        Decrypts a byte array produced by Protect-SEBSecret on this machine.

    .DESCRIPTION
        The decryption seam for the SEBackup credential store. Wraps
        [System.Security.Cryptography.ProtectedData]::Unprotect using
        DataProtectionScope.LocalMachine and the same per-machine entropy
        (Get-SEBSecretEntropy) that Protect-SEBSecret used.

        Because the protection is LocalMachine-scoped, this succeeds for any
        process on the SAME machine -- including an unattended S4U scheduled task
        -- which is exactly what unblocks unattended authentication. It will FAIL
        (CryptographicException) if the blob was created on a different machine,
        under a different application salt/entropy version, or has been tampered
        with; the caller treats that as "re-save required".

        This is the partner of Protect-SEBSecret and the other half of the
        backend seam a future secret backend would replace. Internal; not
        exported.

    .PARAMETER Bytes
        The protected (encrypted) byte array to decrypt. Must not be null.

    .PARAMETER EntropyVersion
        The entropy/salt version the blob was written under (from the envelope's
        EntropyVersion field). Defaults to the current $script:SEBEntropyVersion.
        Passing the recorded version lets a blob written before an entropy rotation
        still be decrypted (Get-SEBSecretEntropy derives the matching salt).

    .OUTPUTS
        System.Byte[]
        The decrypted plaintext byte array, or $null on failure (the error is
        logged via Write-SEBLog).

    .EXAMPLE
        $plain = Unprotect-SEBSecret -Bytes $protectedBytes
        [System.Text.Encoding]::UTF8.GetString($plain)
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNull()]
        [byte[]]$Bytes,

        [Parameter(Position = 1)]
        [int]$EntropyVersion = $script:SEBEntropyVersion
    )

    $entropy = $null
    try {
        $entropy = Get-SEBSecretEntropy -Version $EntropyVersion
        $scope = [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        return [System.Security.Cryptography.ProtectedData]::Unprotect($Bytes, $entropy, $scope)
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message (
            "Failed to unprotect secret with LocalMachine DPAPI (wrong machine, " +
            "rotated entropy, or corrupted data): $_")
        return $null
    }
    finally {
        if ($entropy) { [Array]::Clear($entropy, 0, $entropy.Length) }
    }
}
