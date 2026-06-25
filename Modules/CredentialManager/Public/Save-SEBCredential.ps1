function Save-SEBCredential {
    <#
    .SYNOPSIS
        Saves a PSCredential for a remote SEBackup node using LocalMachine-DPAPI
        protection so unattended scheduled tasks can decrypt it.

    .DESCRIPTION
        Stores a PSCredential for the specified node in the protected "*.cred"
        format introduced for issue #27. The username is stored in clear (it is
        not a secret); the password is encrypted with the Windows Data Protection
        API using DataProtectionScope.LocalMachine plus a per-machine entropy
        value, then the ciphertext is written (Base64) inside a small JSON
        envelope at Credentials/{NodeName}.cred.

        Why LocalMachine scope: the previous Export-Clixml store sealed the
        password with CurrentUser-scope DPAPI, which binds it to the saving user's
        profile. An S4U / "run whether logged on or not" scheduled task has no
        loaded user profile and (per Microsoft) "no access to encrypted files", so
        it could not decrypt those credentials -- breaking unattended backups.
        LocalMachine scope binds the secret to the machine instead, so any process
        on the SAME C&C host (including that scheduled task) can decrypt it. The
        wider local reach is constrained by per-machine entropy and a restrictive
        ACL (SYSTEM + Administrators + the saving account; inherited/Users access
        removed).

        If -Credential is not provided, the user is prompted via Get-Credential.
        The Credentials directory is created and hardened automatically.

    .PARAMETER NodeName
        The name of the remote node to store credentials for. Used as the filename
        stem (e.g. "GameServer01" -> Credentials/GameServer01.cred).

    .PARAMETER Credential
        A PSCredential containing the username and password for the remote node.
        If not provided, the user is prompted interactively.

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
    [OutputType([void])]
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

    try {
        $saved = Write-SEBProtectedCredentialFile -NodeName $NodeName -Credential $Credential
        if (-not $saved) {
            throw "Credential protection or file write failed (see log for details)."
        }

        # If a legacy Clixml file for this node still exists, remove it so the two
        # stores cannot diverge. The new protected file is now authoritative.
        $legacyFile = Resolve-CredentialPath -NodeName $NodeName -Legacy
        if (Test-Path -LiteralPath $legacyFile) {
            Remove-Item -LiteralPath $legacyFile -Force -ErrorAction SilentlyContinue
            Write-SEBLog -Level INFO -Context 'CredentialManager' -Message "Removed superseded legacy credential file '$legacyFile' for node '$NodeName'."
        }

        $credentialFile = Resolve-CredentialPath -NodeName $NodeName
        Write-Verbose "Credential saved for node '$NodeName' at: $credentialFile"
        Write-SEBLog -Level INFO -Context 'CredentialManager' -Message "Saved credential for node '$NodeName' (user '$($Credential.UserName)') using LocalMachine-DPAPI protected store." -NoConsole
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Failed to save credential for node '$NodeName': $_"
        throw "Failed to save credential for node '$NodeName': $_"
    }
}
