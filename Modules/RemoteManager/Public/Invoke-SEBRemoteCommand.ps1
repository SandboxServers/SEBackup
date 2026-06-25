function Invoke-SEBRemoteCommand {
    <#
    .SYNOPSIS
        Executes a script block on a remote node with retry logic and logging.

    .DESCRIPTION
        A resilient wrapper around Invoke-Command that provides:

        - Automatic retry on transient failures (configurable retry count).
        - Session health detection: if the session is no longer available to
          run commands, attempts to reconnect by creating a new session via
          New-SEBSession (one reconnection attempt per invocation).
        - Reconnect propagation: when a reconnection happens, the refreshed
          session is pushed back to the caller so subsequent calls do not keep
          using the dead handle. Propagation works two ways:
            1. New-SEBSession rewrites the module-scoped session cache keyed by
               NodeName, so the next New-SEBSession/Test-SEBSessionExists for
               that node observes the live session.
            2. If the caller passes its session variable by reference via
               -SessionRef, that variable is updated in place to the live
               session immediately.
        - Structured logging of command execution via Write-SEBLog when the
          Logger module is available.

        Session liveness is determined by Availability (RunspaceAvailability),
        not just State: a PSSession can be State=Opened yet Availability=Busy or
        None, in which case it cannot accept a new command. Only an Available
        session is used as-is; anything else triggers the reconnect path.

        This function is intended to be the primary mechanism for executing
        commands on remote Space Engineers Torch server nodes during backup
        and restore operations.

    .PARAMETER Session
        The PSSession to execute the command on. Typically obtained from
        New-SEBSession.

    .PARAMETER ScriptBlock
        The script block to execute on the remote node.

    .PARAMETER ArgumentList
        An array of arguments to pass to the script block.

    .PARAMETER RetryCount
        The number of times to retry the command on failure. Default is 1,
        meaning the command will be attempted a total of 2 times (initial
        attempt + 1 retry).

    .PARAMETER SessionRef
        An optional [ref] to the caller's own session variable. When the wrapper
        reconnects a dead session, it writes the new session back through this
        reference so the caller's variable points at the live session for its
        subsequent operations. Pass it as -SessionRef ([ref]$session).

    .EXAMPLE
        $session = New-SEBSession -NodeName "GameServer01"
        Invoke-SEBRemoteCommand -Session $session -ScriptBlock { Get-Process torch* }
        # Executes the command on the remote node with default retry.

    .EXAMPLE
        $session = New-SEBSession -NodeName "GameServer01"
        $result = Invoke-SEBRemoteCommand -Session $session -ScriptBlock {
            param($path)
            Get-ChildItem -Path $path -Recurse
        } -ArgumentList "C:\TorchServer\Instance\Saves" -RetryCount 3
        # Passes an argument and retries up to 3 times on failure.

    .EXAMPLE
        $session = New-SEBSession -NodeName "GameServer01"
        Invoke-SEBRemoteCommand -Session $session -ScriptBlock {
            Stop-Service -Name "TorchServer" -Force
        } -SessionRef ([ref]$session) -RetryCount 0
        # If the session is dead it is reconnected and $session is refreshed in
        # place, so the caller's next -Session $session call uses the live one.

    .OUTPUTS
        System.Object
        The output of the remote script block execution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory, Position = 1)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [object[]]$ArgumentList,

        [Parameter()]
        [ValidateRange(0, 10)]
        [int]$RetryCount = 1,

        [Parameter()]
        [ref]$SessionRef
    )

    $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue
    $nodeName = $Session.ComputerName
    $attempt = 0
    $maxAttempts = $RetryCount + 1
    $reconnected = $false
    $lastError = $null

    while ($attempt -lt $maxAttempts) {
        $attempt++

        # Check session health before executing. Availability (not State) is the
        # authoritative signal: a session can be State=Opened but Availability=Busy
        # or None, in which case it cannot accept a new command.
        if ($Session.Availability -ne [System.Management.Automation.Runspaces.RunspaceAvailability]::Available) {
            if (-not $reconnected) {
                if ($hasLogger) {
                    Write-SEBLog -Message "Session to '$nodeName' is not available (State=$($Session.State), Availability=$($Session.Availability)). Attempting reconnection." -Level WARN
                }
                Write-Warning "Session to '$nodeName' is not available (State=$($Session.State), Availability=$($Session.Availability)). Attempting to reconnect..."

                try {
                    # Extract the node name from the session name (format: SEBackup-{NodeName})
                    $sessionNodeName = $Session.Name -replace '^SEBackup-', ''
                    if ([string]::IsNullOrEmpty($sessionNodeName)) {
                        $sessionNodeName = $nodeName
                    }

                    # Remove the broken session from the cache and create a new one.
                    # New-SEBSession rewrites the module-scoped cache for this node,
                    # so cache-based callers (New-SEBSession/Test-SEBSessionExists)
                    # observe the live session after this point.
                    Remove-SEBSession -NodeName $sessionNodeName -ErrorAction SilentlyContinue
                    $Session = New-SEBSession -NodeName $sessionNodeName
                    $reconnected = $true

                    # Propagate the refreshed session back to the caller's variable so its
                    # later -Session $session calls use the live handle, not the dead one.
                    if ($PSBoundParameters.ContainsKey('SessionRef') -and $null -ne $SessionRef) {
                        $SessionRef.Value = $Session
                    }

                    # Keep $nodeName in sync with the reconnected session for logging.
                    $nodeName = $Session.ComputerName

                    if ($hasLogger) {
                        Write-SEBLog -Message "Successfully reconnected session to '$nodeName'." -Level INFO
                    }
                    Write-Verbose "Successfully reconnected session to '$nodeName'."
                }
                catch {
                    throw "Session to '$nodeName' is broken and reconnection failed: $_"
                }
            }
            else {
                throw "Session to '$nodeName' is not available (State=$($Session.State), Availability=$($Session.Availability)) after reconnection attempt. Cannot execute command."
            }
        }

        try {
            if ($hasLogger) {
                Write-SEBLog -Message "Executing remote command on '$nodeName' (attempt $attempt/$maxAttempts)" -Level DEBUG
            }
            Write-Verbose "Executing remote command on '$nodeName' (attempt $attempt/$maxAttempts)"

            $invokeParams = @{
                Session      = $Session
                ScriptBlock  = $ScriptBlock
                ErrorAction  = 'Stop'
            }
            if ($PSBoundParameters.ContainsKey('ArgumentList')) {
                $invokeParams['ArgumentList'] = $ArgumentList
            }

            $result = Invoke-Command @invokeParams

            if ($hasLogger -and $attempt -gt 1) {
                Write-SEBLog -Message "Remote command on '$nodeName' succeeded on attempt $attempt." -Level INFO
            }

            return $result
        }
        catch {
            $lastError = $_
            if ($hasLogger) {
                Write-SEBLog -Message "Remote command on '$nodeName' failed (attempt $attempt/$maxAttempts): $_" -Level WARN
            }
            Write-Warning "Remote command on '$nodeName' failed (attempt $attempt/$maxAttempts): $_"

            if ($attempt -lt $maxAttempts) {
                # Brief delay before retry with exponential backoff
                $delaySeconds = [math]::Min([math]::Pow(2, $attempt - 1), 30)
                Write-Verbose "Waiting $delaySeconds second(s) before retry..."
                Start-Sleep -Seconds $delaySeconds
            }
        }
    }

    # All attempts exhausted
    $errorMessage = "Remote command on '$nodeName' failed after $maxAttempts attempt(s). Last error: $lastError"
    if ($hasLogger) {
        Write-SEBLog -Message $errorMessage -Level ERROR
    }
    throw $errorMessage
}
