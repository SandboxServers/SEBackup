function Test-SEBProtectedCredentialReadBack {
    <#
    .SYNOPSIS
        Round-trip-verifies that a just-written "*.cred" file actually decrypts on
        THIS host (and optionally matches an expected credential).

    .DESCRIPTION
        The safety check that gates every DESTRUCTIVE step in the credential store
        (deleting a legacy .cred.xml after migration, or removing a superseded
        legacy file after Save/Update). Write-SEBProtectedCredentialFile reporting
        success only proves the ciphertext was written and ACL'd -- NOT that it can
        be decrypted again. If Get-SEBSecretEntropy took its salt-only MachineGuid
        fallback at write time but not at a later read (a transient registry/ACL
        hiccup), the blob is bound to entropy that cannot be reproduced and is
        permanently undecryptable. Deleting the only other readable copy before
        confirming the replacement is recoverable is how a credential gets lost.

        This reads the file back from disk, parses the envelope, decrypts it via
        ConvertFrom-SEBProtectedCredential, and -- when an -Expected credential is
        supplied -- compares the recovered username and password to it. It returns
        $true only on a successful, matching round-trip.

        Never throws; any failure is logged and returns $false so the caller keeps
        the source file. Internal; not exported.

    .PARAMETER Path
        The "*.cred" file to read back and decrypt.

    .PARAMETER Expected
        Optional PSCredential to compare the decrypted result against. When given,
        BOTH the username and the plaintext password must match for $true. When
        omitted, a successful decrypt alone is sufficient.

    .OUTPUTS
        System.Boolean
        $true if the file decrypts on this host (and matches -Expected when given);
        $false otherwise.

    .EXAMPLE
        if (Test-SEBProtectedCredentialReadBack -Path $file -Expected $legacyCred) {
            Remove-Item -LiteralPath $legacyFile -Force
        }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Position = 1)]
        [PSCredential]$Expected
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Round-trip verification failed: credential file '$Path' does not exist after write."
        return $false
    }

    $recovered = $null
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Round-trip verification failed: credential file '$Path' is empty after write."
            return $false
        }
        $envelope = $raw | ConvertFrom-Json -ErrorAction Stop
        $recovered = ConvertFrom-SEBProtectedCredential -Envelope $envelope
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Round-trip verification of '$Path' failed to read/parse the written credential: $_"
        return $false
    }

    if ($null -eq $recovered) {
        # ConvertFrom-SEBProtectedCredential already logged the decryption cause.
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Round-trip verification of '$Path' failed: the just-written credential did not decrypt on this host."
        return $false
    }

    if ($PSBoundParameters.ContainsKey('Expected') -and $null -ne $Expected) {
        if ($recovered.UserName -ne $Expected.UserName) {
            Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Round-trip verification of '$Path' failed: recovered username does not match the source."
            return $false
        }
        # Compare passwords via the unmanaged BSTRs so we never build a managed
        # String of either secret; zero-free both BSTRs in finally.
        $bstrA = [IntPtr]::Zero
        $bstrB = [IntPtr]::Zero
        try {
            $bstrA = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($recovered.Password)
            $bstrB = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Expected.Password)
            $lenA = $recovered.Password.Length
            $lenB = $Expected.Password.Length
            if ($lenA -ne $lenB) {
                Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Round-trip verification of '$Path' failed: recovered password does not match the source."
                return $false
            }
            for ($i = 0; $i -lt $lenA; $i++) {
                $a = [System.Runtime.InteropServices.Marshal]::ReadInt16($bstrA, $i * 2)
                $b = [System.Runtime.InteropServices.Marshal]::ReadInt16($bstrB, $i * 2)
                if ($a -ne $b) {
                    Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Round-trip verification of '$Path' failed: recovered password does not match the source."
                    return $false
                }
            }
        }
        finally {
            if ($bstrA -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrA) }
            if ($bstrB -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrB) }
        }
    }

    return $true
}
