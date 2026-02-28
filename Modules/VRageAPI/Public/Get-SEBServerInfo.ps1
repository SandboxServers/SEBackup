function Get-SEBServerInfo {
    <#
    .SYNOPSIS
        Retrieves server information from a Space Engineers Torch server.

    .DESCRIPTION
        Queries the VRage Remote API's /server endpoint to retrieve current
        server status information including the server name, world name,
        player count, version, and other metadata.

        If the server is unreachable or the request fails, returns $null
        rather than throwing an error. The caller can check for $null to
        determine if the query succeeded.

    .PARAMETER Hostname
        The hostname or IP address of the Torch server running the VRage
        Remote API.

    .PARAMETER Port
        The TCP port number on which the VRage Remote API is listening.

    .PARAMETER SecurityKey
        The security key configured in the Torch server for VRage Remote API
        authentication.

    .EXAMPLE
        $info = Get-SEBServerInfo -Hostname 'localhost' -Port 8080 -SecurityKey 'MyKey123'
        if ($info) {
            Write-Host "Server: $($info.ServerName) | Players: $($info.Players)/$($info.MaxPlayers)"
        }

    .EXAMPLE
        $info = Get-SEBServerInfo -Hostname '192.168.1.10' -Port 8080 -SecurityKey 'Key12345'
        if ($null -eq $info) {
            Write-Warning "Could not retrieve server info"
        }

    .OUTPUTS
        PSCustomObject
        An object containing server information properties such as ServerName,
        WorldName, Players, MaxPlayers, Version, SimulationSpeed, and
        ServerUptime. Returns $null if the server is unreachable.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
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

    Write-Verbose "VRageAPI: Querying server info from ${Hostname}:${Port}"

    $response = Invoke-SEBVRageRequest -Hostname $Hostname -Port $Port -SecurityKey $SecurityKey -Endpoint 'server'

    if ($null -eq $response) {
        Write-Verbose "VRageAPI: Failed to retrieve server info from ${Hostname}:${Port}"
        return $null
    }

    # The VRage API may wrap the response in a 'data' property
    $data = if ($response.PSObject.Properties.Name -contains 'data') {
        $response.data
    }
    else {
        $response
    }

    # Build a normalized output object from the API response
    $serverInfo = [PSCustomObject]@{
        ServerName      = $data.ServerName
        WorldName       = $data.WorldName
        Players         = $data.Players
        MaxPlayers      = $data.MaxPlayers
        Version         = $data.Version
        SimulationSpeed = $data.SimulationSpeed
        ServerUptime    = $data.ServerUptime
        IsReady         = $data.IsReady
        ServerId        = $data.ServerId
        GameMode        = $data.GameMode
        RawResponse     = $response
    }

    Write-Verbose "VRageAPI: Server '$($serverInfo.ServerName)' - $($serverInfo.Players)/$($serverInfo.MaxPlayers) players"
    return $serverInfo
}
