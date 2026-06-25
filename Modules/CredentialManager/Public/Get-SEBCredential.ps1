function Get-SEBCredential {
    <#
    .SYNOPSIS
        Retrieves a stored PSCredential for a remote SEBackup node.

    .DESCRIPTION
        Loads the credential for a node from the protected "*.cred" store
        introduced for issue #27, decrypting the password with LocalMachine-scope
        DPAPI (the same scope and per-machine entropy used to save it) and
        rebuilding a PSCredential. Because the protection is machine-bound rather
        than user-bound, this succeeds for any process on the SAME C&C host --
        including an unattended S4U scheduled task -- which is what makes
        unattended authentication work.

        Backward compatibility / migration: if no new "{NodeName}.cred" file
        exists but a legacy Export-Clixml "{NodeName}.cred.xml" does, this function
        transparently migrates it. If the legacy file is readable by the current
        user, it is re-saved in the new protected format (and the old file
        removed) and the credential is returned. If it is NOT readable (e.g. it
        was saved by a different user), a clear "re-save required" error is thrown
        and the legacy file is left untouched.

        Throws if no credential exists, or if the stored credential cannot be
        decrypted on this machine.

        NOTE -- migrate-on-read side effect: unlike a pure read, this function may
        MUTATE the store. When only a legacy ".cred.xml" exists, it re-saves the
        credential in the new protected format and deletes the legacy file (after a
        verified read-back), and resolving the path may create and harden the
        Credentials directory. The migration is serialized with a per-node
        cross-process mutex so concurrent callers do not collide. Callers that need
        a side-effect-free probe should use Test-SEBCredential instead.

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
        The PSCredential object for the specified node.
    #>
    [CmdletBinding()]
    [OutputType([PSCredential])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName
    )

    $credentialFile = Resolve-CredentialPath -NodeName $NodeName

    if (Test-Path -LiteralPath $credentialFile) {
        # New protected format.
        try {
            $raw = Get-Content -LiteralPath $credentialFile -Raw -ErrorAction Stop
            $envelope = $raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Failed to read/parse credential file '$credentialFile' for node '$NodeName': $_"
            throw "Failed to read credential for node '$NodeName' from '$credentialFile'. The file may be corrupted: $_"
        }

        # An empty/whitespace .cred (e.g. an externally truncated/touched file) yields
        # a $null envelope from ConvertFrom-Json WITHOUT throwing. Guard it explicitly
        # so we surface the friendly corruption message rather than a raw parameter
        # binding exception from ConvertFrom-SEBProtectedCredential's [ValidateNotNull].
        if ($null -eq $envelope) {
            Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Credential file '$credentialFile' for node '$NodeName' is empty or not valid JSON."
            throw "Failed to read credential for node '$NodeName' from '$credentialFile'. The file may be corrupted (empty or invalid)."
        }

        $credential = ConvertFrom-SEBProtectedCredential -Envelope $envelope
        if ($null -eq $credential) {
            throw "Failed to decrypt credential for node '$NodeName' from '$credentialFile'. " +
                  "It may have been created on a different machine or under a rotated key/entropy version. " +
                  "Re-save it on THIS host with Save-SEBCredential -NodeName '$NodeName'."
        }

        Write-Verbose "Credential loaded for node '$NodeName' (User: $($credential.UserName))"
        return $credential
    }

    # No new-format file. Attempt transparent migration from a legacy Clixml file.
    $legacyFile = Resolve-CredentialPath -NodeName $NodeName -Legacy
    if (Test-Path -LiteralPath $legacyFile) {
        $migration = Convert-SEBLegacyCredential -NodeName $NodeName -SaveAction {
            param([PSCredential]$cred)
            Write-SEBProtectedCredentialFile -NodeName $NodeName -Credential $cred
        }

        if ($migration.Status -eq 'Migrated' -and $migration.Credential) {
            Write-Verbose "Credential for node '$NodeName' migrated from legacy format and loaded (User: $($migration.Credential.UserName))"
            return $migration.Credential
        }

        # Legacy file exists but was not readable/migratable by this account.
        throw "A legacy credential file exists for node '$NodeName' but could not be read by the current account " +
              "(it was likely saved by a different user). Re-save it on THIS host with " +
              "Save-SEBCredential -NodeName '$NodeName' so it is stored in the machine-readable protected format."
    }

    throw "No credential found for node '$NodeName'. Expected file: $credentialFile`n" +
          "Run Setup-Node.ps1 or Save-SEBCredential -NodeName '$NodeName' to store credentials first."
}
