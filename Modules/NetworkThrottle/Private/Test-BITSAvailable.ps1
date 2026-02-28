function Test-BITSAvailable {
    <#
    .SYNOPSIS
        Checks whether the BITS (Background Intelligent Transfer Service) is available and running.

    .DESCRIPTION
        Internal helper function that verifies the BITS service is installed and in a running
        state on the local machine. This is used by Copy-SEBThrottled and Start-SEBBitsTransfer
        to determine whether BITS-based transfers can be used.

        The function checks:
        1. That the BitsTransfer PowerShell module is available.
        2. That the BITS Windows service exists and is in 'Running' status.

    .EXAMPLE
        if (Test-BITSAvailable) { "BITS is ready" }

    .OUTPUTS
        System.Boolean
        $true if BITS is available and running; $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        # Check if the BitsTransfer module is available
        $module = Get-Module -ListAvailable -Name BitsTransfer -ErrorAction SilentlyContinue
        if (-not $module) {
            Write-Verbose "BitsTransfer PowerShell module is not available."
            return $false
        }

        # Check if the BITS service is running
        $service = Get-Service -Name BITS -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Verbose "BITS service is not installed on this system."
            return $false
        }

        if ($service.Status -ne 'Running') {
            Write-Verbose "BITS service exists but is not running (Status: $($service.Status))."
            return $false
        }

        return $true
    }
    catch {
        Write-Verbose "Error checking BITS availability: $_"
        return $false
    }
}
