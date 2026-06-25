function Save-SEBVRageWorld {
    <#
    .SYNOPSIS
        Triggers a world save on a Space Engineers Torch server via the VRage API.

    .DESCRIPTION
        Orchestrates a full world save operation through the VRage Remote API.
        The save process follows these steps:

        1. Pings the server to verify API connectivity.
        2. Sends a PATCH request to /session/save to trigger the save. The VRage
           Remote API PATCH /session/save is synchronous -- it returns only after
           the world has been written to disk -- so a successful (non-null)
           response is the authoritative completion signal. (A prior version
           polled GET /session for an 'IsSaving' field that endpoint never
           returns, so the poll verified nothing.)

        This function never throws a terminating error. If the API is
        unreachable or the save fails, it returns an object with Success=$false
        and an appropriate ErrorMessage. The caller decides how to handle the
        failure (e.g., proceeding with a backup anyway or aborting).

    .PARAMETER Hostname
        The hostname or IP address of the Torch server running the VRage
        Remote API.

    .PARAMETER Port
        The TCP port number on which the VRage Remote API is listening.

    .PARAMETER SecurityKey
        The security key configured in the Torch server for VRage Remote API
        authentication.

    .PARAMETER TimeoutSeconds
        The HTTP timeout, in seconds, applied to the synchronous PATCH
        /session/save request. A large world can take well over the default
        30s request timeout to flush, so this is plumbed through as the request
        timeout to avoid cutting off a save that is still in progress. Defaults
        to 120 seconds.

    .EXAMPLE
        $result = Save-SEBVRageWorld -Hostname 'localhost' -Port 8080 -SecurityKey 'MyKey123'
        if ($result.Success) {
            Write-Host "World saved in $($result.Duration.TotalSeconds) seconds"
        } else {
            Write-Warning "Save failed: $($result.ErrorMessage)"
        }

    .EXAMPLE
        Save-SEBVRageWorld -Hostname '192.168.1.10' -Port 8080 -SecurityKey 'Key12345' -TimeoutSeconds 300
        # Allows up to 5 minutes for large world saves

    .OUTPUTS
        PSCustomObject
        An object with the following properties:
        - Success      [bool]   : Whether the save completed successfully.
        - Duration     [TimeSpan] : How long the save operation took (null if failed).
        - ErrorMessage [string] : Description of the failure (null if successful).
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
        [string]$SecurityKey,

        [Parameter()]
        [ValidateRange(10, 3600)]
        [int]$TimeoutSeconds = 120
    )

    $startTime = Get-Date

    $commonParams = @{
        Hostname    = $Hostname
        Port        = $Port
        SecurityKey = $SecurityKey
    }

    # Step 1: Ping the server to verify connectivity
    Write-Verbose "VRageAPI: Pinging server at ${Hostname}:${Port}"
    $ping = Invoke-SEBVRageRequest @commonParams -Endpoint 'server/ping'

    if ($null -eq $ping) {
        return [PSCustomObject]@{
            Success      = $false
            Duration     = $null
            ErrorMessage = "Server at ${Hostname}:${Port} is unreachable. Ping failed."
        }
    }

    # Step 2: Trigger the save via PATCH. The PATCH is synchronous, so apply TimeoutSeconds as the
    # request timeout -- a large world can take longer than the default 30s to flush to disk.
    Write-Verbose "VRageAPI: Triggering world save on ${Hostname}:${Port} (timeout ${TimeoutSeconds}s)"
    $saveResponse = Invoke-SEBVRageRequest @commonParams -Method PATCH -Endpoint 'session/save' -TimeoutSec $TimeoutSeconds

    if ($null -eq $saveResponse) {
        return [PSCustomObject]@{
            Success      = $false
            Duration     = $null
            ErrorMessage = "Failed to trigger save on ${Hostname}:${Port}. PATCH /session/save returned no response."
        }
    }

    # The VRage Remote API PATCH /session/save is synchronous: it returns only after the
    # world has been written to disk. A successful (non-null) response is therefore the
    # authoritative completion signal. The previous code polled GET /session for an 'IsSaving'
    # property that endpoint does not return, so the poll always saw "not saving" on the first
    # iteration and reported success after one sleep regardless of the real state -- a poll
    # that verified nothing. Treat the PATCH result as definitive.
    $duration = (Get-Date) - $startTime
    Write-Verbose "VRageAPI: Save acknowledged by ${Hostname}:${Port} in $($duration.TotalSeconds)s"
    return [PSCustomObject]@{
        Success      = $true
        Duration     = $duration
        ErrorMessage = $null
    }
}
