function Test-SEBCredential {
    <#
    .SYNOPSIS
        Tests whether a stored credential exists and is readable for a remote
        SEBackup node.

    .DESCRIPTION
        Returns $true if a credential for the node can be successfully loaded as a
        PSCredential on THIS machine, $false otherwise. It first checks the new
        protected "*.cred" store (decrypting via LocalMachine DPAPI to confirm the
        blob is actually usable here, not merely present); if that file is absent
        it falls back to checking whether a legacy Export-Clixml "*.cred.xml" file
        is present and readable by the current user.

        A legacy file that exists but cannot be decrypted by the current account
        returns $false -- it is effectively unusable until re-saved -- so callers
        treating $false as "needs setup/re-save" behave correctly.

        This function never throws and writes nothing to the error stream; it is
        designed for conditional logic and validation checks. It does NOT mutate
        the store (no migration side effects), unlike Get-SEBCredential.

    .PARAMETER NodeName
        The name of the remote node whose credential should be tested.

    .EXAMPLE
        if (Test-SEBCredential -NodeName "GameServer01") {
            Write-Host "Credentials are available for GameServer01"
        }

    .EXAMPLE
        $nodes = @("Server01", "Server02", "Server03")
        $nodes | Where-Object { -not (Test-SEBCredential -NodeName $_) }
        # Returns the names of nodes that do NOT have usable stored credentials.

    .OUTPUTS
        System.Boolean
        $true if a usable credential exists for this machine; $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName
    )

    $credentialFile = Resolve-CredentialPath -NodeName $NodeName

    if (Test-Path -LiteralPath $credentialFile) {
        try {
            $raw = Get-Content -LiteralPath $credentialFile -Raw -ErrorAction Stop
            $envelope = $raw | ConvertFrom-Json -ErrorAction Stop
            $credential = ConvertFrom-SEBProtectedCredential -Envelope $envelope
            if ($credential -is [PSCredential]) {
                Write-Verbose "Credential for node '$NodeName' is valid (User: $($credential.UserName))"
                return $true
            }
            Write-Verbose "Credential file for node '$NodeName' could not be decrypted on this machine."
            return $false
        }
        catch {
            Write-Verbose "Failed to read protected credential for node '$NodeName': $_"
            return $false
        }
    }

    # Fall back to a legacy Clixml file: present AND readable by the current user.
    $legacyFile = Resolve-CredentialPath -NodeName $NodeName -Legacy
    if (Test-Path -LiteralPath $legacyFile) {
        try {
            $legacy = Import-Clixml -LiteralPath $legacyFile -ErrorAction Stop
            if ($legacy -is [PSCredential]) {
                Write-Verbose "Legacy credential for node '$NodeName' is present and readable (User: $($legacy.UserName)). Re-save recommended to migrate to the protected format."
                return $true
            }
            return $false
        }
        catch {
            Write-Verbose "Legacy credential for node '$NodeName' exists but is not readable by the current account: $_"
            return $false
        }
    }

    Write-Verbose "No credential file found for node '$NodeName'."
    return $false
}
