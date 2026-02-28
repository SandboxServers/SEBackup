function Save-SEBVRageWorld {
    <#
    .SYNOPSIS
        Triggers a world save on a Space Engineers Torch server via the VRage API.

    .DESCRIPTION
        Orchestrates a full world save operation through the VRage Remote API.
        The save process follows these steps:

        1. Pings the server to verify API connectivity.
        2. Sends a PATCH request to /session/save to trigger the save.
        3. Polls the /session endpoint until the save completes or the timeout
           is reached.

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
        The maximum number of seconds to wait for the save operation to
        complete. Defaults to 120 seconds.

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

    # Step 2: Trigger the save via PATCH
    Write-Verbose "VRageAPI: Triggering world save on ${Hostname}:${Port}"
    $saveResponse = Invoke-SEBVRageRequest @commonParams -Method PATCH -Endpoint 'session/save'

    if ($null -eq $saveResponse) {
        return [PSCustomObject]@{
            Success      = $false
            Duration     = $null
            ErrorMessage = "Failed to trigger save on ${Hostname}:${Port}. PATCH /session/save returned no response."
        }
    }

    # Step 3: Poll until save completes or timeout
    Write-Verbose "VRageAPI: Polling save status on ${Hostname}:${Port} (timeout: ${TimeoutSeconds}s)"
    $deadline = $startTime.AddSeconds($TimeoutSeconds)
    $pollInterval = 2  # seconds between polls

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $pollInterval

        $session = Invoke-SEBVRageRequest @commonParams -Endpoint 'session'

        if ($null -eq $session) {
            return [PSCustomObject]@{
                Success      = $false
                Duration     = (Get-Date) - $startTime
                ErrorMessage = "Lost connection to ${Hostname}:${Port} while waiting for save to complete."
            }
        }

        # Check if the save has completed - the session response indicates
        # save status via the IsReady property (true when not currently saving)
        $isSaving = $false
        if ($session.PSObject.Properties.Name -contains 'IsSaving') {
            $isSaving = $session.IsSaving
        }
        elseif ($session.data -and $session.data.PSObject.Properties.Name -contains 'IsSaving') {
            $isSaving = $session.data.IsSaving
        }

        if (-not $isSaving) {
            $duration = (Get-Date) - $startTime
            Write-Verbose "VRageAPI: Save completed on ${Hostname}:${Port} in $($duration.TotalSeconds)s"
            return [PSCustomObject]@{
                Success      = $true
                Duration     = $duration
                ErrorMessage = $null
            }
        }

        Write-Verbose "VRageAPI: Save still in progress on ${Hostname}:${Port}..."
    }

    # Timeout reached
    return [PSCustomObject]@{
        Success      = $false
        Duration     = (Get-Date) - $startTime
        ErrorMessage = "Save operation timed out after ${TimeoutSeconds} seconds on ${Hostname}:${Port}."
    }
}
