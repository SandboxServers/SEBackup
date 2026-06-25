function Resolve-CredentialPath {
    <#
    .SYNOPSIS
        Resolves the path to the SEBackup Credentials directory or a node's
        credential file.

    .DESCRIPTION
        Internal helper function that determines the absolute path to the
        Credentials/ directory at the project root. This function lives at
        Modules/CredentialManager/Private/ -- THREE levels below the project root
        -- so it walks up three parents to reach it (matching the BackupEngine
        lock-file helpers at the same depth). The store therefore lands at the
        documented project-root Credentials/ directory, NOT Modules/Credentials/.

        If the Credentials directory does not exist, this function creates it. On
        every resolution it (re)applies the restrictive ACL to the directory so an
        already-existing Credentials/ (created by an earlier version, the legacy
        .cred.xml era, git, or another tool) is locked down too -- not only when
        this code creates it. Set-SEBCredentialAcl is idempotent, so the call is
        cheap when the directory is already hardened.

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

    # Navigate from Modules/CredentialManager/Private/ up to the project root
    # (three parents: Private -> CredentialManager -> Modules -> root), then into
    # Credentials/. This matches BackupEngine\Public\New-SEBLockFile.ps1 and keeps
    # the store at the project-root Credentials/ that every doc references.
    $projectRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
    $credentialDir = Join-Path -Path $projectRoot -ChildPath 'Credentials'

    # -LiteralPath on the existence check: the project root can legitimately contain
    # PowerShell wildcard characters ('[', ']') in a path segment, which a -Path
    # Test-Path would interpret as a pattern -- making it miss an existing Credentials
    # directory and re-run New-Item. (New-Item has no -LiteralPath, but its -Path does
    # NOT expand wildcards for creation, so it already treats the path literally.)
    if (-not (Test-Path -LiteralPath $credentialDir)) {
        New-Item -Path $credentialDir -ItemType Directory -Force | Out-Null
        Write-Verbose "Created credentials directory: $credentialDir"
    }

    # Harden the directory on EVERY resolution, not just on creation: an existing
    # Credentials/ (legacy era, manual mkdir, git checkout) would otherwise keep its
    # inherited Users access, and a newly written .cred would inherit that before
    # its own ACL is stamped. Set-SEBCredentialAcl is idempotent (fast-path returns
    # without a security-descriptor write when already hardened), so this is cheap.
    # Best-effort: a failure is logged inside Set-SEBCredentialAcl and must not block
    # path resolution (each file also gets its own ACL on save).
    $null = Set-SEBCredentialAcl -Path $credentialDir

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
        $extension = if ($Legacy) { '.cred.xml' } else { '.cred' }
        return Join-Path -Path $credentialDir -ChildPath "$NodeName$extension"
    }

    return $credentialDir
}
