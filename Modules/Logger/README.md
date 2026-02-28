# Logger Module

Thread-safe, daily-rotating structured logging for the SEBackup system. All other modules depend on Logger for diagnostic output.

## Exported Functions

### Write-SEBLog

Writes a structured log entry to the daily log file and optionally to the console.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Message | string | Yes | -- | The log message text. |
| Level | string | No | `INFO` | Log level: `DEBUG`, `INFO`, `WARN`, or `ERROR`. |
| Context | string | No | current context | A context prefix for the log entry (e.g., instance name). |
| NoConsole | switch | No | `$false` | Suppresses console output; writes only to the log file. |

**Output:** None

```powershell
Write-SEBLog -Message "Backup started for PvPArena" -Level INFO -Context "PvPArena"
Write-SEBLog -Message "Disk space low on node" -Level WARN
Write-SEBLog -Message "Detailed trace info" -Level DEBUG -NoConsole
```

### Get-SEBLogPath

Returns the full path to today's log file.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Date | datetime | No | today | The date for which to return the log file path. |

**Output:** `System.String` -- path like `Logs/SEBackup_2026-02-27.log`

```powershell
$logFile = Get-SEBLogPath
$logFile = Get-SEBLogPath -Date (Get-Date).AddDays(-1)
```

### Get-SEBLogEntries

Reads and parses structured log entries from one or more log files with optional filtering.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Date | datetime | No | today | The date of the log file to read. |
| Level | string | No | all | Filter by log level (`DEBUG`, `INFO`, `WARN`, `ERROR`). |
| Context | string | No | all | Filter by context prefix. |
| Last | int | No | `100` | Maximum number of entries to return (most recent first). |

**Output:** `PSCustomObject[]` -- array of parsed log entries with `Timestamp`, `Level`, `Context`, `Message` properties.

```powershell
$entries = Get-SEBLogEntries -Level ERROR -Last 20
$entries = Get-SEBLogEntries -Context "PvPArena" -Date (Get-Date).AddDays(-1)
```

### Start-SEBLogContext

Sets a context prefix that is automatically prepended to all subsequent log entries until `Stop-SEBLogContext` is called.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Context | string | Yes | -- | The context string to prepend to log messages. |

**Output:** None

```powershell
Start-SEBLogContext -Context "BackupJob:PvPArena"
Write-SEBLog -Message "Starting VSS snapshot"  # Logged as [BackupJob:PvPArena] Starting VSS snapshot
```

### Stop-SEBLogContext

Clears the current log context prefix set by `Start-SEBLogContext`.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| -- | -- | -- | -- | No parameters. |

**Output:** None

```powershell
Stop-SEBLogContext
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Format-LogLine` | Formats a structured log line with timestamp, level, context, and message. |
| `Invoke-LogRotation` | Checks log file age and rotates/cleans up old log files based on configured retention. |

## Module-Scoped Variables

| Variable | Purpose |
|----------|---------|
| `$script:SEBLogRoot` | Root directory for log files (defaults to `Logs/` under project root). |
| `$script:SEBLogContext` | Current context prefix string, set by `Start-SEBLogContext`. |
| `$script:LastRotationCheck` | Timestamp of last rotation check to avoid checking on every write. |
| `$script:LogMutex` | Named mutex for thread-safe file writes. |

## Dependencies

None. Logger is the foundational module and has no dependencies on other SEBackup modules.

## Configuration

Logger reads settings from the `[logging]` section of `global.toml`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `log_level` | string | `INFO` | Minimum log level to record. |
| `log_retention_days` | int | `30` | Days to keep old log files before rotation deletes them. |
| `log_root` | string | `Logs/` | Directory where log files are stored. |

## Usage Scenarios

**Scenario 1: Tracking a backup operation**
```powershell
Start-SEBLogContext -Context "Backup:PvPArena"
Write-SEBLog -Message "Starting backup workflow" -Level INFO
# ... backup steps ...
Write-SEBLog -Message "Backup completed in 45.2s" -Level INFO
Stop-SEBLogContext
```

**Scenario 2: Reviewing recent errors**
```powershell
$errors = Get-SEBLogEntries -Level ERROR -Last 50
$errors | Format-Table Timestamp, Context, Message
```

**Scenario 3: Checking yesterday's logs for a specific instance**
```powershell
$entries = Get-SEBLogEntries -Date (Get-Date).AddDays(-1) -Context "Creative01"
$entries | Where-Object { $_.Level -eq 'WARN' -or $_.Level -eq 'ERROR' }
```
