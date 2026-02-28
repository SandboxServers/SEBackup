function Clear-SEBOldMetrics {
    <#
    .SYNOPSIS
        Trims the metrics history file to the most recent entries.

    .DESCRIPTION
        Reads the metrics JSON file for the specified instance and trims the history
        array to retain only the most recent KeepCount entries. Older entries beyond
        the KeepCount limit are permanently removed.

        This prevents the metrics file from growing indefinitely over time. Typically
        called as part of periodic maintenance.

        If the history already has fewer entries than KeepCount, no changes are made.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance.

    .PARAMETER BackupRoot
        The root path where backup data is stored.

    .PARAMETER KeepCount
        The maximum number of most recent metric entries to retain.
        Defaults to 500.

    .EXAMPLE
        Clear-SEBOldMetrics -InstanceName "PvPArena" -BackupRoot "C:\SEBackup\Backups"
        # Trims to the most recent 500 entries (default).

    .EXAMPLE
        Clear-SEBOldMetrics -InstanceName "Creative01" -BackupRoot "C:\SEBackup\Backups" -KeepCount 100
        # Trims to the most recent 100 entries.

    .OUTPUTS
        None

    .LINK
        Add-SEBMetric
        Get-SEBMetrics
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$KeepCount = 500
    )

    $metricsFile = Join-Path -Path $BackupRoot -ChildPath 'Data' |
        Join-Path -ChildPath 'metrics' |
        Join-Path -ChildPath "${InstanceName}_metrics.json"

    if (-not (Test-Path -Path $metricsFile -PathType Leaf)) {
        Write-Verbose "No metrics file found at: $metricsFile. Nothing to trim."
        return
    }

    try {
        $rawJson = Get-Content -Path $metricsFile -Raw -ErrorAction Stop
        $metricsObj = $rawJson | ConvertFrom-Json -ErrorAction Stop

        if ($null -eq $metricsObj -or $null -eq $metricsObj.history) {
            Write-Verbose "Metrics file has no history array. Nothing to trim."
            return
        }

        $history = @($metricsObj.history)
        $originalCount = $history.Count

        if ($originalCount -le $KeepCount) {
            Write-Verbose "Metrics history for '$InstanceName' has $originalCount entries (limit: $KeepCount). No trimming needed."
            return
        }

        # Keep only the most recent entries
        $trimmed = $history[($originalCount - $KeepCount)..($originalCount - 1)]
        $metricsObj.history = @($trimmed)

        $json = $metricsObj | ConvertTo-Json -Depth 10
        Set-Content -Path $metricsFile -Value $json -Encoding UTF8 -ErrorAction Stop

        $removed = $originalCount - $KeepCount
        Write-Verbose "Trimmed metrics for '$InstanceName': removed $removed old entries, kept $KeepCount (was $originalCount)."
    }
    catch {
        Write-Error "Clear-SEBOldMetrics: Failed to trim metrics file '$metricsFile': $_"
    }
}
