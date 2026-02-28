function Test-SEBVRageAPI {
    <#
    .SYNOPSIS
        Tests connectivity to the VRage Remote API on a Torch server.

    .DESCRIPTION
        Sends a simple ping request to the VRage Remote API to verify that the
        server is reachable and the security key is valid. Returns $true if the
        ping succeeds, $false otherwise.

        This is a lightweight connectivity check suitable for use in health
        checks, pre-backup validation, or interactive diagnostics.

    .PARAMETER Hostname
        The hostname or IP address of the Torch server running the VRage
        Remote API.

    .PARAMETER Port
        The TCP port number on which the VRage Remote API is listening.

    .PARAMETER SecurityKey
        The security key configured in the Torch server for VRage Remote API
        authentication.

    .EXAMPLE
        if (Test-SEBVRageAPI -Hostname 'localhost' -Port 8080 -SecurityKey 'MyKey123') {
            Write-Host "VRage API is accessible"
        } else {
            Write-Warning "VRage API is not accessible"
        }

    .EXAMPLE
        Test-SEBVRageAPI -Hostname '192.168.1.10' -Port 8080 -SecurityKey 'Key12345' -Verbose
        # Returns $true or $false with verbose diagnostic output

    .OUTPUTS
        System.Boolean
        $true if the API responded to the ping request, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Hostname,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SecurityKey
    )

    Write-Verbose "VRageAPI: Testing connectivity to ${Hostname}:${Port}"

    $response = Invoke-SEBVRageRequest -Hostname $Hostname -Port $Port -SecurityKey $SecurityKey -Endpoint 'server/ping'

    if ($null -ne $response) {
        Write-Verbose "VRageAPI: Connectivity test succeeded for ${Hostname}:${Port}"
        return $true
    }

    Write-Verbose "VRageAPI: Connectivity test failed for ${Hostname}:${Port}"
    return $false
}
