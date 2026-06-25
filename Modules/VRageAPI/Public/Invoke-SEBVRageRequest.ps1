function Invoke-SEBVRageRequest {
    <#
    .SYNOPSIS
        Sends an authenticated request to the VRage Remote API.

    .DESCRIPTION
        Core request function for communicating with the Space Engineers Torch
        server via the VRage Remote API. Implements HMAC-SHA1 authentication
        using a random nonce and the configured security key.

        The function constructs the full API URL, generates authentication
        headers via the internal New-SEBVRageAuthHeaders helper, and sends
        the HTTP request using Invoke-RestMethod. If a Body is provided,
        it is serialized to JSON automatically.

        Connection errors and timeouts are handled gracefully -- the function
        writes a warning and returns $null rather than throwing a terminating
        error, allowing callers to decide how to handle unreachable servers.

    .PARAMETER Hostname
        The hostname or IP address of the Torch server running the VRage
        Remote API.

    .PARAMETER Port
        The TCP port number on which the VRage Remote API is listening.

    .PARAMETER SecurityKey
        The security key configured in the Torch server for VRage Remote API
        authentication.

    .PARAMETER Method
        The HTTP method to use for the request. Defaults to 'GET'. Common
        values are GET, POST, PATCH, DELETE.

    .PARAMETER Endpoint
        The API endpoint path, relative to the VRage Remote API base URL.
        For example: 'server', 'server/ping', 'session/save'.

    .PARAMETER Body
        An optional object to send as the request body. Will be serialized
        to JSON via ConvertTo-Json. Typically used with PATCH or POST methods.

    .PARAMETER TimeoutSec
        The per-request HTTP timeout in seconds. Defaults to 30. Callers that
        issue potentially long-running requests (e.g. a synchronous world save)
        should raise this so the request is not cut off prematurely.

    .EXAMPLE
        Invoke-SEBVRageRequest -Hostname 'localhost' -Port 8080 -SecurityKey 'MyKey123' -Endpoint 'server/ping'
        # Sends a GET request to http://localhost:8080/vrageremote/v1/server/ping

    .EXAMPLE
        Invoke-SEBVRageRequest -Hostname '192.168.1.10' -Port 8080 -SecurityKey 'MyKey123' -Method PATCH -Endpoint 'session/save'
        # Triggers a world save via PATCH request

    .EXAMPLE
        $body = @{ SomeProperty = 'value' }
        Invoke-SEBVRageRequest -Hostname 'server1' -Port 8080 -SecurityKey 'Key12345' -Method POST -Endpoint 'session' -Body $body
        # Sends a POST request with a JSON body

    .OUTPUTS
        System.Object
        The deserialized response from the VRage Remote API, or $null if the
        request failed due to a connection error or timeout.
    #>
    [CmdletBinding()]
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
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [Parameter()]
        [object]$Body,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = 30
    )

    # Build the full API URL and the absolute path that the signature is bound to.
    $requestPath = "/vrageremote/v1/${Endpoint}"
    $url = "http://${Hostname}:${Port}${requestPath}"

    # Generate HMAC-SHA1 authentication headers (signature is bound to the request path).
    $authHeaders = New-SEBVRageAuthHeaders -SecurityKey $SecurityKey -RequestUri $requestPath

    $headers = @{
        'Date'          = $authHeaders.Date
        'Authorization' = $authHeaders.Authorization
    }

    # Build the request parameters
    $requestParams = @{
        Uri             = $url
        Method          = $Method
        Headers         = $headers
        ContentType     = 'application/json'
        TimeoutSec      = $TimeoutSec
        ErrorAction     = 'Stop'
    }

    # Add body if provided
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        if ($Body -is [string]) {
            $requestParams.Body = $Body
        }
        else {
            $requestParams.Body = $Body | ConvertTo-Json -Depth 10
        }
    }

    try {
        Write-Verbose "VRageAPI: $Method $url"
        $response = Invoke-RestMethod @requestParams
        return $response
    }
    catch [System.Net.Http.HttpRequestException] {
        Write-Warning "VRageAPI: Connection error reaching ${Hostname}:${Port} - $($_.Exception.Message)"
        return $null
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        Write-Warning "VRageAPI: Request timed out for ${Hostname}:${Port}/${Endpoint}"
        return $null
    }
    catch {
        Write-Warning "VRageAPI: Request failed for ${Hostname}:${Port}/${Endpoint} - $($_.Exception.Message)"
        return $null
    }
}
