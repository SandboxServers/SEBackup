function Resolve-CredentialPath {
    <#
    .SYNOPSIS
        Resolves the path to the SEBackup Credentials directory or a node's
        credential file.

    .DESCRIPTION
        Internal helper function that determines the absolute path to the
        Credentials/ directory at the project root. The path is resolved
        relative to the CredentialManager module location, which resides at
        Modules/CredentialManager/ -- two levels below the project root.

        If the Credentials directory does not exist, this function creates it.

        When -NodeName is supplied, the node-specific credential FILE path is
        returned. The node name is validated so it cannot traverse out of the
        Credentials directory. By default the new protected format extension
        (".cred") is used; pass -Legacy to resolve the original Export-Clixml
        path (".cred.xml"), which is needed for transparent migration of
        credentials saved before issue #27.

        This function is not exported and is intended for use only within the
        CredentialManager module.

    .PARAMETER NodeName
        When supplied, returns the full credential FILE path for the node, with
        the node name validated so it cannot traverse out of the Credentials
        directory.

    .PARAMETER Legacy
        When supplied together with -NodeName, returns the LEGACY credential file
        path ("{NodeName}.cred.xml") used by the pre-#27 Export-Clixml store,
        instead of the new "{NodeName}.cred" path. Used by the migration path.

    .OUTPUTS
        System.String
        The absolute path to the Credentials directory, or to the node credential
        file when -NodeName is supplied.

    .EXAMPLE
        $credPath = Resolve-CredentialPath
        # Returns something like: C:\Projects\SEBackup\Credentials

    .EXAMPLE
        $file = Resolve-CredentialPath -NodeName 'GameServer01'
        # Returns: ...\Credentials\GameServer01.cred  (new protected format)

    .EXAMPLE
        $legacy = Resolve-CredentialPath -NodeName 'GameServer01' -Legacy
        # Returns: ...\Credentials\GameServer01.cred.xml  (old Clixml format)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$NodeName,

        [Parameter()]
        [switch]$Legacy
    )

    # Navigate from Modules/CredentialManager/ up to project root, then into Credentials/
    $projectRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $credentialDir = Join-Path -Path $projectRoot -ChildPath 'Credentials'

    if (-not (Test-Path -Path $credentialDir)) {
        New-Item -Path $credentialDir -ItemType Directory -Force | Out-Null
        Write-Verbose "Created credentials directory: $credentialDir"
        # Harden the directory on creation so credential files inherit a locked-down
        # ACL. Best-effort: a failure here is logged inside Set-SEBCredentialAcl and
        # must not block path resolution (the files get their own ACL on save too).
        $null = Set-SEBCredentialAcl -Path $credentialDir
    }

    if ($PSBoundParameters.ContainsKey('NodeName')) {
        # A node name is used as a filename component. Reject anything with a path separator,
        # drive qualifier, or '.'/'..' so a hostile or fat-fingered name cannot write or read
        # a credential file outside the Credentials directory.
        if ($NodeName -notmatch '^[A-Za-z0-9._-]+$' -or $NodeName -in @('.', '..')) {
            throw "Invalid node name '$NodeName': only letters, digits, '.', '-', and '_' are allowed (no path separators)."
        }
        $extension = if ($Legacy) { '.cred.xml' } else { '.cred' }
        return Join-Path -Path $credentialDir -ChildPath "$NodeName$extension"
    }

    return $credentialDir
}
