function Test-SEBShare {
    <#
    .SYNOPSIS
        Tests whether an SMB share is accessible with the provided credentials.

    .DESCRIPTION
        Validates that the specified UNC share path can be reached and read
        using the provided PSCredential. This is done by temporarily mapping
        a PSDrive to the share and checking for access. The temporary drive
        is always cleaned up, regardless of success or failure.

        Returns $true if the share is accessible, $false otherwise. This
        function never throws.

    .PARAMETER SharePath
        The UNC path to the SMB share to test (e.g., \\GameServer01\TorchBackups).

    .PARAMETER Credential
        The PSCredential to use for authenticating to the share.

    .EXAMPLE
        $cred = Get-SEBCredential -NodeName "GameServer01"
        Test-SEBShare -SharePath "\\GameServer01\TorchBackups" -Credential $cred
        # Returns $true if the share is accessible.

    .EXAMPLE
        $sharePath = Get-SEBSharePath -NodeConfig $nodeConfig -InstanceConfig $instanceConfig
        if (-not (Test-SEBShare -SharePath $sharePath -Credential $cred)) {
            Write-Error "Cannot access backup share at $sharePath"
        }

    .OUTPUTS
        System.Boolean
        $true if the share is accessible; $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$SharePath,

        [Parameter(Mandatory, Position = 1)]
        [PSCredential]$Credential
    )

    $testDriveName = "SEBShareTest_$([guid]::NewGuid().ToString('N').Substring(0, 8))"

    try {
        New-PSDrive `
            -Name       $testDriveName `
            -PSProvider  FileSystem `
            -Root        $SharePath `
            -Credential  $Credential `
            -Scope       Local `
            -ErrorAction Stop | Out-Null

        # Verify we can actually list the share contents
        Get-ChildItem -Path "${testDriveName}:\" -ErrorAction Stop | Out-Null

        Write-Verbose "SMB share is accessible: $SharePath"
        return $true
    }
    catch {
        Write-Verbose "SMB share is not accessible: $SharePath -- $_"
        return $false
    }
    finally {
        Remove-PSDrive -Name $testDriveName -Force -ErrorAction SilentlyContinue
    }
}
