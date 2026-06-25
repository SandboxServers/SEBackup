function ConvertFrom-SEBProtectedCredential {
    <#
    .SYNOPSIS
        Rebuilds a PSCredential from the on-disk protected-credential envelope.

    .DESCRIPTION
        The inverse of ConvertTo-SEBProtectedCredential. Validates the envelope,
        Base64-decodes the protected password, decrypts it via Unprotect-SEBSecret
        (LocalMachine DPAPI + per-machine entropy), and reconstructs a PSCredential
        whose password is a SecureString. The decrypted plaintext is appended to
        the SecureString character by character and the transient byte buffer is
        zeroed in a finally block.

        Returns $null (rather than throwing) when the envelope is malformed or the
        decryption fails -- for example when the blob was created on a different
        machine or under a rotated entropy version. The caller decides how to
        surface that (e.g. "re-save required").

        Internal helper; not exported.

    .PARAMETER Envelope
        The envelope object produced by deserializing a "*.cred" file (typically
        via ConvertFrom-Json). Accepts a PSCustomObject or hashtable.

    .OUTPUTS
        System.Management.Automation.PSCredential
        The reconstructed credential, or $null on validation/decryption failure.

    .EXAMPLE
        $envelope = Get-Content -Raw -Path $file | ConvertFrom-Json
        $cred = ConvertFrom-SEBProtectedCredential -Envelope $envelope
    #>
    [CmdletBinding()]
    [OutputType([PSCredential])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNull()]
        [object]$Envelope
    )

    # Read fields tolerantly so either a ConvertFrom-Json PSCustomObject or a
    # hashtable works.
    $format   = $Envelope.Format
    $userName = $Envelope.UserName
    $b64       = $Envelope.ProtectedSecret

    if ($format -ne 'SEBCredential') {
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Credential envelope has unexpected format '$format' (expected 'SEBCredential')."
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($b64)) {
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Credential envelope is missing UserName or ProtectedSecret."
        return $null
    }

    $plainBytes = $null
    try {
        $protected = [Convert]::FromBase64String($b64)
        $plainBytes = Unprotect-SEBSecret -Bytes $protected
        if ($null -eq $plainBytes) {
            # Unprotect-SEBSecret already logged the underlying CryptographicException.
            return $null
        }

        $plain = [System.Text.Encoding]::UTF8.GetString($plainBytes)
        $secure = [System.Security.SecureString]::new()
        foreach ($ch in $plain.ToCharArray()) {
            $secure.AppendChar($ch)
        }
        $secure.MakeReadOnly()

        return [System.Management.Automation.PSCredential]::new($userName, $secure)
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Failed to rebuild credential from protected envelope: $_"
        return $null
    }
    finally {
        if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
    }
}
