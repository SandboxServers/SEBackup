function Remove-SEBCredential {
    <#
    .SYNOPSIS
        Removes a stored credential file for a remote SEBackup node.

    .DESCRIPTION
        Deletes the DPAPI-encrypted credential file at
        Credentials/{NodeName}.cred.xml. By default, the user is prompted for
        confirmation before deletion. Use the -Force switch to suppress the
        confirmation prompt.

        If the credential file does not exist, a warning is written and no
        error is thrown.

    .PARAMETER NodeName
        The name of the remote node whose credential should be removed.

    .PARAMETER Force
        Suppresses the confirmation prompt and removes the credential file
        immediately.

    .EXAMPLE
        Remove-SEBCredential -NodeName "GameServer01"
        # Prompts for confirmation, then removes the credential file.

    .EXAMPLE
        Remove-SEBCredential -NodeName "GameServer01" -Force
        # Removes the credential file without prompting.

    .EXAMPLE
        @("Server01", "Server02") | ForEach-Object { Remove-SEBCredential -NodeName $_ -Force }
        # Removes credentials for multiple nodes.

    .OUTPUTS
        None.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter()]
        [switch]$Force
    )

    $credentialDir = Resolve-CredentialPath
    $credentialFile = Join-Path -Path $credentialDir -ChildPath "$NodeName.cred.xml"

    if (-not (Test-Path -Path $credentialFile)) {
        Write-Warning "No credential file found for node '$NodeName' at: $credentialFile"
        return
    }

    if (-not $Force) {
        $confirm = Read-Host "Are you sure you want to remove the credential for node '$NodeName'? (Y/N)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Verbose "Removal of credential for node '$NodeName' was cancelled by the user."
            return
        }
    }

    try {
        Remove-Item -Path $credentialFile -Force
        Write-Verbose "Credential removed for node '$NodeName': $credentialFile"
    }
    catch {
        throw "Failed to remove credential for node '$NodeName': $_"
    }
}
