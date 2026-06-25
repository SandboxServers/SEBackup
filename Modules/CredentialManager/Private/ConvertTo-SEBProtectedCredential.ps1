function ConvertTo-SEBProtectedCredential {
    <#
    .SYNOPSIS
        Serializes a PSCredential into the on-disk protected-credential envelope.

    .DESCRIPTION
        Converts a PSCredential into the hashtable envelope persisted by
        Save-SEBCredential as the new "*.cred" format. The password is the only
        secret: its SecureString is marshalled to a transient managed string, the
        UTF-8 bytes are protected via Protect-SEBSecret (LocalMachine DPAPI +
        per-machine entropy), and only the Base64 of the resulting ciphertext is
        stored. The username is stored in clear because usernames are not secrets
        (the legacy Export-Clixml format also stored them recoverably).

        The transient plaintext is zeroed/freed in a finally block to minimise how
        long the password lives in unmanaged memory.

        Envelope schema (serialized to JSON by the caller):
            Format          = 'SEBCredential'   # format discriminator
            Version         = 1                  # envelope version
            Scope           = 'LocalMachine'     # documents the DPAPI scope used
            UserName        = '<plaintext user>'
            ProtectedSecret = '<base64 DPAPI ciphertext of the password bytes>'

        Internal helper; not exported.

    .PARAMETER Credential
        The PSCredential to serialize. Must not be null.

    .OUTPUTS
        System.Collections.Hashtable
        The envelope hashtable, or $null if protection failed (logged upstream).

    .EXAMPLE
        $envelope = ConvertTo-SEBProtectedCredential -Credential $cred
        $envelope | ConvertTo-Json | Set-Content -Path $file
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNull()]
        [PSCredential]$Credential
    )

    $bstr = [IntPtr]::Zero
    $plainBytes = $null
    try {
        # Marshal the SecureString to a BSTR, copy out the chars, then immediately
        # free the BSTR. PtrToStringBSTR honors embedded characters and length.
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($plain)

        $protected = Protect-SEBSecret -Bytes $plainBytes
        if ($null -eq $protected) {
            # Protect-SEBSecret already logged the underlying error.
            return $null
        }

        return @{
            Format          = 'SEBCredential'
            Version         = 1
            Scope           = 'LocalMachine'
            UserName        = $Credential.UserName
            ProtectedSecret = [Convert]::ToBase64String($protected)
        }
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Failed to serialize credential into protected envelope: $_"
        return $null
    }
    finally {
        # Best-effort scrub of the transient plaintext bytes, then free the BSTR.
        if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}
