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
    param(
        # When supplied, returns the full credential FILE path for the node, with the node
        # name validated so it cannot traverse out of the Credentials directory.
        [Parameter()]
        [string]$NodeName
    )

    # Navigate from Modules/CredentialManager/ up to project root, then into Credentials/
    $projectRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $credentialDir = Join-Path -Path $projectRoot -ChildPath 'Credentials'

    if (-not (Test-Path -Path $credentialDir)) {
        New-Item -Path $credentialDir -ItemType Directory -Force | Out-Null
        Write-Verbose "Created credentials directory: $credentialDir"
    }

    if ($PSBoundParameters.ContainsKey('NodeName')) {
        # A node name is used as a filename component. Reject anything with a path separator,
        # drive qualifier, or '.'/'..' so a hostile or fat-fingered name cannot write or read
        # a credential file outside the Credentials directory.
        #
        # This intentionally keeps its own ALLOWLIST ('^[A-Za-z0-9._-]+$', plus the explicit
        # '.'/'..' reject below) rather than calling the shared Test-SEBSafeName denylist (issue
        # #28). Credential files are the most security-sensitive path in the system, so an allowlist
        # (deny-by-default) is used here -- it rejects spaces and the broader set of filename-legal
        # Unicode characters that Test-SEBSafeName permits for operator-chosen instance/node names.
        # The two checks AGREE on rejecting the dangerous cases (path separators, drive/UNC roots,
        # wildcards, and '.'/'..'), but NEITHER is a strict subset of the other: this allowlist
        # rejects characters Test-SEBSafeName allows, while Test-SEBSafeName rejects an embedded
        # '..' ANYWHERE (e.g. 'foo..bar') that this character-class allowlist would otherwise accept
        # -- which is why the explicit '.'/'..' guard below is required for the dotted-name case.
        if ($NodeName -notmatch '^[A-Za-z0-9._-]+$' -or $NodeName -in @('.', '..')) {
            throw "Invalid node name '$NodeName': only letters, digits, '.', '-', and '_' are allowed (no path separators)."
        }
        return Join-Path -Path $credentialDir -ChildPath "$NodeName.cred.xml"
    }

    return $credentialDir
}
