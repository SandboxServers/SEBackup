function Write-SEBProtectedCredentialFile {
    <#
    .SYNOPSIS
        Persists a PSCredential to the new protected "*.cred" store with a hardened ACL.

    .DESCRIPTION
        The single write path shared by Save-SEBCredential, Update-SEBCredential,
        and the legacy-migration re-save action. It:
        1. Serializes the credential into the protected envelope via
           ConvertTo-SEBProtectedCredential (LocalMachine DPAPI + per-machine
           entropy; only the password ciphertext is stored).
        2. Writes the envelope JSON ATOMICALLY: it writes to a sibling temp file,
           hardens that temp file's ACL, then renames it over the destination with
           Move-Item (an atomic rename on the same volume). A mid-write failure
           therefore leaves any previous valid "{NodeName}.cred" intact -- critical
           because Update's in-place rotation reads the OLD blob and Save/Update
           delete the legacy .cred.xml, so a truncated overwrite could otherwise
           destroy the only copy.
        3. Because the ACL is applied to the temp file BEFORE the rename, the
           credential ciphertext is never visible at its final path with an
           inherited (possibly Users-readable) ACL -- closing the write-then-tighten
           TOCTOU window.

        ACL hardening is treated as REQUIRED, not best-effort: the file ACL is the
        only local confidentiality boundary (any local process can call Unprotect
        and the entropy is reproducible on-box). If Set-SEBCredentialAcl fails, the
        function logs ERROR, removes the temp file, and returns $false WITHOUT
        publishing the credential, so callers never report success while a secret
        sits world-readable and never delete the legacy fallback.

        Centralising this guarantees every code path produces an identically
        formatted, identically protected, identically ACL'd file. Internal;
        not exported.

    .PARAMETER NodeName
        The node to write the credential for. Validated by Resolve-CredentialPath.

    .PARAMETER Credential
        The PSCredential to persist. Must not be null.

    .OUTPUTS
        System.Boolean
        $true on success; $false if serialization or the file write failed (the
        underlying error is logged via Write-SEBLog).

    .EXAMPLE
        Write-SEBProtectedCredentialFile -NodeName 'Node01' -Credential $cred
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNull()]
        [PSCredential]$Credential
    )

    $envelope = ConvertTo-SEBProtectedCredential -Credential $Credential
    if ($null -eq $envelope) {
        # ConvertTo-SEBProtectedCredential already logged the cause.
        return $false
    }

    $credentialFile = Resolve-CredentialPath -NodeName $NodeName

    # Write to a sibling temp file, harden it, then atomically rename it into place.
    # This guarantees a mid-write failure leaves any existing .cred untouched and
    # that the final file is never momentarily present with a permissive ACL.
    $tempFile = "$credentialFile.tmp.$([guid]::NewGuid().ToString('n'))"
    try {
        # Depth 3 is ample for the flat envelope; Set-Content writes UTF-8 in pwsh 7.
        $json = $envelope | ConvertTo-Json -Depth 3
        Set-Content -LiteralPath $tempFile -Value $json -Encoding UTF8 -Force -ErrorAction Stop
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Failed to write protected credential file '$credentialFile': $_"
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Harden BEFORE publishing. The ACL is the only local boundary, so a failure to
    # apply it is fatal: discard the temp file and report failure rather than leave
    # a readable secret on disk (and rather than let the caller delete the legacy
    # fallback).
    $hardened = Set-SEBCredentialAcl -Path $tempFile
    if (-not $hardened) {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message (
            "Wrote protected credential for node '$NodeName' but FAILED to restrict its ACL; " +
            "discarding it rather than leaving the ciphertext readable by non-admin users. " +
            "Re-save from an elevated session: Save-SEBCredential -NodeName '$NodeName'.")
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Atomic publish: rename over the destination (same volume => atomic).
    try {
        Move-Item -LiteralPath $tempFile -Destination $credentialFile -Force -ErrorAction Stop
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Failed to publish protected credential file '$credentialFile' (rename failed): $_"
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    return $true
}
