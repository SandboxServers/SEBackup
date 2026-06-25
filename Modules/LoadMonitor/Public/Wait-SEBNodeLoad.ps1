function Wait-SEBNodeLoad {
    <#
    .SYNOPSIS
        Waits for a remote node's load to drop below thresholds before proceeding.

    .DESCRIPTION
        Implements the defer/skip logic for high-load scenarios during backup
        scheduling:

        If on_high_load == "defer":
            Polls the node at regular intervals (defer_poll_interval_seconds from
            the global config's load_awareness section, default 30 seconds) until
            the load drops below all thresholds. Waits up to a maximum duration
            (defer_wait_minutes, default 60 minutes). Returns CanProceed = $true
            if load drops within the timeout, or $false if the timeout elapses.

        If on_high_load == "skip":
            Returns immediately with CanProceed = $false without polling. The
            backup operation should be skipped entirely for this cycle.

        All poll checks are logged with actual metric values versus thresholds
        for diagnostics and audit purposes.

    .PARAMETER Session
        An open PSSession to the remote game server node.

    .PARAMETER InstanceConfig
        A hashtable containing the instance configuration. Must include vrage_api
        settings for player count queries.

    .PARAMETER GlobalConfig
        A hashtable containing the global configuration. Must include the
        load_awareness section with thresholds, on_high_load policy, polling
        interval, and wait timeout settings.

    .EXAMPLE
        $session = New-SEBSession -NodeName "GameServer01"
        $waitResult = Wait-SEBNodeLoad -Session $session -InstanceConfig $instCfg -GlobalConfig $globalCfg
        if ($waitResult.CanProceed) {
            # Start the backup
        } else {
            Write-Warning "Backup deferred: node load did not drop in time."
        }

    .EXAMPLE
        # Immediate skip behavior
        $globalCfg = @{
            load_awareness = @{
                enabled      = $true
                on_high_load = 'skip'
            }
        }
        $result = Wait-SEBNodeLoad -Session $session -InstanceConfig $cfg -GlobalConfig $globalCfg
        $result.CanProceed  # $false -- skipped immediately

    .OUTPUTS
        PSCustomObject
        An object with properties: CanProceed (bool), WaitedSeconds (int),
        PollCount (int), FinalLoadCheck (object), Reason (string).

    .LINK
        Test-SEBNodeLoad
        Get-SEBNodeMetrics
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [hashtable]$InstanceConfig,

        [Parameter(Mandatory)]
        [hashtable]$GlobalConfig
    )

    $result = [PSCustomObject]@{
        CanProceed     = $false
        WaitedSeconds  = 0
        PollCount      = 0
        FinalLoadCheck = $null
        Reason         = $null
    }

    $loadConfig = $GlobalConfig['load_awareness']
    if (-not $loadConfig -or -not $loadConfig['enabled']) {
        $result.CanProceed = $true
        $result.Reason = 'Load awareness is disabled.'
        return $result
    }

    # --- Determine the on_high_load policy ---
    $onHighLoad = if ($loadConfig['on_high_load']) { $loadConfig['on_high_load'].ToLower() } else { 'defer' }

    if ($onHighLoad -eq 'skip') {
        $result.CanProceed = $false
        $result.Reason = 'Policy is "skip" -- backup skipped due to high load.'

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Load policy is 'skip' -- backup will not proceed." -Level WARN -Context 'LoadMonitor'
        }

        return $result
    }

    # --- Defer mode: poll until load drops or timeout ---
    # The shipped config uses check_interval_seconds / max_backoff_minutes; accept the older
    # defer_* names too so existing configs keep working. Without this match the operator's
    # settings were silently ignored and the hard-coded defaults were used.
    $pollIntervalSeconds = if ($loadConfig['check_interval_seconds']) {
        [int]$loadConfig['check_interval_seconds']
    } elseif ($loadConfig['defer_poll_interval_seconds']) {
        [int]$loadConfig['defer_poll_interval_seconds']
    } else { 30 }

    $maxWaitMinutes = if ($loadConfig['max_backoff_minutes']) {
        [int]$loadConfig['max_backoff_minutes']
    } elseif ($loadConfig['defer_wait_minutes']) {
        [int]$loadConfig['defer_wait_minutes']
    } else { 60 }

    $maxWaitSeconds = $maxWaitMinutes * 60
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollCount = 0

    if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
        Write-SEBLog -Message "Deferring backup: polling every ${pollIntervalSeconds}s, max wait ${maxWaitMinutes}m" -Level INFO -Context 'LoadMonitor'
    }

    while ($stopwatch.Elapsed.TotalSeconds -lt $maxWaitSeconds) {
        $pollCount++

        # Perform a load check
        $loadCheck = Test-SEBNodeLoad -Session $Session -InstanceConfig $InstanceConfig -GlobalConfig $GlobalConfig
        $result.FinalLoadCheck = $loadCheck

        $elapsed = [math]::Round($stopwatch.Elapsed.TotalSeconds, 0)

        if ($loadCheck.CanProceed) {
            $stopwatch.Stop()
            $result.CanProceed = $true
            $result.WaitedSeconds = $elapsed
            $result.PollCount = $pollCount
            $result.Reason = "Load dropped below thresholds after ${elapsed}s ($pollCount poll(s))."

            if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
                Write-SEBLog -Message "Load check passed after ${elapsed}s ($pollCount polls): CPU=$($loadCheck.CpuPercent)%, Memory=$($loadCheck.AvailableMemoryMB)MB, Players=$($loadCheck.PlayerCount)" -Level INFO -Context 'LoadMonitor'
            }

            return $result
        }

        # Log the current state
        $reasonsText = $loadCheck.Reasons -join '; '
        Write-Verbose "LoadMonitor: Poll $pollCount (${elapsed}s elapsed): still high load -- $reasonsText"

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Defer poll $pollCount (${elapsed}s/$($maxWaitSeconds)s): $reasonsText" -Level DEBUG -Context 'LoadMonitor'
        }

        # Wait before the next poll, but don't exceed the max wait time
        $remainingSeconds = $maxWaitSeconds - $stopwatch.Elapsed.TotalSeconds
        $sleepSeconds = [math]::Min($pollIntervalSeconds, [math]::Max(0, $remainingSeconds))

        if ($sleepSeconds -gt 0) {
            Start-Sleep -Seconds $sleepSeconds
        }
    }

    # Timeout reached
    $stopwatch.Stop()
    $result.WaitedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 0)
    $result.PollCount = $pollCount
    $result.Reason = "Timeout after ${maxWaitMinutes} minutes ($pollCount polls). Load did not drop below thresholds."

    if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
        Write-SEBLog -Message "Defer timeout: waited ${maxWaitMinutes}m ($pollCount polls), load still too high." -Level WARN -Context 'LoadMonitor'
    }

    return $result
}
