function Get-SEBMetrics {
    <#
    .SYNOPSIS
        Reads and returns metrics history for a specific server instance.

    .DESCRIPTION
        Reads the JSON metrics file for the specified instance and returns the parsed
        metrics object. The returned object contains the instance name and a history
        array of metric entries, limited to the most recent N entries (default 30).

        The metrics file is located at:
            {BackupRoot}\Data\metrics\{InstanceName}_metrics.json

        If the file does not exist or is empty, returns a default object with an
        empty history array.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance.

    .PARAMETER BackupRoot
        The root path where backup data is stored.

    .PARAMETER Last
        The maximum number of most recent metric entries to return.
        Defaults to 30. Set to 0 to return all entries.

    .EXAMPLE
        $metrics = Get-SEBMetrics -InstanceName "PvPArena" -BackupRoot "C:\SEBackup\Backups"
        $metrics.history | Select-Object timestamp, type, success

    .EXAMPLE
        # Get the last 10 metrics
        $metrics = Get-SEBMetrics -InstanceName "Creative01" -BackupRoot "C:\SEBackup\Backups" -Last 10

    .EXAMPLE
        # Get all metrics
        $metrics = Get-SEBMetrics -InstanceName "Survival" -BackupRoot "C:\SEBackup\Backups" -Last 0

    .OUTPUTS
        PSCustomObject
        An object with properties:
        - instance (string): the instance name
        - history (array): array of metric entry objects

    .LINK
        Add-SEBMetric
        Get-SEBHealthSummary
        Clear-SEBOldMetrics
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot,

        [Parameter()]
        [int]$Last = 30
    )

    $metricsFile = Join-Path -Path $BackupRoot -ChildPath 'Data' |
        Join-Path -ChildPath 'metrics' |
        Join-Path -ChildPath "${InstanceName}_metrics.json"

    # Default empty object
    $defaultObj = [PSCustomObject]@{
        instance = $InstanceName
        history  = @()
    }

    if (-not (Test-Path -Path $metricsFile -PathType Leaf)) {
        Write-Verbose "No metrics file found at: $metricsFile"
        return $defaultObj
    }

    try {
        $rawJson = Get-Content -Path $metricsFile -Raw -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($rawJson)) {
            Write-Verbose "Metrics file is empty: $metricsFile"
            return $defaultObj
        }

        $metricsObj = $rawJson | ConvertFrom-Json -ErrorAction Stop

        if ($null -eq $metricsObj -or $null -eq $metricsObj.history) {
            Write-Verbose "Metrics file has no history array: $metricsFile"
            return $defaultObj
        }

        # Limit to the most recent entries if requested
        $history = @($metricsObj.history)
        if ($Last -gt 0 -and $history.Count -gt $Last) {
            $history = $history[($history.Count - $Last)..($history.Count - 1)]
        }

        return [PSCustomObject]@{
            instance = $metricsObj.instance
            history  = $history
        }
    }
    catch {
        Write-Warning "Get-SEBMetrics: Failed to read metrics file '$metricsFile': $_"
        return $defaultObj
    }
}
