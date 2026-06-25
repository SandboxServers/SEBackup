function Convert-SEBLegacyCredential {
    <#
    .SYNOPSIS
        Migrates a legacy Export-Clixml credential file to the new protected format.

    .DESCRIPTION
        Best-effort, transparent migration for credentials saved before issue #27.
        The legacy store used Export-Clixml, whose password SecureString is sealed
        with CurrentUser-scope DPAPI -- readable only by the user who saved it on
        this machine. This helper attempts to Import-Clixml the legacy
        "{NodeName}.cred.xml" file and, if it deserializes to a PSCredential,
        re-saves it through the new LocalMachine-DPAPI protected store
        ("{NodeName}.cred") via the supplied re-save script block.

        Outcomes:
        - Migrated  : legacy file was readable; a new ".cred" was written. The
          legacy ".cred.xml" is then deleted so it is not mistaken for current.
        - NotReadable: legacy file exists but could not be decrypted (e.g. it was
          created by a different user). It is LEFT in place and the caller surfaces
          a clear "re-save required" warning. Nothing is destroyed.
        - None      : no legacy file present.

        This never throws; failures are reported through the returned status so the
        calling Get/Test path can continue. Internal; not exported.

    .PARAMETER NodeName
        The node whose legacy credential should be migrated.

    .PARAMETER SaveAction
        A script block that persists a PSCredential in the NEW protected format for
        the node. It receives the PSCredential as its only argument. Injected by
        the caller (Save-SEBCredential's serialization path) to avoid a circular
        dependency and to keep all writing logic in one place. Must return $true on
        success.

    .OUTPUTS
        System.Collections.Hashtable
        @{ Status = 'Migrated' | 'NotReadable' | 'None'; Credential = <PSCredential or $null> }

    .EXAMPLE
        $result = Convert-SEBLegacyCredential -NodeName 'Node01' -SaveAction {
            param($cred) Write-SEBProtectedCredentialFile -NodeName 'Node01' -Credential $cred
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNull()]
        [scriptblock]$SaveAction
    )

    $legacyFile = Resolve-CredentialPath -NodeName $NodeName -Legacy

    if (-not (Test-Path -LiteralPath $legacyFile)) {
        return @{ Status = 'None'; Credential = $null }
    }

    # Try to read the legacy Clixml credential. This only succeeds for the same
    # user that saved it (CurrentUser DPAPI), which is the whole reason #27 exists.
    $legacyCred = $null
    try {
        $legacyCred = Import-Clixml -LiteralPath $legacyFile -ErrorAction Stop
    }
    catch {
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message (
            "Legacy credential '$legacyFile' could not be read for migration " +
            "(likely saved by a different user): $_")
        return @{ Status = 'NotReadable'; Credential = $null }
    }

    if ($legacyCred -isnot [PSCredential]) {
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Legacy credential file '$legacyFile' did not contain a PSCredential; leaving it in place."
        return @{ Status = 'NotReadable'; Credential = $null }
    }

    # Re-save in the new format using the injected writer.
    try {
        $saved = & $SaveAction $legacyCred
        if (-not $saved) {
            Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Migration of '$NodeName' failed while writing the new protected credential; legacy file left intact."
            return @{ Status = 'NotReadable'; Credential = $legacyCred }
        }
    }
    catch {
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Migration of '$NodeName' threw while writing the new protected credential; legacy file left intact: $_"
        return @{ Status = 'NotReadable'; Credential = $legacyCred }
    }

    # New format written successfully -- remove the legacy file so it is not
    # ambiguous which store is authoritative.
    try {
        Remove-Item -LiteralPath $legacyFile -Force -ErrorAction Stop
        Write-SEBLog -Level INFO -Context 'CredentialManager' -Message "Migrated credential for node '$NodeName' from legacy Clixml to LocalMachine-DPAPI protected format; removed '$legacyFile'."
    }
    catch {
        # The new file is valid; failing to delete the old one is non-fatal.
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Migrated '$NodeName' to the new format but could not remove the legacy file '$legacyFile': $_"
    }

    return @{ Status = 'Migrated'; Credential = $legacyCred }
}
