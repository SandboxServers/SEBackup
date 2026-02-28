function Save-SEBCredential {
    <#
    .SYNOPSIS
        Saves a PSCredential for a remote SEBackup node as DPAPI-encrypted XML.

    .DESCRIPTION
        Stores a PSCredential object for the specified node by serializing it to
        a DPAPI-encrypted XML file using Export-Clixml. The credential file is
        saved at Credentials/{NodeName}.cred.xml relative to the SEBackup project
        root.

        If the -Credential parameter is not provided, the user is prompted
        interactively via Get-Credential.

        The Credentials directory is created automatically if it does not exist.

        Because DPAPI encryption is tied to the current Windows user account and
        machine, credential files can only be decrypted by the same user on the
        same machine that created them.

    .PARAMETER NodeName
        The name of the remote node to store credentials for. This is used as
        the filename stem for the credential file (e.g., "GameServer01" produces
        Credentials/GameServer01.cred.xml).

    .PARAMETER Credential
        A PSCredential object containing the username and password for the remote
        node. If not provided, the user is prompted interactively.

    .EXAMPLE
        Save-SEBCredential -NodeName "GameServer01"
        # Prompts for credentials and saves them for GameServer01.

    .EXAMPLE
        $cred = Get-Credential -UserName "Admin" -Message "Enter password for GameServer01"
        Save-SEBCredential -NodeName "GameServer01" -Credential $cred
        # Saves the provided credential without prompting.

    .EXAMPLE
        Save-SEBCredential -NodeName "GameServer01" -Credential (New-Object PSCredential("Admin", (ConvertTo-SecureString "P@ss" -AsPlainText -Force)))
        # Saves a programmatically created credential (useful for automation).

    .OUTPUTS
        None. The credential is written to disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter(Position = 1)]
        [PSCredential]$Credential
    )

    if (-not $PSBoundParameters.ContainsKey('Credential')) {
        $Credential = Get-Credential -Message "Enter credentials for SEBackup node '$NodeName'"
        if (-not $Credential) {
            throw "No credential was provided for node '$NodeName'. Operation cancelled."
        }
    }

    $credentialDir = Resolve-CredentialPath
    $credentialFile = Join-Path -Path $credentialDir -ChildPath "$NodeName.cred.xml"

    try {
        $Credential | Export-Clixml -Path $credentialFile -Force
        Write-Verbose "Credential saved for node '$NodeName' at: $credentialFile"
    }
    catch {
        throw "Failed to save credential for node '$NodeName': $_"
    }
}
