function Get-SEBHealthSummary {
    <#
    .SYNOPSIS
        Computes a health summary for a server instance based on its backup metrics.

    .DESCRIPTION
        Analyzes the metrics history for the specified instance and produces a structured
        health summary suitable for GUI display. The summary includes:

        - LastSuccessfulBackupAge: how long ago the last successful backup occurred,
          as a human-readable string (e.g., "2h 15m ago") and raw TimeSpan.
        - AverageBackupDuration: mean duration of the last 10 backups in seconds.
        - AverageArchiveSize: mean archive size of the last 10 backups in bytes.
        - SuccessRate: percentage of successful backups over the last 7 days.
        - CurrentChainLength: number of consecutive incremental backups since the
          last full backup.
        - DurationTrend: "growing", "stable", or "shrinking" based on the last 10
          backup durations.
        - SizeTrend: "growing", "stable", or "shrinking" based on the last 10
          archive sizes.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance.

    .PARAMETER BackupRoot
        The root path where backup data is stored.

    .EXAMPLE
        $health = Get-SEBHealthSummary -InstanceName "PvPArena" -BackupRoot "C:\SEBackup\Backups"
        $health.SuccessRate
        # Returns e.g. 95.5

    .EXAMPLE
        $health = Get-SEBHealthSummary -InstanceName "Creative01" -BackupRoot "C:\SEBackup\Backups"
        Write-Host "Last backup: $($health.LastSuccessfulBackupAgeFormatted)"
        Write-Host "Duration trend: $($health.DurationTrend)"

    .OUTPUTS
        PSCustomObject
        An object with properties:
        - InstanceName (string)
        - LastSuccessfulBackupAge (TimeSpan or $null)
        - LastSuccessfulBackupAgeFormatted (string)
        - AverageBackupDuration (double, seconds)
        - AverageArchiveSize (double, bytes)
        - SuccessRate (double, percentage 0-100)
        - CurrentChainLength (int)
        - DurationTrend (string: "growing", "stable", "shrinking")
        - SizeTrend (string: "growing", "stable", "shrinking")

    .LINK
        Get-SEBMetrics
        Add-SEBMetric
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot
    )

    # Get all metrics (no limit) for full analysis
    $metrics = Get-SEBMetrics -InstanceName $InstanceName -BackupRoot $BackupRoot -Last 0

    $now = [datetime]::UtcNow

    # Default health summary
    $summary = [PSCustomObject]@{
        InstanceName                    = $InstanceName
        LastSuccessfulBackupAge         = $null
        LastSuccessfulBackupAgeFormatted = 'Never'
        AverageBackupDuration           = 0.0
        AverageArchiveSize              = 0.0
        SuccessRate                     = 0.0
        CurrentChainLength              = 0
        DurationTrend                   = 'stable'
        SizeTrend                       = 'stable'
    }

    $history = @($metrics.history)
    if ($history.Count -eq 0) {
        Write-Verbose "No metrics history found for '$InstanceName'."
        return $summary
    }

    # --- Last Successful Backup Age ---
    $successfulEntries = @($history | Where-Object { $_.success -eq $true })
    if ($successfulEntries.Count -gt 0) {
        $lastSuccess = $successfulEntries[-1]
        try {
            $lastSuccessTime = [datetime]::Parse($lastSuccess.timestamp).ToUniversalTime()
            $age = $now - $lastSuccessTime
            $summary.LastSuccessfulBackupAge = $age

            # Format as human-readable
            if ($age.TotalDays -ge 1) {
                $days = [math]::Floor($age.TotalDays)
                $hours = $age.Hours
                $summary.LastSuccessfulBackupAgeFormatted = "${days}d ${hours}h ago"
            }
            elseif ($age.TotalHours -ge 1) {
                $hours = [math]::Floor($age.TotalHours)
                $minutes = $age.Minutes
                $summary.LastSuccessfulBackupAgeFormatted = "${hours}h ${minutes}m ago"
            }
            else {
                $minutes = [math]::Max(1, [math]::Floor($age.TotalMinutes))
                $summary.LastSuccessfulBackupAgeFormatted = "${minutes}m ago"
            }
        }
        catch {
            Write-Verbose "Failed to parse last successful backup timestamp: $_"
        }
    }

    # --- Average Backup Duration (last 10) ---
    $recentEntries = if ($history.Count -gt 10) {
        $history[($history.Count - 10)..($history.Count - 1)]
    }
    else {
        $history
    }

    $durations = @($recentEntries | Where-Object { $null -ne $_.duration_seconds } |
        ForEach-Object { [double]$_.duration_seconds })
    if ($durations.Count -gt 0) {
        $summary.AverageBackupDuration = [math]::Round(($durations | Measure-Object -Average).Average, 1)
    }

    # --- Average Archive Size (last 10) ---
    $sizes = @($recentEntries | Where-Object { $null -ne $_.archive_size_bytes -and $_.archive_size_bytes -gt 0 } |
        ForEach-Object { [double]$_.archive_size_bytes })
    if ($sizes.Count -gt 0) {
        $summary.AverageArchiveSize = [math]::Round(($sizes | Measure-Object -Average).Average, 0)
    }

    # --- Success Rate (last 7 days) ---
    $sevenDaysAgo = $now.AddDays(-7)
    $recentWeek = @($history | Where-Object {
        try {
            $ts = [datetime]::Parse($_.timestamp).ToUniversalTime()
            return $ts -ge $sevenDaysAgo
        }
        catch { return $false }
    })

    if ($recentWeek.Count -gt 0) {
        $successCount = @($recentWeek | Where-Object { $_.success -eq $true }).Count
        $summary.SuccessRate = [math]::Round(($successCount / $recentWeek.Count) * 100, 1)
    }

    # --- Current Chain Length ---
    # Count consecutive incremental backups from the end, stopping at the first Full
    $chainLength = 0
    for ($i = $history.Count - 1; $i -ge 0; $i--) {
        if ($history[$i].type -eq 'Full') {
            break
        }
        $chainLength++
    }
    $summary.CurrentChainLength = $chainLength

    # --- Duration Trend (last 10) ---
    if ($durations.Count -ge 3) {
        $summary.DurationTrend = Get-SEBTrendIndicator -Values $durations
    }

    # --- Size Trend (last 10) ---
    if ($sizes.Count -ge 3) {
        $summary.SizeTrend = Get-SEBTrendIndicator -Values $sizes
    }

    return $summary
}
