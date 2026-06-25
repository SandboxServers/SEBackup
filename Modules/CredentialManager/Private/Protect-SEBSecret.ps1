function Protect-SEBSecret {
    <#
    .SYNOPSIS
        Encrypts a byte array so any process on THIS machine can later decrypt it.

    .DESCRIPTION
        The encryption seam for the SEBackup credential store. Wraps the Windows
        Data Protection API (DPAPI) via
        [System.Security.Cryptography.ProtectedData]::Protect using
        DataProtectionScope.LocalMachine plus a per-machine entropy value from
        Get-SEBSecretEntropy.

        LocalMachine scope is deliberate. CurrentUser-scope DPAPI (what the old
        Export-Clixml store used) binds the ciphertext to the saving user's
        profile, so an unattended scheduled task running under S4U ("run whether
        logged on or not") -- which has no loaded user profile and, per Microsoft,
        "no access to encrypted files" -- cannot decrypt it. LocalMachine scope
        binds to the machine instead, so the same task on the same C&C host CAN
        decrypt. The trade-off (any local process can decrypt) is mitigated by the
        per-machine entropy and by the restrictive file ACL applied by
        Set-SEBCredentialAcl.

        This function is the single point a future backend swap (e.g. gMSA, a
        certificate, or Microsoft.PowerShell.SecretManagement) would replace --
        keep it small and free of credential-shaped logic. Its contract is simply
        bytes in, protected bytes out.

        Internal helper; not exported.

    .PARAMETER Bytes
        The plaintext byte array to protect. Must not be null.

    .OUTPUTS
        System.Byte[]
        The protected (encrypted) byte array, or $null on failure (the error is
        logged via Write-SEBLog).

    .EXAMPLE
        $protected = Protect-SEBSecret -Bytes ([System.Text.Encoding]::UTF8.GetBytes($plain))
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNull()]
        [byte[]]$Bytes
    )

    try {
        $entropy = Get-SEBSecretEntropy
        $scope = [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        return [System.Security.Cryptography.ProtectedData]::Protect($Bytes, $entropy, $scope)
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Failed to protect secret with LocalMachine DPAPI: $_"
        return $null
    }
}
