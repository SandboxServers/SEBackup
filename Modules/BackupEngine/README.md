# BackupEngine Module

Full and incremental backup orchestration for the SEBackup system. Coordinates the entire backup workflow from load checks through VRage API save, VSS snapshot, manifest generation, compression, multi-tier distribution, integrity verification, metrics recording, notifications, and retention cleanup.

## Exported Functions

### Invoke-SEBBackup

Orchestrates a complete backup workflow for a single Space Engineers Torch instance. This is the primary backup function.

**Workflow (17 steps):**
1. Load configs, create PSSession to node, read instance TOML
2. Acquire per-instance lock file (prevents concurrent runs)
3. Load awareness check (if enabled, wait for safe load)
4. Determine backup type (full vs incremental)
5. Pre-flight checks (disk space, world exists, VSS, SMB share)
6. Trigger VRage API world save (flush game state to disk)
7. Create VSS shadow copy
8. Generate file manifest from shadow copy
9. Copy files from VSS mount to node staging (full: robocopy; incremental: changed files only)
10. Compress staging directory to archive on the node
11. Transfer archive from SMB share to C&C local storage
12. Copy archive to NAS (optional, warn on failure)
13. Integrity verification (Level 1 + Level 2)
14. Record metrics
15. Send Discord notification
16. Retention cleanup
17. Release lock, clean up staging

**Full vs Incremental Decision:**
- No previous backup -> Full
- Hours since last full >= `full_backup_interval_hours` -> Full
- Chain sequence >= `max_incremental_chain_length` -> Full
- `-ForceFull` specified -> Full
- Otherwise -> Incremental

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The compute node hosting the Torch instance. |
| InstanceName | string | Yes | -- | The instance name to back up. |
| ForceFull | switch | No | `$false` | Forces a full backup regardless of decision logic. |
| SkipLoadCheck | switch | No | `$false` | Skips the load awareness check. |
| SkipNotify | switch | No | `$false` | Skips sending the Discord notification. |

**Output:** `PSCustomObject` with properties:

| Property | Type | Description |
|----------|------|-------------|
| `Success` | bool | Whether the backup completed and passed integrity checks. |
| `InstanceName` | string | The instance name. |
| `NodeName` | string | The compute node name. |
| `BackupType` | string | `full` or `incremental`. |
| `ArchiveFile` | string | Path to the archive on the C&C server. |
| `ArchiveSizeBytes` | long | Archive file size in bytes. |
| `FileCount` | int | Number of files in the manifest. |
| `Duration` | TimeSpan | Total operation duration. |
| `ManifestFile` | string | Path to the manifest JSON on the C&C server. |
| `ChainId` | string | The backup chain GUID. |
| `ChainSequence` | int | Position in the incremental chain (0 = full). |
| `IntegrityPassed` | bool | Whether Level 1 + Level 2 integrity checks passed. |
| `Warnings` | string[] | Any non-fatal warnings encountered. |
| `ErrorMessage` | string | Error message if the backup failed, or `$null`. |

```powershell
$result = Invoke-SEBBackup -NodeName "GameServer01" -InstanceName "PvPArena"
if ($result.Success) {
    Write-Host "Backup OK: $($result.BackupType), $([math]::Round($result.ArchiveSizeBytes / 1MB, 2)) MB"
}

Invoke-SEBBackup -NodeName "GameServer01" -InstanceName "Creative" -ForceFull -SkipLoadCheck
```

### Invoke-SEBBackupAll

Backs up all instances across all configured nodes. Discovers nodes from `Config/nodes/*.toml` and instances from each node via `Get-SEBAllInstanceConfigs`.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| SkipLoadCheck | switch | No | `$false` | Skips load checks for all instances. |
| SkipNotify | switch | No | `$false` | Skips individual Discord notifications. |
| ParallelNodes | switch | No | `$false` | Processes nodes in parallel (instances within each node are still serial). |

**Output:** `PSCustomObject[]` -- array of backup result objects, one per instance.

```powershell
$results = Invoke-SEBBackupAll
$failed = $results | Where-Object { -not $_.Success }
Write-Host "$($results.Count) total, $($failed.Count) failed"

$results = Invoke-SEBBackupAll -ParallelNodes -SkipLoadCheck
```

### Get-SEBBackupHistory

Retrieves the backup history for an instance by reading all manifest files and correlating them with archive files.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| InstanceName | string | Yes (Position 0) | -- | The instance name. |
| Last | int | No | `50` | Maximum entries to return (1-1000). |
| BackupRoot | string | No | from global config | The C&C backup root directory. |

**Output:** `PSCustomObject[]` -- array sorted newest first, with `Timestamp`, `Type`, `ArchiveFile`, `SizeBytes`, `FileCount`, `ChainId`, `ChainSequence`, `IntegrityStatus`, `ManifestFile`.

```powershell
$history = Get-SEBBackupHistory -InstanceName "PvPArena" -Last 10
$history | Format-Table Timestamp, Type, SizeBytes, IntegrityStatus
```

### Remove-SEBExpiredBackups

Implements three-tier retention cleanup for an instance.

| Tier | Storage | Retention Policy |
|:----:|---------|------------------|
| 1 | Node staging | Only latest full kept (handled during backup, not here). |
| 2 | C&C local | Keep most recent `cc_full_count` full backups + their incremental chains. |
| 3 | NAS | Delete backups older than `nas_retention_days`. |

Also cleans up orphaned manifests (manifests without corresponding archives).

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| InstanceName | string | Yes | -- | The instance name. |
| GlobalConfig | hashtable | Yes | -- | The global config with retention and storage settings. |

**Output:** `PSCustomObject` with `RemovedCC` (int), `RemovedNAS` (int), `OrphanedManifestsRemoved` (int), `Errors` (string[]).

```powershell
$config = Get-SEBGlobalConfig
$cleanup = Remove-SEBExpiredBackups -InstanceName "PvPArena" -GlobalConfig $config
Write-Host "Removed: $($cleanup.RemovedCC) from C&C, $($cleanup.RemovedNAS) from NAS"
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Get-SEBBackupType` | Determines whether the next backup should be full or incremental based on configuration thresholds, chain length, and time since last full. Returns a decision object with `Type`, `Reason`, `LastFullManifest`, `LastManifest`, `ChainId`, `ChainSequence`. |
| `New-SEBLockFile` | Creates a JSON lock file at `Data/lockfiles/{InstanceName}.lock` to prevent concurrent backup operations. Automatically breaks stale locks older than `StaleThresholdHours` (default 4). |
| `Remove-SEBLockFile` | Removes the lock file for an instance. Safe to call in `finally` blocks -- never throws. |
| `Test-SEBPreFlight` | Runs pre-flight checks before backup: node staging disk space, C&C disk space, NAS disk space (warning only), world save folder with Sandbox.sbc, and SMB share accessibility. Returns `Passed`, `Failures`, `Warnings`, `DiskSpaceNode`, `DiskSpaceCC`, `DiskSpaceNAS`. |

## Dependencies

This module orchestrates nearly every other module in the system:
- **ConfigManager**: loading global, node, and instance configs
- **CredentialManager**: credential retrieval (via RemoteManager)
- **RemoteManager**: PSSession creation and remote command execution
- **VRageAPI**: triggering world saves before snapshot
- **VSSManager**: creating and managing shadow copies
- **ManifestManager**: manifest generation and comparison
- **CompressionManager**: archive creation
- **IntegrityManager**: Level 1 + Level 2 integrity checks
- **LoadMonitor**: pre-backup load awareness checks
- **NetworkThrottle**: bandwidth-limited archive transfers
- **NotificationManager**: Discord webhook notifications
- **MetricsCollector**: recording backup metrics

## Configuration

BackupEngine uses settings from multiple `global.toml` sections:

| Section | Key | Description |
|---------|-----|-------------|
| `[storage]` | `cc_backup_root` | C&C backup storage directory. |
| `[storage]` | `nas_backup_path` | Optional NAS offsite storage path. |
| `[schedule]` | `full_backup_interval_hours` | Hours between forced full backups. |
| `[schedule]` | `max_incremental_chain_length` | Max incrementals before forcing a full. |
| `[retention]` | `cc_full_count` | Full backups to keep on C&C. |
| `[retention]` | `nas_retention_days` | Days to keep backups on NAS. |
| `[compression]` | `engine`, `level`, `threads` | Compression settings. |
| `[network]` | `method`, `bandwidth_limit_mbps` | Transfer settings. |
| `[load_awareness]` | `enabled`, thresholds | Load check settings. |
| `[notifications]` | `enabled`, `webhook_url` | Notification settings. |

## Usage Scenarios

**Scenario 1: Run a single instance backup**
```powershell
$result = Invoke-SEBBackup -NodeName "GameServer01" -InstanceName "PvPArena"
if (-not $result.Success) {
    Write-Error "Backup failed: $($result.ErrorMessage)"
}
```

**Scenario 2: Back up everything (scheduled task entry point)**
```powershell
$results = Invoke-SEBBackupAll
$failed = @($results | Where-Object { -not $_.Success })
if ($failed.Count -gt 0) {
    Write-Warning "$($failed.Count) backup(s) failed"
    $failed | ForEach-Object { Write-Warning "  $($_.InstanceName): $($_.ErrorMessage)" }
}
```

**Scenario 3: Force a full backup after major server changes**
```powershell
Invoke-SEBBackup -NodeName "GameServer01" -InstanceName "PvPArena" -ForceFull -SkipLoadCheck
```
