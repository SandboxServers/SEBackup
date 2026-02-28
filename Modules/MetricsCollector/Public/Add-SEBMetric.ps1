function Add-SEBMetric {
    <#
    .SYNOPSIS
        Appends a backup metric entry to the instance metrics history file.

    .DESCRIPTION
        Records a single backup metric entry to the JSON metrics file for the specified
        instance. The metrics file is stored at:
            {BackupRoot}\Data\metrics\{InstanceName}_metrics.json

        Each entry is timestamped and appended to the "history" array in the JSON file.
        If the file does not exist, it is created with a new history array.

        The metrics file structure is:
        {
            "instance": "InstanceName",
            "history": [
                {
                    "timestamp": "2026-02-27T14:30:00Z",
                    "type": "Full",
                    "duration_seconds": 135.5,
                    "archive_size_bytes": 1932735283,
                    "files_changed": 12,
                    "transfer_seconds": 45.2,
                    "compression_seconds": 30.1,
                    "vss_seconds": 8.5,
                    "manifest_seconds": 2.1,
                    "success": true
                }
            ]
        }

    .PARAMETER InstanceName
        The name of the Space Engineers server instance.

    .PARAMETER MetricData
        A hashtable containing the metric data to record. Expected keys:
        - type (string): "Full" or "Incremental"
        - duration_seconds (double): total backup duration
        - archive_size_bytes (long): size of the archive in bytes
        - files_changed (int): number of files that changed
        - transfer_seconds (double): time spent on file transfer
        - compression_seconds (double): time spent on compression
        - vss_seconds (double): time spent on VSS operations
        - manifest_seconds (double): time spent on manifest operations
        - success (bool): whether the backup succeeded

    .PARAMETER BackupRoot
        The root path where backup data is stored. The metrics file will be placed
        under {BackupRoot}\Data\metrics\.

    .EXAMPLE
        $metric = @{
            type                = 'Full'
            duration_seconds    = 135.5
            archive_size_bytes  = 1932735283
            files_changed       = 12
            transfer_seconds    = 45.2
            compression_seconds = 30.1
            vss_seconds         = 8.5
            manifest_seconds    = 2.1
            success             = $true
        }
        Add-SEBMetric -InstanceName "PvPArena" -MetricData $metric -BackupRoot "C:\SEBackup\Backups"

    .OUTPUTS
        None

    .LINK
        Get-SEBMetrics
        Clear-SEBOldMetrics
        Get-SEBHealthSummary
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$MetricData,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot
    )

    $metricsDir = Join-Path -Path $BackupRoot -ChildPath 'Data' | Join-Path -ChildPath 'metrics'
    $metricsFile = Join-Path -Path $metricsDir -ChildPath "${InstanceName}_metrics.json"

    # Ensure the metrics directory exists
    if (-not (Test-Path -Path $metricsDir -PathType Container)) {
        try {
            New-Item -Path $metricsDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Verbose "Created metrics directory: $metricsDir"
        }
        catch {
            Write-Error "Failed to create metrics directory '$metricsDir': $_"
            throw
        }
    }

    # Build the metric entry with a UTC timestamp
    $entry = @{
        timestamp           = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        type                = $MetricData['type']
        duration_seconds    = $MetricData['duration_seconds']
        archive_size_bytes  = $MetricData['archive_size_bytes']
        files_changed       = $MetricData['files_changed']
        transfer_seconds    = $MetricData['transfer_seconds']
        compression_seconds = $MetricData['compression_seconds']
        vss_seconds         = $MetricData['vss_seconds']
        manifest_seconds    = $MetricData['manifest_seconds']
        success             = $MetricData['success']
    }

    # Load existing metrics or create a new structure
    $metricsObj = $null
    if (Test-Path -Path $metricsFile -PathType Leaf) {
        try {
            $rawJson = Get-Content -Path $metricsFile -Raw -ErrorAction Stop
            $metricsObj = $rawJson | ConvertFrom-Json -ErrorAction Stop

            # Convert to a mutable structure if needed
            if ($null -eq $metricsObj.history) {
                $metricsObj | Add-Member -NotePropertyName 'history' -NotePropertyValue @() -Force
            }
        }
        catch {
            Write-Warning "Add-SEBMetric: Failed to parse existing metrics file. Creating a new one. Error: $_"
            $metricsObj = $null
        }
    }

    if ($null -eq $metricsObj) {
        $metricsObj = [PSCustomObject]@{
            instance = $InstanceName
            history  = @()
        }
    }

    # Append the new entry to the history array
    $historyList = [System.Collections.ArrayList]::new()
    foreach ($existing in $metricsObj.history) {
        [void]$historyList.Add($existing)
    }
    [void]$historyList.Add([PSCustomObject]$entry)

    $metricsObj.history = @($historyList)

    # Write back to disk
    try {
        $json = $metricsObj | ConvertTo-Json -Depth 10
        Set-Content -Path $metricsFile -Value $json -Encoding UTF8 -ErrorAction Stop
        Write-Verbose "Appended metric entry to: $metricsFile (total entries: $($historyList.Count))"
    }
    catch {
        Write-Error "Failed to write metrics file '$metricsFile': $_"
        throw
    }
}
