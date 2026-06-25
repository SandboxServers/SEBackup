function Remove-SEBCredential {
    <#
    .SYNOPSIS
        Removes the stored credential file(s) for a remote SEBackup node.

    .DESCRIPTION
        Deletes the credential for a node. It removes the new protected file
        (Credentials/{NodeName}.cred) and, if present, any leftover legacy
        Export-Clixml file (Credentials/{NodeName}.cred.xml), so a node is fully
        de-provisioned regardless of which format(s) exist on disk.

        This function supports the common -WhatIf and -Confirm risk-mitigation
        parameters via ShouldProcess. Running with -WhatIf reports what would be
        removed without deleting anything. Running with -Confirm (or when the
        configured ConfirmImpact would otherwise prompt) requests interactive
        confirmation before deletion. Use the -Force switch to bypass confirmation
        for automation. -WhatIf always wins over -Force.

        If no credential file exists in either format, a warning is written and no
        error is thrown.

    .PARAMETER NodeName
        The name of the remote node whose credential should be removed.

    .PARAMETER Force
        Removes the credential file(s) without prompting for confirmation.
        Intended for non-interactive/automated use.

    .EXAMPLE
        Remove-SEBCredential -NodeName "GameServer01"
        # Removes the credential file(s), prompting for confirmation if required.

    .EXAMPLE
        Remove-SEBCredential -NodeName "GameServer01" -WhatIf
        # Reports what would be removed without deleting anything.

    .EXAMPLE
        Remove-SEBCredential -NodeName "GameServer01" -Force
        # Removes the credential file(s) without prompting.

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
    $legacyFile = Resolve-CredentialPath -NodeName $NodeName -Legacy

    # -LiteralPath: these are resolved paths, not patterns -- avoid treating any [ or ]
    # in the resolved path as a wildcard during the existence checks.
    $targets = @($credentialFile, $legacyFile) | Where-Object { Test-Path -LiteralPath $_ }

    if ($targets.Count -eq 0) {
        # Mention BOTH the new-format and legacy paths: a node may have only ever had a
        # pre-#27 '.cred.xml', so surfacing just the '.cred' path hides where to look
        # when troubleshooting a migration or a manual cleanup.
        Write-Warning "No credential file found for node '$NodeName' (checked '$credentialFile' and legacy '$legacyFile')."
        return
    }

    # ShouldProcess is always consulted: -WhatIf returns $false (preview, no deletion),
    # -Confirm/ConfirmImpact prompt interactively unless suppressed (e.g. by -Force above).
    $targetDescription = $targets -join ', '
    if (-not $PSCmdlet.ShouldProcess($targetDescription, "Remove credential for node '$NodeName'")) {
        return
    }

    try {
        foreach ($target in $targets) {
            # ShouldProcess already handled confirmation above, so suppress any nested prompt.
            # -LiteralPath: resolved path, not a pattern -- avoid wildcard expansion if the
            # node name ever resolves to a path containing [ or ].
            Remove-Item -LiteralPath $target -Force -Confirm:$false -ErrorAction Stop
            Write-Verbose "Credential removed for node '$NodeName': $target"
        }
        Write-SEBLog -Level INFO -Context 'CredentialManager' -Message "Removed credential file(s) for node '$NodeName': $targetDescription" -NoConsole
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Failed to remove credential for node '$NodeName': $_"
        throw "Failed to remove credential for node '$NodeName': $_"
    }
}
