function Remove-SEBCredential {
    <#
    .SYNOPSIS
        Removes a stored credential file for a remote SEBackup node.

    .DESCRIPTION
        Deletes the DPAPI-encrypted credential file at
        Credentials/{NodeName}.cred.xml.

        This function supports the common -WhatIf and -Confirm risk-mitigation
        parameters via ShouldProcess. Running with -WhatIf reports what would be
        removed without deleting anything. Running with -Confirm (or when the
        configured ConfirmImpact would otherwise prompt) requests interactive
        confirmation before deletion. Use the -Force switch to bypass
        confirmation for automation.

        If the credential file does not exist, a warning is written and no
        error is thrown.

    .PARAMETER NodeName
        The name of the remote node whose credential should be removed.

    .PARAMETER Force
        Removes the credential file without prompting for confirmation. This is
        intended for non-interactive/automated use.

    .EXAMPLE
        Remove-SEBCredential -NodeName "GameServer01"
        # Removes the credential file, prompting for confirmation if required.

    .EXAMPLE
        Remove-SEBCredential -NodeName "GameServer01" -WhatIf
        # Reports what would be removed without deleting the file.

    .EXAMPLE
        Remove-SEBCredential -NodeName "GameServer01" -Force
        # Removes the credential file without prompting.

    .EXAMPLE
        @("Server01", "Server02") | ForEach-Object { Remove-SEBCredential -NodeName $_ -Force }
        # Removes credentials for multiple nodes.

    .OUTPUTS
        None.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter()]
        [switch]$Force
    )

    # -Force suppresses the interactive confirmation prompt for automation by lowering
    # $ConfirmPreference in this scope. ShouldProcess is STILL consulted below, so -WhatIf
    # always wins (it returns $false and prevents deletion even when -Force is supplied).
    # An explicit -Confirm still overrides -Force, so honor it when the caller passed it.
    if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    $credentialFile = Resolve-CredentialPath -NodeName $NodeName

    # -LiteralPath: $credentialFile is a resolved path, not a pattern -- avoid treating
    # any [ or ] in the resolved path as a wildcard during the existence check.
    if (-not (Test-Path -LiteralPath $credentialFile)) {
        Write-Warning "No credential file found for node '$NodeName' at: $credentialFile"
        return
    }

    # ShouldProcess is always consulted: -WhatIf returns $false (preview, no deletion),
    # -Confirm/ConfirmImpact prompt interactively unless suppressed (e.g. by -Force above).
    if (-not $PSCmdlet.ShouldProcess($credentialFile, "Remove credential for node '$NodeName'")) {
        return
    }

    try {
        # ShouldProcess already handled confirmation above, so suppress any nested prompt.
        # -LiteralPath: $credentialFile is a resolved path, not a pattern -- avoid wildcard
        # expansion if the node name ever resolves to a path containing [ or ].
        Remove-Item -LiteralPath $credentialFile -Force -Confirm:$false -ErrorAction Stop
        Write-Verbose "Credential removed for node '$NodeName': $credentialFile"
    }
    catch {
        throw "Failed to remove credential for node '$NodeName': $_"
    }
}
