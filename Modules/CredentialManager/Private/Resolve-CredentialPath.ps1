function Resolve-CredentialPath {
    <#
    .SYNOPSIS
        Resolves the path to the SEBackup Credentials directory.

    .DESCRIPTION
        Internal helper function that determines the absolute path to the
        Credentials/ directory at the project root. The path is resolved
        relative to the CredentialManager module location, which resides at
        Modules/CredentialManager/ -- two levels below the project root.

        If the Credentials directory does not exist, this function creates it.

        This function is not exported and is intended for use only within the
        CredentialManager module.

    .OUTPUTS
        System.String
        The absolute path to the Credentials directory.

    .EXAMPLE
        $credPath = Resolve-CredentialPath
        # Returns something like: C:\Projects\SEBackup\Credentials
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Navigate from Modules/CredentialManager/ up to project root, then into Credentials/
    $projectRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $credentialDir = Join-Path -Path $projectRoot -ChildPath 'Credentials'

    if (-not (Test-Path -Path $credentialDir)) {
        New-Item -Path $credentialDir -ItemType Directory -Force | Out-Null
        Write-Verbose "Created credentials directory: $credentialDir"
    }

    return $credentialDir
}
