function Get-SEBCredential {
    <#
    .SYNOPSIS
        Retrieves a stored PSCredential for a remote SEBackup node.

    .DESCRIPTION
        Reads and deserializes a DPAPI-encrypted PSCredential from the credential
        file at Credentials/{NodeName}.cred.xml using Import-Clixml.

        If the credential file does not exist, an error is thrown with guidance
        to run Setup-Node.ps1 or Save-SEBCredential to store credentials first.

        Because DPAPI encryption is tied to the current Windows user account and
        machine, the credential can only be read by the same user on the same
        machine that created it.

    .PARAMETER NodeName
        The name of the remote node whose credential should be retrieved.

    .EXAMPLE
        $cred = Get-SEBCredential -NodeName "GameServer01"
        # Returns the stored PSCredential for GameServer01.

    .EXAMPLE
        New-PSSession -ComputerName "GameServer01" -Credential (Get-SEBCredential -NodeName "GameServer01")
        # Uses the stored credential to open a remote session.

    .OUTPUTS
        System.Management.Automation.PSCredential
        The deserialized PSCredential object for the specified node.
    #>
    [CmdletBinding()]
    [OutputType([PSCredential])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName
    )

    $credentialDir = Resolve-CredentialPath
    $credentialFile = Join-Path -Path $credentialDir -ChildPath "$NodeName.cred.xml"

    if (-not (Test-Path -Path $credentialFile)) {
        throw "No credential found for node '$NodeName'. Expected file: $credentialFile`n" +
              "Run Setup-Node.ps1 or Save-SEBCredential -NodeName '$NodeName' to store credentials first."
    }

    try {
        $credential = Import-Clixml -Path $credentialFile
        Write-Verbose "Credential loaded for node '$NodeName' (User: $($credential.UserName))"
        return $credential
    }
    catch {
        throw "Failed to read credential for node '$NodeName' from '$credentialFile'. " +
              "The file may be corrupted or was encrypted by a different user/machine: $_"
    }
}
