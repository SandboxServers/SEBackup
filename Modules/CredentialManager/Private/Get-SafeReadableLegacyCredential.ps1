function Get-SafeReadableLegacyCredential {
    <#
    .SYNOPSIS
        Reads a legacy Export-Clixml credential file READ-ONLY and returns it as a
        non-migrated ('NotReadable') result.

    .DESCRIPTION
        Used by Convert-SEBLegacyCredential on the fail-safe path: when the
        cross-process migration mutex cannot be created or acquired, the destructive
        re-save/verify/delete sequence MUST be skipped (an unsynchronised second
        process could be doing the same thing). This helper performs only the safe,
        side-effect-free half -- an Import-Clixml of the legacy file -- so the caller
        can still authenticate this run with the in-memory credential, WITHOUT writing
        the new ".cred", deleting the legacy ".cred.xml", or touching any ACL.

        It returns a 'NotReadable' status (never 'Migrated') because nothing was
        actually persisted; the credential is carried in the result only so the caller
        (Get-SEBCredential) can use it and warn that a re-save is recommended. If the
        legacy file cannot be read (e.g. it was saved by a different user) or does not
        deserialize to a PSCredential, the Credential is $null.

        This never throws; failures are reported through the returned status. Internal;
        not exported.

    .PARAMETER LegacyFile
        The full path to the legacy "{NodeName}.cred.xml" file to read.

    .OUTPUTS
        System.Collections.Hashtable
        @{ Status = 'NotReadable'; Credential = <PSCredential or $null> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$LegacyFile
    )

    if (-not (Test-Path -LiteralPath $LegacyFile)) {
        return @{ Status = 'NotReadable'; Credential = $null }
    }

    try {
        $legacyCred = Import-Clixml -LiteralPath $LegacyFile -ErrorAction Stop
    }
    catch {
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message (
            "Legacy credential '$LegacyFile' could not be read (likely saved by a " +
            "different user): $_")
        return @{ Status = 'NotReadable'; Credential = $null }
    }

    if ($legacyCred -isnot [PSCredential]) {
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Legacy credential file '$LegacyFile' did not contain a PSCredential; leaving it in place."
        return @{ Status = 'NotReadable'; Credential = $null }
    }

    return @{ Status = 'NotReadable'; Credential = $legacyCred }
}
