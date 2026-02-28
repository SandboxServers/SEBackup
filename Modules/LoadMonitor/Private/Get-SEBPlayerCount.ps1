function Get-SEBPlayerCount {
    <#
    .SYNOPSIS
        Retrieves the current player count from the VRage Remote API.

    .DESCRIPTION
        Queries the VRage Remote API's server endpoint to obtain the current
        number of players connected to the Space Engineers Torch server instance.

        This function is fail-open for load checking: if the API is unreachable,
        misconfigured, or returns an unexpected response, the function returns 0
        rather than throwing an error. This ensures that a VRage API outage does
        not prevent backups from proceeding.

        The VRage API connection parameters are extracted from the instance
        configuration hashtable's vrage_api section.

    .PARAMETER InstanceConfig
        A hashtable containing the instance configuration. Expected to have a
        vrage_api section with keys: hostname, port, security_key.

    .EXAMPLE
        $config = @{
            vrage_api = @{
                hostname     = 'localhost'
                port         = 8080
                security_key = 'MyKey123'
            }
        }
        $players = Get-SEBPlayerCount -InstanceConfig $config
        Write-Host "Currently $players player(s) online."

    .OUTPUTS
        System.Int32
        The number of players currently connected, or 0 if the API is unreachable.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$InstanceConfig
    )

    # Extract VRage API settings from instance config
    $vrageConfig = $InstanceConfig['vrage_api']
    if (-not $vrageConfig) {
        Write-Verbose "LoadMonitor: No vrage_api configuration found in instance config. Returning 0 players."
        return 0
    }

    $hostname    = $vrageConfig['hostname']
    $port        = $vrageConfig['port']
    $securityKey = $vrageConfig['security_key']

    if (-not $hostname -or -not $port -or -not $securityKey) {
        Write-Verbose "LoadMonitor: Incomplete vrage_api configuration (hostname=$hostname, port=$port). Returning 0 players."
        return 0
    }

    try {
        # Use Get-SEBServerInfo if available, otherwise fall back to Invoke-SEBVRageRequest
        if (Get-Command -Name 'Get-SEBServerInfo' -ErrorAction SilentlyContinue) {
            $serverInfo = Get-SEBServerInfo -Hostname $hostname -Port $port -SecurityKey $securityKey

            if ($null -ne $serverInfo) {
                # The VRage API server endpoint typically returns Players as a count
                $playerCount = if ($null -ne $serverInfo.Players) {
                    [int]$serverInfo.Players
                }
                elseif ($null -ne $serverInfo.PlayerCount) {
                    [int]$serverInfo.PlayerCount
                }
                elseif ($null -ne $serverInfo.Data -and $null -ne $serverInfo.Data.Players) {
                    [int]$serverInfo.Data.Players
                }
                else {
                    0
                }

                Write-Verbose "LoadMonitor: VRage API reports $playerCount player(s) online."
                return $playerCount
            }
        }
        else {
            # Fallback: direct API request to the server endpoint
            $response = Invoke-SEBVRageRequest -Hostname $hostname -Port $port -SecurityKey $securityKey -Endpoint 'server'

            if ($null -ne $response) {
                $playerCount = if ($null -ne $response.Players) {
                    [int]$response.Players
                }
                elseif ($null -ne $response.Data -and $null -ne $response.Data.Players) {
                    [int]$response.Data.Players
                }
                else {
                    0
                }

                Write-Verbose "LoadMonitor: VRage API reports $playerCount player(s) online."
                return $playerCount
            }
        }

        Write-Verbose "LoadMonitor: VRage API returned no data. Returning 0 players (fail-open)."
        return 0
    }
    catch {
        Write-Verbose "LoadMonitor: Failed to query VRage API for player count: $_. Returning 0 (fail-open)."
        return 0
    }
}
