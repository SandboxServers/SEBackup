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

    $credentialFile = Resolve-CredentialPath -NodeName $NodeName

    if (-not (Test-Path -Path $credentialFile)) {
        Write-Warning "No credential file found for node '$NodeName' at: $credentialFile"
        return
    }

    # -Force bypasses confirmation for automation; otherwise ShouldProcess handles
    # -WhatIf (preview, no deletion) and -Confirm (interactive prompt) natively.
    if (-not ($Force -or $PSCmdlet.ShouldProcess($credentialFile, "Remove credential for node '$NodeName'"))) {
        return
    }

    try {
        # ShouldProcess already handled confirmation above, so suppress any nested prompt.
        Remove-Item -Path $credentialFile -Force -Confirm:$false -ErrorAction Stop
        Write-Verbose "Credential removed for node '$NodeName': $credentialFile"
    }
    catch {
        throw "Failed to remove credential for node '$NodeName': $_"
    }
}
