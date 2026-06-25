function Invoke-SEBRemoteCommand {
    <#
    .SYNOPSIS
        Executes a script block on a remote node with retry logic and logging.

    .DESCRIPTION
        A resilient wrapper around Invoke-Command that provides:

        - Automatic retry on transient failures (configurable retry count).
          IMPORTANT: the default RetryCount=1 makes the command run up to TWICE.
          That is only safe for IDEMPOTENT work (reads, hash/verify, metrics). A
          transport drop that occurs AFTER the remote block has already mutated
          node state but BEFORE the result returns would otherwise cause the
          mutation to RUN AGAIN on the retry. Callers performing non-idempotent
          writes (VSS create/mount/remove, world rename + robocopy, service
          start/stop, deletes, best-effort cleanups) MUST pass -RetryCount 0 so a
          transport failure fails fast into their own rollback/abort handling
          instead of silently re-running.
        - Session health detection via the Test-SEBSessionUsable predicate
          (State=Opened AND Availability=Available) -- the wrapper's execution gate
          ("can run a command NOW"). (This is stricter than Test-SEBSessionAlive,
          the "exists / don't destroy" predicate used by session creation/probing,
          which counts Busy as alive.) If the session is not usable,
          the wrapper distinguishes two cases:
            * Terminal (State != Opened, or Availability=None): the handle is dead
              or never opened. The wrapper reconnects ONCE per invocation.
            * Busy-but-Opened (State=Opened, Availability=Busy/nested/debug): the
              runspace is mid-command (often another caller sharing the same
              cached per-node session). This is transient, NOT a broken handle, so
              the wrapper briefly polls for it to return to Available and, if it
              stays busy, throws a clear "session busy" error WITHOUT tearing the
              session down -- it must never kill a runspace running someone else's
              command. If the runspace instead goes TERMINAL during the wait (the
              in-flight command broke the transport), the wrapper re-classifies it
              as terminal and falls through to the one-shot reconnect rather than
              misreporting a now-dead handle as "busy".
        - Reconnect that preserves the connection identity and ownership:
            1. The dead session's real target (ComputerName, i.e. the pinned
               hostname/IP) is captured BEFORE removal and passed back through
               -NodeConfig so the reconnect goes to the SAME host, not the bare
               friendly alias (alias != hostname is the documented standard
               deployment; reconnecting to the alias could fail to resolve or, if
               it resolves to a different machine, run commands on the WRONG node
               and leak the stored credential there).
            2. The node is derived ONLY from a strict 'SEBackup-(.+)' match on the
               session Name. A session not created by New-SEBSession is rejected
               rather than reconnected under a guessed credential/cache key.
            3. If the module cache already holds a healthy session for the node
               (e.g. a prior reconnect by another call stored one), it is reused
               instead of being torn down -- this avoids closing a live session
               and preserves caller-owned sessions.
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

        Pass 0 for any NON-IDEMPOTENT remote block (anything that mutates node
        state and is not safe to run twice). With RetryCount=0 the command is
        attempted exactly once, so a post-mutation transport drop surfaces as a
        thrown error the caller can route into rollback, rather than being
        silently re-executed by a retry.

    .PARAMETER SessionRef
        An optional [ref] to the caller's own session variable. When the wrapper
        reconnects a dead session, it writes the new session back through this
        reference so the caller's variable points at the live session for its
        subsequent operations. Pass it as -SessionRef ([ref]$session).

    .PARAMETER BusyWaitSeconds
        How long to poll for a State=Opened but Availability=Busy session to
        return to Available before giving up with a "busy" error. Default 30.
        A busy session is never reconnected or torn down (it may be running
        another caller's command); it is only waited on. The default is 30s
        rather than a few seconds because the per-node session is shared and
        legitimate concurrent ops (compression/hashing/robocopy on large worlds)
        routinely run for minutes; a session that goes terminal during the wait
        is reconnected instead, so waiting longer only affects the truly-busy case.

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
        [ref]$SessionRef,

        [Parameter()]
        [ValidateRange(0, 120)]
        # Default 30s, not 10s: the per-node session is a SHARED cache entry, and legitimate
        # concurrent holders (multiple Torch instances per node) run minutes-long
        # compression/hashing/robocopy. A short poll would make a colliding caller throw 'busy'
        # while a normal long op is still in flight; 30s tolerates the common case while still
        # bounding the synchronous wait. Throwing is safe (no teardown), so this is tuning.
        [int]$BusyWaitSeconds = 30
    )

    $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue
    $nodeName = $Session.ComputerName
    $attempt = 0
    $maxAttempts = $RetryCount + 1
    $reconnected = $false
    $lastError = $null

    while ($attempt -lt $maxAttempts) {
        $attempt++

        # Check session health before executing, using the Test-SEBSessionUsable
        # predicate (State=Opened AND Availability=Available) -- the wrapper's execution gate.
        # (Session creation/probing use the broader Test-SEBSessionAlive instead.) A session that is not usable
        # falls into one of two distinct buckets that must be handled DIFFERENTLY:
        #   * Busy-but-Opened: the runspace is mid-command (commonly another caller sharing
        #     this cached per-node session). This is transient -- wait briefly, do NOT tear
        #     the session down (killing a runspace running someone else's command would abort
        #     an in-flight backup/restore step).
        #   * Terminal (State != Opened, or Availability=None == "not in the Opened state"):
        #     the handle is dead/never-opened. Reconnect once per invocation.
        if (-not (Test-SEBSessionUsable -Session $Session)) {

            $isOpened = $Session.State -eq [System.Management.Automation.Runspaces.RunspaceState]::Opened
            $isNone = $Session.Availability -eq [System.Management.Automation.Runspaces.RunspaceAvailability]::None

            if ($isOpened -and -not $isNone) {
                # State=Opened but Availability is Busy / AvailableForNestedCommand / RemoteDebug.
                # Briefly poll for the runspace to go idle; never reconnect or remove it here.
                $busyDeadline = (Get-Date).AddSeconds($BusyWaitSeconds)
                while ((Get-Date) -lt $busyDeadline -and -not (Test-SEBSessionUsable -Session $Session)) {
                    Start-Sleep -Milliseconds 500
                }
                if (Test-SEBSessionUsable -Session $Session) {
                    # Became Available -- fall through and execute on the same session.
                }
                else {
                    # Still not usable after the wait. Re-classify: the runspace may have gone
                    # TERMINAL (State left Opened, or Availability dropped to None) while we polled
                    # -- e.g. the in-flight command finished by breaking the transport. In that case
                    # it is no longer "busy with someone else's work"; it is dead, so fall through to
                    # the one-shot reconnect instead of misreporting it as busy. Only throw the busy
                    # error if it is STILL genuinely busy (Opened and not None).
                    $isOpened = $Session.State -eq [System.Management.Automation.Runspaces.RunspaceState]::Opened
                    $isNone = $Session.Availability -eq [System.Management.Automation.Runspaces.RunspaceAvailability]::None
                    if ($isOpened -and -not $isNone) {
                        throw "Session to '$nodeName' is busy (State=$($Session.State), Availability=$($Session.Availability)) and did not become available. Refusing to reconnect a busy session (it may be running another operation)."
                    }
                    # Otherwise it went terminal during the wait -- handle it as terminal below.
                }
            }

            # NB: re-test usability here rather than chaining elseif on the entry-time state, so a
            # session that transitioned Busy -> terminal during the busy-wait still reaches the
            # reconnect path (instead of the stale 'busy' throw above).
            if (-not (Test-SEBSessionUsable -Session $Session) -and -not $reconnected) {
                if ($hasLogger) {
                    Write-SEBLog -Message "Session to '$nodeName' is not usable (State=$($Session.State), Availability=$($Session.Availability)). Attempting reconnection." -Level WARN
                }
                Write-Warning "Session to '$nodeName' is not usable (State=$($Session.State), Availability=$($Session.Availability)). Attempting to reconnect..."

                try {
                    # Derive the node STRICTLY from the canonical session Name 'SEBackup-<node>'.
                    # A session not created by New-SEBSession must NOT be reconnected -- guessing a
                    # key would fetch the wrong node's credential and pollute the cache under a
                    # foreign name (and connect to that foreign name as a host).
                    if ($Session.Name -match '^SEBackup-(.+)$') {
                        $sessionNodeName = $Matches[1]
                    }
                    else {
                        throw "cannot reconnect a session not created by New-SEBSession (Name='$($Session.Name)')"
                    }

                    # Capture the dying handle's real connection target BEFORE removing it, so the
                    # reconnect goes to the same pinned hostname/IP rather than the bare friendly
                    # alias (node alias != hostname is the documented standard deployment).
                    $origComputerName = $Session.ComputerName

                    # If the module cache already holds an ALIVE session for this node (e.g. another
                    # call reconnected it), reuse it instead of tearing it down -- closing a live
                    # session and rebuilding wastes a round-trip and can orphan a caller-owned handle.
                    # Use Test-SEBSessionAlive (not Usable), consistent with New-SEBSession/
                    # Test-SEBSessionExists: a Busy-but-alive shared session must never be torn down;
                    # the execution-gate busy-wait below handles it if it is momentarily Busy.
                    $cached = $script:SEBSessions[$sessionNodeName]
                    if ($cached -and (Test-SEBSessionAlive -Session $cached)) {
                        $Session = $cached
                    }
                    else {
                        # Remove the broken session from the cache and create a new one, preserving
                        # the original connection target via NodeConfig. New-SEBSession rewrites the
                        # module-scoped cache for this node, so cache-based callers
                        # (New-SEBSession/Test-SEBSessionExists) observe the live session after this.
                        Remove-SEBSession -NodeName $sessionNodeName -ErrorAction SilentlyContinue
                        $Session = New-SEBSession -NodeName $sessionNodeName -NodeConfig @{ hostname = $origComputerName }
                    }
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
            elseif (-not (Test-SEBSessionUsable -Session $Session)) {
                # Still not usable AND we already reconnected once this invocation -- give up.
                # (A session that became Available during the busy-wait is usable here and falls
                # through to execute; this branch fires only for the terminal-after-reconnect case.)
                throw "Session to '$nodeName' is not usable (State=$($Session.State), Availability=$($Session.Availability)) after reconnection attempt. Cannot execute command."
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
