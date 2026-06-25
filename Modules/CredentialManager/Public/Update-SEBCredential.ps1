function Update-SEBCredential {
    <#
    .SYNOPSIS
        Rotates / re-encrypts a node's stored credential in the protected store.

    .DESCRIPTION
        Re-writes a node's credential through the current protection backend
        (LocalMachine DPAPI + per-machine entropy) and re-applies the restrictive
        ACL. Two modes:

        - Re-encrypt in place (default): with no -Credential, the existing stored
          credential is loaded via Get-SEBCredential and saved again. Use this
          after the protection parameters change -- for example after bumping the
          entropy salt version, after migrating from the legacy Clixml store, or
          to re-stamp the file's ACL. The username and password are preserved
          exactly. (This obviously requires the existing blob to still be readable
          on this host; if the entropy was already rotated past the point of no
          return, supply -Credential instead.)

        - Replace the secret: pass -Credential (e.g. after the node's password was
          changed) to store new material. The node's existing credential does not
          need to be readable for this path.

        Honors -WhatIf / -Confirm. Because rotation overwrites the stored secret it
        is treated as a Medium-impact change. On success the file is left in the
        new protected format with SYSTEM + Administrators + current-user ACL.

    .PARAMETER NodeName
        The node whose credential should be rotated. Validated by
        Resolve-CredentialPath.

    .PARAMETER Credential
        Optional replacement PSCredential. When supplied, its username/password
        become the new stored secret. When omitted, the existing stored credential
        is re-encrypted in place.

    .EXAMPLE
        Update-SEBCredential -NodeName "GameServer01"
        # Re-encrypts the existing credential in place (e.g. after entropy rotation
        # or to refresh the ACL) and preserves the username/password.

    .EXAMPLE
        $new = Get-Credential -UserName "SEBackup" -Message "New password for GameServer01"
        Update-SEBCredential -NodeName "GameServer01" -Credential $new
        # Replaces the stored secret with a new password.

    .OUTPUTS
        None. The credential is re-written to disk.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter(Position = 1)]
        [PSCredential]$Credential
    )

    # Resolve the credential to (re)store.
    if ($PSBoundParameters.ContainsKey('Credential')) {
        if ($null -eq $Credential) {
            throw "The -Credential argument for node '$NodeName' was null."
        }
        $target = $Credential
        $action = "Rotate credential for node '$NodeName' (replace stored secret)"
    }
    else {
        # Load the existing credential so we can re-encrypt it under the current
        # backend parameters. Get-SEBCredential throws a clear message if it is
        # absent or undecryptable on this host.
        try {
            $target = Get-SEBCredential -NodeName $NodeName
        }
        catch {
            throw "Cannot re-encrypt credential for node '$NodeName' because the existing credential could not be loaded: $_"
        }
        $action = "Rotate credential for node '$NodeName' (re-encrypt in place)"
    }

    if (-not $PSCmdlet.ShouldProcess($NodeName, $action)) {
        return
    }

    try {
        $saved = Write-SEBProtectedCredentialFile -NodeName $NodeName -Credential $target
        if (-not $saved) {
            throw "Credential protection or file write failed (see log for details)."
        }

        # Clean up any superseded legacy file so the protected file stays authoritative.
        $legacyFile = Resolve-CredentialPath -NodeName $NodeName -Legacy
        if (Test-Path -LiteralPath $legacyFile) {
            Remove-Item -LiteralPath $legacyFile -Force -ErrorAction SilentlyContinue
        }

        Write-Verbose "Credential rotated for node '$NodeName' (User: $($target.UserName))"
        Write-SEBLog -Level INFO -Context 'CredentialManager' -Message "Rotated credential for node '$NodeName' (user '$($target.UserName)') in the LocalMachine-DPAPI protected store." -NoConsole
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Failed to rotate credential for node '$NodeName': $_"
        throw "Failed to rotate credential for node '$NodeName': $_"
    }
}
