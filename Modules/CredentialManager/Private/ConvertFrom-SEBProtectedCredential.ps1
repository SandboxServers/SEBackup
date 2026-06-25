function ConvertFrom-SEBProtectedCredential {
    <#
    .SYNOPSIS
        Rebuilds a PSCredential from the on-disk protected-credential envelope.

    .DESCRIPTION
        The inverse of ConvertTo-SEBProtectedCredential. Validates the envelope --
        including the load-bearing Format, Version, and Scope discriminators --
        Base64-decodes the protected password, decrypts it via Unprotect-SEBSecret
        (LocalMachine DPAPI + the per-machine entropy of the version recorded in
        the envelope), and reconstructs a PSCredential whose password is a
        SecureString. The decrypted bytes are decoded to UTF-16 code units and
        appended to the SecureString one code unit at a time; every transient
        buffer (the decrypted UTF-8 bytes and the char[]) is zeroed in a finally
        block so the cleartext is never held in a managed String.

        Forward/back compatibility: Version is honored, not decorative. An envelope
        whose Version this build does not understand is REJECTED with a clear
        warning (returns $null) rather than being fed to the wrong decode path and
        failing with a generic CryptographicException. Scope is mandatory and must
        equal the backend this build implements ('LocalMachine'): a missing/null or
        mismatched Scope is rejected so a malformed envelope cannot be decrypted
        without proving which backend sealed it. EntropyVersion is passed through to
        Unprotect so a blob written under an earlier entropy rotation can still be
        decrypted.

        Returns $null (rather than throwing) when the envelope is malformed,
        carries an unsupported version/scope, or the decryption fails -- for
        example when the blob was created on a different machine or under a rotated
        entropy that is no longer derivable. The caller decides how to surface that
        (e.g. "re-save required").

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
    $version  = $Envelope.Version
    $scope    = $Envelope.Scope
    $userName = $Envelope.UserName
    $b64       = $Envelope.ProtectedSecret

    if ($format -ne 'SEBCredential') {
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Credential envelope has unexpected format '$format' (expected 'SEBCredential')."
        return $null
    }

    # Version is load-bearing: reject an envelope this build does not understand
    # rather than feeding a future format to the v1 decode path (which would fail
    # with an opaque CryptographicException). This is the forward-compat seam.
    $supportedVersion = 1
    if ($null -eq $version -or [int]$version -ne $supportedVersion) {
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message (
            "Credential envelope declares unsupported version '$version' " +
            "(this build supports version $supportedVersion). Re-save the credential on this host.")
        return $null
    }

    # Scope selects which protection backend wrote the blob and is load-bearing, NOT
    # decorative: a missing/null Scope must be REJECTED rather than accepted, otherwise
    # a malformed (or hand-crafted) envelope that simply omits the field would be
    # decrypted without ever proving which backend sealed it. This build implements
    # only the LocalMachine-DPAPI backend, so the field MUST be present AND equal to
    # 'LocalMachine'; anything else (absent, null, or a future gMSA/cert scope) is
    # rejected so a blob cannot be silently mis-decrypted by the wrong backend.
    $supportedScope = 'LocalMachine'
    if ($null -eq $scope -or $scope -ne $supportedScope) {
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message (
            "Credential envelope declares scope '$scope', but this build requires the " +
            "'$supportedScope' backend (the Scope field is mandatory). Re-save the credential on this host.")
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($b64)) {
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Credential envelope is missing UserName or ProtectedSecret."
        return $null
    }

    # Entropy version the blob was written under (defaults to current if absent for
    # forward-written v1 files that predate the field).
    $entropyVersion = if ($null -ne $Envelope.EntropyVersion) { [int]$Envelope.EntropyVersion } else { $script:SEBEntropyVersion }

    $plainBytes = $null
    $chars = $null
    try {
        $protected = [Convert]::FromBase64String($b64)
        $plainBytes = Unprotect-SEBSecret -Bytes $protected -EntropyVersion $entropyVersion
        if ($null -eq $plainBytes) {
            # Unprotect-SEBSecret already logged the underlying CryptographicException.
            return $null
        }

        # Decode UTF-8 -> UTF-16 code units into a char[] we own (no managed String
        # of the secret), append to the SecureString, then scrub the char[].
        $chars = [System.Text.Encoding]::UTF8.GetChars($plainBytes)
        $secure = [System.Security.SecureString]::new()
        foreach ($ch in $chars) {
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
        if ($chars)      { [Array]::Clear($chars, 0, $chars.Length) }
    }
}
