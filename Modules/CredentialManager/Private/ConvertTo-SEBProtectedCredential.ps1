function ConvertTo-SEBProtectedCredential {
    <#
    .SYNOPSIS
        Serializes a PSCredential into the on-disk protected-credential envelope.

    .DESCRIPTION
        Converts a PSCredential into the hashtable envelope persisted by
        Save-SEBCredential as the new "*.cred" format. The password is the only
        secret: its SecureString is marshalled to an unmanaged BSTR, the UTF-16
        code units are copied directly into a byte buffer (never into a managed
        String, which would be immutable and unscrubbable), transcoded to UTF-8,
        protected via Protect-SEBSecret (LocalMachine DPAPI + per-machine
        entropy), and only the Base64 of the resulting ciphertext is stored. The
        username is stored in clear because usernames are not secrets (the legacy
        Export-Clixml format also stored them recoverably).

        Every transient plaintext buffer (the char[] code units, the UTF-16 bytes,
        and the UTF-8 bytes) is zeroed and the BSTR is zero-freed in a finally
        block, so the cleartext password is never left in a managed String and
        lives in memory only briefly.

        Envelope schema (serialized to JSON by the caller):
            Format          = 'SEBCredential'   # format discriminator
            Version         = 1                  # envelope version (load-bearing; ConvertFrom rejects unknown)
            Scope           = 'LocalMachine'     # the DPAPI scope used (validated on read)
            EntropyVersion  = <int>              # entropy/salt version the blob was written under
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
    $chars = $null
    $utf16Bytes = $null
    $plainBytes = $null
    try {
        # Marshal the SecureString to an unmanaged BSTR and read its UTF-16 code
        # units directly into a char[] we own. We deliberately do NOT call
        # PtrToStringBSTR: that would create an immutable managed String of the
        # password which cannot be scrubbed and would linger on the heap.
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        $charCount = $Credential.Password.Length
        $chars = [char[]]::new($charCount)
        for ($i = 0; $i -lt $charCount; $i++) {
            $chars[$i] = [char][System.Runtime.InteropServices.Marshal]::ReadInt16($bstr, $i * 2)
        }
        # Transcode UTF-16 -> UTF-8 without an intermediate String.
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($chars)

        $protected = Protect-SEBSecret -Bytes $plainBytes
        if ($null -eq $protected) {
            # Protect-SEBSecret already logged the underlying error.
            return $null
        }

        return @{
            Format          = 'SEBCredential'
            Version         = 1
            Scope           = 'LocalMachine'
            EntropyVersion  = $script:SEBEntropyVersion
            UserName        = $Credential.UserName
            ProtectedSecret = [Convert]::ToBase64String($protected)
        }
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Failed to serialize credential into protected envelope: $_"
        return $null
    }
    finally {
        # Best-effort scrub of every transient plaintext buffer, then free the BSTR
        # (ZeroFreeBSTR zeroes the unmanaged copy before freeing).
        if ($plainBytes)  { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        if ($utf16Bytes)  { [Array]::Clear($utf16Bytes, 0, $utf16Bytes.Length) }
        if ($chars)       { [Array]::Clear($chars, 0, $chars.Length) }
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}
