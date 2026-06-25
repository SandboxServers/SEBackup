function Stop-SEBTorchServer {
    <#
    .SYNOPSIS
        Stops a Torch server on a remote node based on the configured run mode.

    .DESCRIPTION
        Handles stopping the Space Engineers Torch server on the remote node. The
        stop method depends on the instance's run_mode configuration:

        - "service": Uses Stop-Service via Invoke-Command on the remote node.
          Waits up to TimeoutSeconds for the service to stop.
        - "console": Attempts a graceful shutdown via the VRage Remote API. If the
          API is not available, warns the user that manual intervention may be
          required. Does not force-kill the process.

    .PARAMETER Session
        An active PSSession connected to the target compute node.

    .PARAMETER InstanceConfig
        The instance configuration hashtable containing run_mode, service_name,
        and VRage API settings.

    .PARAMETER NodeConfig
        The node configuration hashtable containing the hostname.

    .PARAMETER TimeoutSeconds
        Maximum time to wait for the server to stop. Defaults to 120 seconds.

    .EXAMPLE
        $result = Stop-SEBTorchServer -Session $session -InstanceConfig $config -NodeConfig $nodeConfig
        if ($result.Stopped) {
            Write-Host "Server stopped via $($result.Method)"
        }

    .OUTPUTS
        PSCustomObject
        An object with: Stopped (bool), Method (string), ErrorMessage (string).
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
        [ValidateRange(10, 600)]
        [int]$TimeoutSeconds = 120
    )

    $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue
    $instanceName = $InstanceConfig['_InstanceName']
    $runMode = if ($InstanceConfig.ContainsKey('run_mode')) { $InstanceConfig['run_mode'] } else { 'service' }

    if ($runMode -eq 'service') {
        $serviceName = if ($InstanceConfig.ContainsKey('service_name')) {
            $InstanceConfig['service_name']
        }
        else {
            "TorchServer_$instanceName"
        }

        if ($hasLogger) {
            Write-SEBLog -Message "Stopping Torch service '$serviceName' on node..." -Level INFO -Context $instanceName
        }

        try {
            $stopResult = Invoke-Command -Session $Session -ScriptBlock {
                param($svcName, $timeout)

                $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                if ($null -eq $svc) {
                    return @{ Stopped = $false; Error = "Service '$svcName' not found." }
                }

                if ($svc.Status -eq 'Stopped') {
                    return @{ Stopped = $true; Error = $null }
                }

                try {
                    Stop-Service -Name $svcName -Force -ErrorAction Stop
                    $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($timeout))
                    return @{ Stopped = $true; Error = $null }
                }
                catch {
                    return @{ Stopped = $false; Error = $_.ToString() }
                }
            } -ArgumentList $serviceName, $TimeoutSeconds -ErrorAction Stop

            if ($stopResult.Stopped) {
                if ($hasLogger) {
                    Write-SEBLog -Message "Torch service '$serviceName' stopped successfully." -Level INFO -Context $instanceName
                }
                return [PSCustomObject]@{
                    Stopped      = $true
                    Method       = 'service'
                    ErrorMessage = $null
                }
            }
            else {
                return [PSCustomObject]@{
                    Stopped      = $false
                    Method       = 'service'
                    ErrorMessage = "Failed to stop service '$serviceName': $($stopResult.Error)"
                }
            }
        }
        catch {
            return [PSCustomObject]@{
                Stopped      = $false
                Method       = 'service'
                ErrorMessage = "Exception stopping service '$serviceName': $_"
            }
        }
    }
    elseif ($runMode -eq 'console') {
        # Try graceful shutdown via VRage API
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

        if (-not [string]::IsNullOrWhiteSpace($vrageKey)) {
            if ($hasLogger) {
                Write-SEBLog -Message "Attempting graceful shutdown via VRage API for console-mode instance..." -Level INFO -Context $instanceName
            }

            try {
                # Try to stop via API - this sends a shutdown command
                $apiResult = Invoke-SEBVRageRequest `
                    -Hostname $nodeHostname `
                    -Port $vragePort `
                    -SecurityKey $vrageKey `
                    -Endpoint 'server/stop' `
                    -Method 'PATCH'

                # Wait for the API to become unreachable (indicates shutdown)
                $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 3
                    $ping = Test-SEBVRageAPI -Hostname $nodeHostname -Port $vragePort -SecurityKey $vrageKey
                    if (-not $ping) {
                        # The API is down, but the process may still be flushing and closing the
                        # world files. Overwriting the world dir while those handles are open
                        # corrupts the restore, so wait for the actual process to exit (handles
                        # released), then settle briefly. Fall back to the settle delay alone if
                        # the process cannot be located by name.
                        $procName = if ($InstanceConfig.ContainsKey('process_name') -and -not [string]::IsNullOrWhiteSpace($InstanceConfig['process_name'])) {
                            $InstanceConfig['process_name']
                        }
                        else { 'Torch.Server' }

                        # Give the process-exit wait its OWN deadline. Reusing the outer $deadline
                        # (already mostly consumed waiting for the API to drop) meant that if the API
                        # only went unreachable near the end of the window, this loop never ran and
                        # only the 3s settle applied -- robocopy could then overwrite the world dir
                        # while Torch.Server still held file handles, corrupting the restore.
                        $procDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
                        while ((Get-Date) -lt $procDeadline) {
                            $stillRunning = Invoke-Command -Session $Session -ScriptBlock {
                                param($name)
                                [bool](Get-Process -Name $name -ErrorAction SilentlyContinue)
                            } -ArgumentList $procName -ErrorAction SilentlyContinue
                            if (-not $stillRunning) { break }
                            Start-Sleep -Seconds 2
                        }

                        # Settle to let the OS release any lingering file handles.
                        Start-Sleep -Seconds 3

                        if ($hasLogger) {
                            Write-SEBLog -Message "Console-mode Torch server stopped (API unreachable, process '$procName' exited)." -Level INFO -Context $instanceName
                        }
                        return [PSCustomObject]@{
                            Stopped      = $true
                            Method       = 'console_api'
                            ErrorMessage = $null
                        }
                    }
                }

                return [PSCustomObject]@{
                    Stopped      = $false
                    Method       = 'console_api'
                    ErrorMessage = "VRage API shutdown command sent but server did not stop within ${TimeoutSeconds}s. Manual intervention may be required."
                }
            }
            catch {
                $warnMsg = "Failed to stop console-mode server via API: $_. Manual intervention may be required."
                if ($hasLogger) {
                    Write-SEBLog -Message $warnMsg -Level WARN -Context $instanceName
                }
                return [PSCustomObject]@{
                    Stopped      = $false
                    Method       = 'console_api'
                    ErrorMessage = $warnMsg
                }
            }
        }
        else {
            $warnMsg = "Console mode with no VRage API key configured. Cannot stop server automatically. Please stop the server manually."
            if ($hasLogger) {
                Write-SEBLog -Message $warnMsg -Level WARN -Context $instanceName
            }
            return [PSCustomObject]@{
                Stopped      = $false
                Method       = 'manual'
                ErrorMessage = $warnMsg
            }
        }
    }
    else {
        return [PSCustomObject]@{
            Stopped      = $false
            Method       = 'unknown'
            ErrorMessage = "Unknown run_mode: '$runMode'"
        }
    }
}
