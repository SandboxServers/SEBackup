# SchedulerManager Module

Windows Task Scheduler integration for automated SEBackup operations. Provides registration, removal, status querying, and live updating of scheduled backup tasks without requiring manual Task Scheduler configuration.

## Exported Functions

### Register-SEBScheduledTask

Registers a Windows Task Scheduler task that runs `Invoke-Backup.ps1 -All` on a repeating interval.

Task configuration:
- Runs under the current user's identity with highest privileges
- Runs whether the user is logged on or not (`S4U` logon type)
- Execution time limit: 4 hours
- Runs on battery power
- Start when available (catches up missed runs)

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| TaskName | string | No (Position 0) | `SEBackup-Scheduled` | The task name in Windows Task Scheduler. |
| GlobalConfig | hashtable | No | from `Config/global.toml` | The global configuration with `[schedule]` settings. |

**Output:** `Microsoft.Management.Infrastructure.CimInstance` -- the registered scheduled task object.

```powershell
Register-SEBScheduledTask
Register-SEBScheduledTask -TaskName "MyBackupTask"
$config = Get-SEBGlobalConfig
Register-SEBScheduledTask -GlobalConfig $config
```

### Unregister-SEBScheduledTask

Removes the SEBackup scheduled task from Windows Task Scheduler.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| TaskName | string | No (Position 0) | `SEBackup-Scheduled` | The task name to remove. |
| Force | switch | No | `$false` | Suppresses the confirmation prompt. |

**Output:** None

```powershell
Unregister-SEBScheduledTask
Unregister-SEBScheduledTask -Force
Unregister-SEBScheduledTask -TaskName "MyBackupTask" -Force
```

### Get-SEBScheduleStatus

Returns the current status of the SEBackup scheduled task.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| TaskName | string | No (Position 0) | `SEBackup-Scheduled` | The task name to query. |

**Output:** `PSCustomObject` with:

| Property | Type | Description |
|----------|------|-------------|
| `TaskName` | string | The task name queried. |
| `Exists` | bool | Whether the task exists in Task Scheduler. |
| `State` | string | Current state: `Ready`, `Running`, `Disabled`, `Queued`, `Unknown`, or `$null`. |
| `NextRunTime` | datetime | Next scheduled run time, or `$null`. |
| `LastRunTime` | datetime | Last time the task ran, or `$null`. |
| `LastResult` | int | Exit code from the last run, or `$null`. |
| `TriggerInterval` | TimeSpan | Configured repetition interval, or `$null`. |

```powershell
$status = Get-SEBScheduleStatus
Write-Host "State: $($status.State)"
Write-Host "Next run: $($status.NextRunTime)"
Write-Host "Last result: $($status.LastResult)"
```

### Update-SEBSchedule

Modifies settings on an existing scheduled task without recreating it. Only the parameters you specify are changed; all others remain untouched.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| TaskName | string | No (Position 0) | `SEBackup-Scheduled` | The task name to update. |
| IntervalHours | int | No | unchanged | New repetition interval in hours (1-168). |
| StartTime | string | No | unchanged | New trigger start time in `HH:mm` 24-hour format. |
| Enabled | bool | No | unchanged | `$true` to enable, `$false` to disable. |

**Output:** `Microsoft.Management.Infrastructure.CimInstance` -- the updated scheduled task object.

```powershell
Update-SEBSchedule -IntervalHours 4
Update-SEBSchedule -StartTime "03:30"
Update-SEBSchedule -Enabled $false
Update-SEBSchedule -IntervalHours 8 -StartTime "01:00" -Enabled $true
Update-SEBSchedule -TaskName "MyBackupTask" -IntervalHours 12
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Get-SEBProjectRoot` | Resolves the SEBackup project root directory by navigating up from the module's `Private/` directory. Used to locate `Scripts/Invoke-Backup.ps1` for the scheduled task action. |

## Dependencies

- **ScheduledTasks** PowerShell module (built into Windows)
- **ConfigManager** (optional): `Get-SEBGlobalConfig` for loading schedule settings when `GlobalConfig` is not provided

## Configuration

Schedule settings come from the `[schedule]` section of `global.toml`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `interval_hours` | int | `6` | Hours between backup runs. |
| `start_time` | string | `02:00` | Initial trigger time in `HH:mm` 24-hour format. |
| `full_backup_interval_hours` | int | -- | Hours between forced full backups (used by BackupEngine, not directly by SchedulerManager). |
| `max_incremental_chain_length` | int | -- | Max incrementals before full (used by BackupEngine). |

## Requirements

- **Administrator privileges** required to register tasks with highest privileges and `S4U` logon type.
- **PowerShell 7** must be installed (the task action runs `pwsh.exe`).

## Usage Scenarios

**Scenario 1: Set up automated backups**
```powershell
# Register the default task (every 6 hours starting at 2 AM)
Register-SEBScheduledTask

# Verify it was created
$status = Get-SEBScheduleStatus
Write-Host "Task registered. Next run: $($status.NextRunTime)"
```

**Scenario 2: Change backup frequency**
```powershell
# Switch from every 6 hours to every 4 hours
Update-SEBSchedule -IntervalHours 4
```

**Scenario 3: Temporarily disable and re-enable**
```powershell
# Disable during server maintenance
Update-SEBSchedule -Enabled $false

# Re-enable when maintenance is done
Update-SEBSchedule -Enabled $true
```
