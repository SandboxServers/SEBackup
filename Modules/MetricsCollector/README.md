# MetricsCollector Module

Backup metrics collection, disk space monitoring, health summaries, and trend analysis. Stores per-instance metrics in JSON files and provides health dashboards suitable for GUI display.

## Exported Functions

### Add-SEBMetric

Appends a new metric entry to the per-instance metrics history file.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Metric | hashtable | Yes | -- | A hashtable containing metric data (instance, node, type, success, duration_sec, archive_bytes, file_count, chain_id, chain_sequence, timestamp). |
| BackupRoot | string | No | from global config | The root path where backup data is stored. |

**Output:** None

```powershell
Add-SEBMetric -Metric @{
    instance       = "PvPArena"
    node           = "GameServer01"
    type           = "incremental"
    success        = $true
    duration_sec   = 45.2
    archive_bytes  = 15728640
    file_count     = 342
    chain_id       = "abc-123"
    chain_sequence = 3
    timestamp      = [datetime]::UtcNow.ToString('o')
}
```

### Get-SEBMetrics

Reads the metrics history for a specific instance, optionally limited to the most recent N entries.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| InstanceName | string | Yes | -- | The instance name. |
| BackupRoot | string | Yes | -- | The root backup data path. |
| Last | int | No | `50` | Number of most recent entries to return. Use `0` for all entries. |

**Output:** `PSCustomObject` with `instance` (string) and `history` (PSCustomObject[]) properties. Each history entry contains the metric fields recorded by `Add-SEBMetric`.

```powershell
$metrics = Get-SEBMetrics -InstanceName "PvPArena" -BackupRoot "C:\SEBackup\Backups" -Last 10
$metrics.history | Format-Table timestamp, type, success, duration_sec
```

### Get-SEBDiskSpace

Returns disk space information for the C&C backup root and optional NAS path.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| BackupRoot | string | No | from global config | The C&C backup root path. |
| NASPath | string | No | from global config | The NAS backup path. |

**Output:** `PSCustomObject` with `CC` (hashtable with DriveLetter, FreeGB, UsedGB, TotalGB) and `NAS` (hashtable or `$null`).

```powershell
$disk = Get-SEBDiskSpace
Write-Host "C&C: $($disk.CC.FreeGB) GB free of $($disk.CC.TotalGB) GB"
if ($disk.NAS) { Write-Host "NAS: $($disk.NAS.FreeGB) GB free" }
```

### Get-SEBHealthSummary

Computes a comprehensive health summary for an instance based on its full metrics history. Designed for GUI dashboard display.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| InstanceName | string | Yes | -- | The instance name. |
| BackupRoot | string | Yes | -- | The root backup data path. |

**Output:** `PSCustomObject` with the following properties:

| Property | Type | Description |
|----------|------|-------------|
| `InstanceName` | string | The instance name. |
| `LastSuccessfulBackupAge` | TimeSpan or `$null` | Time since last successful backup. |
| `LastSuccessfulBackupAgeFormatted` | string | Human-readable age (e.g., `2h 15m ago`). |
| `AverageBackupDuration` | double | Mean duration of last 10 backups (seconds). |
| `AverageArchiveSize` | double | Mean archive size of last 10 backups (bytes). |
| `SuccessRate` | double | Percentage of successful backups over last 7 days (0-100). |
| `CurrentChainLength` | int | Consecutive incrementals since last full. |
| `DurationTrend` | string | `growing`, `stable`, or `shrinking`. |
| `SizeTrend` | string | `growing`, `stable`, or `shrinking`. |

```powershell
$health = Get-SEBHealthSummary -InstanceName "PvPArena" -BackupRoot "C:\SEBackup\Backups"
Write-Host "Last backup: $($health.LastSuccessfulBackupAgeFormatted)"
Write-Host "Success rate: $($health.SuccessRate)%"
Write-Host "Duration trend: $($health.DurationTrend)"
```

### Clear-SEBOldMetrics

Trims the metrics history file to retain only the most recent entries, preventing indefinite growth.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| InstanceName | string | Yes | -- | The instance name. |
| BackupRoot | string | Yes | -- | The root backup data path. |
| KeepCount | int | No | `500` | Maximum number of entries to retain. |

**Output:** None

```powershell
Clear-SEBOldMetrics -InstanceName "PvPArena" -BackupRoot "C:\SEBackup\Backups"
Clear-SEBOldMetrics -InstanceName "Creative01" -BackupRoot "C:\SEBackup\Backups" -KeepCount 100
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Get-SEBTrendIndicator` | Computes a trend direction (`growing`, `stable`, or `shrinking`) from a numeric array using linear regression slope analysis. Used by `Get-SEBHealthSummary` for duration and size trends. |

## Metrics File Format

Metrics are stored as JSON files at `{BackupRoot}/Data/metrics/{InstanceName}_metrics.json`:

```json
{
    "instance": "PvPArena",
    "history": [
        {
            "instance": "PvPArena",
            "node": "GameServer01",
            "type": "full",
            "success": true,
            "duration_sec": 120.5,
            "archive_bytes": 52428800,
            "file_count": 1024,
            "chain_id": "abc-123",
            "chain_sequence": 0,
            "timestamp": "2026-02-27T10:30:00.0000000Z"
        }
    ]
}
```

## Dependencies

None (uses built-in JSON serialization and math).

## Usage Scenarios

**Scenario 1: Recording metrics after a backup (called by BackupEngine)**
```powershell
Add-SEBMetric -Metric @{
    instance       = $InstanceName
    node           = $NodeName
    type           = $backupType
    success        = $result.IntegrityPassed
    duration_sec   = $duration.TotalSeconds
    archive_bytes  = $result.ArchiveSizeBytes
    file_count     = $result.FileCount
    timestamp      = [datetime]::UtcNow.ToString('o')
}
```

**Scenario 2: Dashboard health overview**
```powershell
$instances = @("PvPArena", "Creative01", "Survival")
$backupRoot = "C:\SEBackup\Backups"
foreach ($inst in $instances) {
    $health = Get-SEBHealthSummary -InstanceName $inst -BackupRoot $backupRoot
    Write-Host "$inst : $($health.LastSuccessfulBackupAgeFormatted) | $($health.SuccessRate)% | Chain: $($health.CurrentChainLength)"
}
```

**Scenario 3: Periodic maintenance -- trim old metrics**
```powershell
$instances = @("PvPArena", "Creative01")
foreach ($inst in $instances) {
    Clear-SEBOldMetrics -InstanceName $inst -BackupRoot "C:\SEBackup\Backups" -KeepCount 200
}
```
