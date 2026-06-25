function Test-SEBCredential {
    <#
    .SYNOPSIS
        Tests whether a stored credential exists and is readable for a remote SEBackup node.

    .DESCRIPTION
        Checks if a DPAPI-encrypted credential file exists at
        Credentials/{NodeName}.cred.xml and attempts to deserialize it using
        Import-Clixml. Returns $true if the file exists and can be successfully
        read as a PSCredential, $false otherwise.

        This function never throws. It is designed for use in conditional logic
        and validation checks.

    .PARAMETER NodeName
        The name of the remote node whose credential should be tested.

    .EXAMPLE
        if (Test-SEBCredential -NodeName "GameServer01") {
            Write-Host "Credentials are available for GameServer01"
        }

    .EXAMPLE
        $nodes = @("Server01", "Server02", "Server03")
        $nodes | Where-Object { -not (Test-SEBCredential -NodeName $_) }
        # Returns the names of nodes that do NOT have stored credentials.

    .OUTPUTS
        System.Boolean
        $true if the credential file exists and can be read; $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName
    )

    $credentialFile = Resolve-CredentialPath -NodeName $NodeName

    if (-not (Test-Path -Path $credentialFile)) {
        Write-Verbose "Credential file not found for node '$NodeName': $credentialFile"
        return $false
    }

    try {
        $credential = Import-Clixml -Path $credentialFile
        if ($credential -is [PSCredential]) {
            Write-Verbose "Credential for node '$NodeName' is valid (User: $($credential.UserName))"
            return $true
        }
        else {
            Write-Verbose "Credential file for node '$NodeName' does not contain a PSCredential object."
            return $false
        }
    }
    catch {
        Write-Verbose "Failed to read credential for node '$NodeName': $_"
        return $false
    }
}
