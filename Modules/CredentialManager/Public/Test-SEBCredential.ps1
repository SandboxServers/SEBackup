function Test-SEBCredential {
    <#
    .SYNOPSIS
        Tests whether a stored credential exists and is readable for a remote
        SEBackup node.

    .DESCRIPTION
        Returns $true ONLY if a credential for the node is usable for the
        unattended scenario this store exists to support -- i.e. it is present in
        the new protected "*.cred" format AND decrypts under LocalMachine DPAPI on
        THIS machine (the property an S4U "run whether logged on or not" task
        relies on). Anything else returns $false.

        Crucially, a node that has ONLY a legacy Export-Clixml "*.cred.xml" file
        returns $false -- even when that file is readable by the current
        interactive user. The legacy blob is sealed with CurrentUser-scope DPAPI,
        which does NOT decrypt under an S4U task with no loaded profile, so a green
        result here would be a false readiness signal: the preflight would pass and
        the unattended backup would then fail. Returning $false correctly reports
        "re-save required" -- run Save-SEBCredential (or just call Get-SEBCredential
        once interactively, which migrates it) to convert the node to the
        machine-readable protected format. (Test deliberately does NOT migrate; it
        is side-effect-free, unlike Get-SEBCredential.)

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
        # Returns the names of nodes that do NOT have a usable protected credential
        # (missing, undecryptable, or legacy-only and needing a re-save).

    .OUTPUTS
        System.Boolean
        $true ONLY if a protected, machine-decryptable credential exists for this
        node on this host; $false if it is missing, undecryptable, or present only
        in the legacy CurrentUser format (which an unattended task cannot read).
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
            # Treat an empty/corrupt envelope identically to Get-SEBCredential: a
            # $null envelope is not usable. (Guard before ConvertFrom's ValidateNotNull.)
            if ($null -eq $envelope) {
                Write-Verbose "Credential file for node '$NodeName' is empty or not valid JSON."
                return $false
            }
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

    # A legacy-only credential is NOT usable for the unattended (S4U) scenario this
    # API exists to gate: the CurrentUser-DPAPI legacy blob does not decrypt under a
    # task with no loaded profile, even if it is readable interactively right now.
    # Report $false ("re-save required") rather than a false-green readiness signal.
    $legacyFile = Resolve-CredentialPath -NodeName $NodeName -Legacy
    if (Test-Path -LiteralPath $legacyFile) {
        Write-Verbose "Only a legacy '.cred.xml' exists for node '$NodeName'; it is not in the machine-readable protected format and is NOT usable unattended. Re-save with Save-SEBCredential -NodeName '$NodeName' (or call Get-SEBCredential once to migrate)."
        return $false
    }

    Write-Verbose "No credential file found for node '$NodeName'."
    return $false
}
