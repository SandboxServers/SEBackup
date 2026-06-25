function Start-SEBTorchServer {
    <#
    .SYNOPSIS
        Starts a Torch server on a remote node and waits for the VRage API to respond.

    .DESCRIPTION
        Starts the Space Engineers Torch server on the remote node. The start
        method depends on the instance's run_mode configuration:

        - "service": Uses Start-Service via Invoke-Command on the remote node.
        - "console": Warns that the server must be started manually.

        After starting, polls the VRage Remote API until it responds (indicating
        the server is fully loaded and ready) or the timeout is reached.

    .PARAMETER Session
        An active PSSession connected to the target compute node.

    .PARAMETER InstanceConfig
        The instance configuration hashtable containing run_mode, service_name,
        and VRage API settings.

    .PARAMETER NodeConfig
        The node configuration hashtable containing the hostname.

    .PARAMETER TimeoutSeconds
        Maximum time to wait for the server to start and respond via API.
        Defaults to 300 seconds (5 minutes) to allow for world loading.

    .EXAMPLE
        $result = Start-SEBTorchServer -Session $session -InstanceConfig $config -NodeConfig $nodeConfig
        if ($result.Started) {
            Write-Host "Server started and API responding."
        }

    .OUTPUTS
        PSCustomObject
        An object with: Started (bool), Method (string), APIResponding (bool),
        ErrorMessage (string).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [hashtable]$InstanceConfig,

        [Parameter(Mandatory)]
        [hashtable]$NodeConfig,

        [Parameter()]
        [ValidateRange(10, 1800)]
        [int]$TimeoutSeconds = 300
    )

    $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue
    $instanceName = $InstanceConfig['_InstanceName']
    $runMode = if ($InstanceConfig.ContainsKey('run_mode')) { $InstanceConfig['run_mode'] } else { 'service' }

    $serviceStarted = $false

    if ($runMode -eq 'service') {
        $serviceName = if ($InstanceConfig.ContainsKey('service_name')) {
            $InstanceConfig['service_name']
        }
        else {
            "TorchServer_$instanceName"
        }

        if ($hasLogger) {
            Write-SEBLog -Message "Starting Torch service '$serviceName' on node..." -Level INFO -Context $instanceName
        }

        try {
            # Route through the wrapper for retry/logging/reconnect; the block stays node-local.
            $startResult = Invoke-SEBRemoteCommand -Session $Session -ScriptBlock {
                param($svcName, $timeout)

                $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                if ($null -eq $svc) {
                    return @{ Started = $false; Error = "Service '$svcName' not found." }
                }

                if ($svc.Status -eq 'Running') {
                    return @{ Started = $true; Error = $null }
                }

                try {
                    Start-Service -Name $svcName -ErrorAction Stop
                    $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
                    return @{ Started = $true; Error = $null }
                }
                catch {
                    return @{ Started = $false; Error = $_.ToString() }
                }
            } -ArgumentList $serviceName, $TimeoutSeconds -ErrorAction Stop

            if ($startResult.Started) {
                $serviceStarted = $true
                if ($hasLogger) {
                    Write-SEBLog -Message "Torch service '$serviceName' started. Waiting for API to respond..." -Level INFO -Context $instanceName
                }
            }
            else {
                return [PSCustomObject]@{
                    Started       = $false
                    Method        = 'service'
                    APIResponding = $false
                    ErrorMessage  = "Failed to start service '$serviceName': $($startResult.Error)"
                }
            }
        }
        catch {
            return [PSCustomObject]@{
                Started       = $false
                Method        = 'service'
                APIResponding = $false
                ErrorMessage  = "Exception starting service '$serviceName': $_"
            }
        }
    }
    elseif ($runMode -eq 'console') {
        $warnMsg = "Console mode: server must be started manually. Waiting for API to respond..."
        if ($hasLogger) {
            Write-SEBLog -Message $warnMsg -Level WARN -Context $instanceName
        }
        Write-Warning $warnMsg
        $serviceStarted = $true  # Assume user will start it
    }
    else {
        return [PSCustomObject]@{
            Started       = $false
            Method        = 'unknown'
            APIResponding = $false
            ErrorMessage  = "Unknown run_mode: '$runMode'"
        }
    }

    # Wait for VRage API to respond
    $nodeHostname = if ($NodeConfig.ContainsKey('node') -and $NodeConfig['node'].ContainsKey('hostname')) {
        $NodeConfig['node']['hostname']
    }
    elseif ($NodeConfig.ContainsKey('hostname')) {
        $NodeConfig['hostname']
    }
    else {
        $Session.ComputerName
    }

    $vragePort = if ($InstanceConfig.ContainsKey('vrage_api') -and $InstanceConfig['vrage_api'].ContainsKey('port')) {
        $InstanceConfig['vrage_api']['port']
    }
    else { 8080 }

    $vrageKey = if ($InstanceConfig.ContainsKey('vrage_api') -and $InstanceConfig['vrage_api'].ContainsKey('security_key')) {
        $InstanceConfig['vrage_api']['security_key']
    }
    else { $null }

    $apiResponding = $false

    if (-not [string]::IsNullOrWhiteSpace($vrageKey)) {
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $pollInterval = 5

        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $pollInterval

            $ping = Test-SEBVRageAPI -Hostname $nodeHostname -Port $vragePort -SecurityKey $vrageKey
            if ($ping) {
                $apiResponding = $true
                if ($hasLogger) {
                    Write-SEBLog -Message "VRage API is responding on ${nodeHostname}:${vragePort}. Server is ready." -Level INFO -Context $instanceName
                }
                break
            }

            Write-Verbose "Waiting for VRage API to respond on ${nodeHostname}:${vragePort}..."
        }

        if (-not $apiResponding) {
            $warnMsg = "VRage API did not respond within ${TimeoutSeconds}s. Server may still be loading."
            if ($hasLogger) {
                Write-SEBLog -Message $warnMsg -Level WARN -Context $instanceName
            }
        }
    }
    else {
        if ($hasLogger) {
            Write-SEBLog -Message "No VRage API key configured. Cannot verify server readiness." -Level WARN -Context $instanceName
        }
    }

    return [PSCustomObject]@{
        Started       = $serviceStarted
        Method        = $runMode
        APIResponding = $apiResponding
        ErrorMessage  = if (-not $serviceStarted) { "Server did not start." } elseif (-not $apiResponding) { "Server started but API not responding within timeout." } else { $null }
    }
}
