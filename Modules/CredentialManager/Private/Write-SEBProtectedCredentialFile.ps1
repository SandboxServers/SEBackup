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
        2. Writes the envelope as JSON to "{NodeName}.cred" (UTF-8).
        3. Applies the restrictive ACL via Set-SEBCredentialAcl so only SYSTEM,
           Administrators, and the current account can read it.

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

    try {
        # Depth 3 is ample for the flat envelope; Set-Content writes UTF-8 in pwsh 7.
        $json = $envelope | ConvertTo-Json -Depth 3
        Set-Content -LiteralPath $credentialFile -Value $json -Encoding UTF8 -Force -ErrorAction Stop
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Failed to write protected credential file '$credentialFile': $_"
        return $false
    }

    # Harden the file. A failure is logged but does not undo the (encrypted) write.
    $null = Set-SEBCredentialAcl -Path $credentialFile

    return $true
}
