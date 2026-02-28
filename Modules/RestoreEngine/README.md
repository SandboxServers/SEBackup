# RestoreEngine Module

Point-in-time restore reconstruction for the SEBackup system. Reconstructs world state from full + incremental backup chains, handles safety backups, provides atomic deployment with rollback capability, and supports undo via pre-restore directory preservation.

## Exported Functions

### Invoke-SEBRestore

Orchestrates a complete restore workflow for a Space Engineers Torch instance.

**Workflow (11 steps):**
1. Load configs, create PSSession to node
2. Confirmation prompt (unless `-Force`)
3. Validate the restore chain (all manifests and archives exist, integrity passes)
4. Safety backup of current state (unless `-SkipSafetyBackup`)
5. Stop Torch server (service mode or console/API shutdown)
6. Reconstruct world state in temp directory on node:
   - Extract full backup archive
   - For each incremental in chain order: extract (overwrite), process deleted files
7. Verify reconstructed state against target manifest (SHA256 per file)
8. Deploy: rename current world dir to `{name}_prerestore_{timestamp}`, copy reconstructed files
9. Start Torch server, wait for VRage API to respond
10. Send restore notification
11. Clean up temp directory

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The compute node hosting the Torch instance. |
| InstanceName | string | Yes | -- | The instance name to restore. |
| RestorePoint | string | Yes | -- | The manifest filename identifying the target restore point (e.g., `PvPArena_INC_20260227_120000.json`). |
| SkipSafetyBackup | switch | No | `$false` | Skips the safety full backup of current state. |
| Force | switch | No | `$false` | Skips the confirmation prompt (required for non-interactive use). |

**Output:** `PSCustomObject` with properties:

| Property | Type | Description |
|----------|------|-------------|
| `Success` | bool | Whether the restore completed successfully. |
| `RestorePoint` | string | The manifest filename used. |
| `Duration` | TimeSpan | Total operation duration. |
| `SafetyBackupPath` | string | Path to the safety backup archive, or `$null`. |
| `UndoAvailable` | bool | Whether the pre-restore directory exists for `Undo-SEBRestore`. |
| `ErrorMessage` | string | Error message if failed, or `$null`. |
| `Warnings` | string[] | Non-fatal warnings. |

```powershell
$result = Invoke-SEBRestore -NodeName "GameServer01" -InstanceName "PvPArena" `
    -RestorePoint "PvPArena_FULL_20260227_100000.json" -Force
if ($result.Success) {
    Write-Host "Restored successfully. Undo available: $($result.UndoAvailable)"
}
```

### Get-SEBRestorePoints

Returns all available restore points for an instance, with chain validity information.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| InstanceName | string | Yes (Position 0) | -- | The instance name. |
| BackupRoot | string | No | from global config | The C&C backup root directory. |

**Output:** `PSCustomObject[]` -- array of restore points with:

| Property | Type | Description |
|----------|------|-------------|
| `ManifestFile` | string | Full path to the manifest. |
| `Timestamp` | string | ISO 8601 timestamp of the backup. |
| `Type` | string | `full` or `incremental`. |
| `ChainId` | string | The chain GUID. |
| `ChainSequence` | int | Position in the chain (0 = full). |
| `ArchiveFile` | string | Path to the archive, or `$null` if missing. |
| `SizeBytes` | long | Archive file size. |
| `ChainValid` | bool | Whether the full chain from sequence 0 to this point is complete. |

```powershell
$points = Get-SEBRestorePoints -InstanceName "PvPArena"
$validPoints = $points | Where-Object { $_.ChainValid }
$validPoints | Format-Table Timestamp, Type, ChainSequence, SizeBytes, ChainValid
```

### Test-SEBRestoreChain

Validates that a restore to a specific point is possible by checking all chain members, archives, and integrity.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| InstanceName | string | Yes | -- | The instance name. |
| RestorePoint | string | Yes | -- | The target restore point manifest filename. |
| BackupRoot | string | No | from global config | The C&C backup root directory. |

**Checks performed:**
1. Target manifest exists and is parseable
2. All manifests from sequence 0 to target exist
3. All corresponding archive files exist
4. Level 1 integrity (archive CRC) passes on each
5. Level 2 integrity (manifest cross-check) passes on each

**Output:** `PSCustomObject` with `Valid` (bool), `ChainLength` (int), `ChainManifests` (string[]), `ChainArchives` (string[]), `Errors` (string[]), `Warnings` (string[]).

```powershell
$validation = Test-SEBRestoreChain -InstanceName "PvPArena" `
    -RestorePoint "PvPArena_INC_20260227_120000.json"
if ($validation.Valid) {
    Write-Host "Chain valid: $($validation.ChainLength) archives"
} else {
    $validation.Errors | ForEach-Object { Write-Error $_ }
}
```

### Undo-SEBRestore

Reverts the most recent restore by finding the `_prerestore_` directory and swapping it back.

**Undo workflow:**
1. Find the most recent `{WorldName}_prerestore_{timestamp}` directory on the node
2. Stop Torch server
3. Rename current world dir to `{WorldName}_postrestore_{timestamp}`
4. Rename `_prerestore_` directory back to the original world name
5. Start Torch server

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The compute node name. |
| InstanceName | string | Yes | -- | The instance name. |

**Output:** `PSCustomObject` with `Success` (bool), `PreRestorePath` (string), `PostRestorePath` (string), `ErrorMessage` (string).

```powershell
$undo = Undo-SEBRestore -NodeName "GameServer01" -InstanceName "PvPArena"
if ($undo.Success) {
    Write-Host "Undo complete. Pre-restore state restored."
}
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Deploy-SEBRestoredFiles` | Handles the atomic deployment: renames current world dir to `_prerestore_{timestamp}`, copies reconstructed files via robocopy, verifies file count and Sandbox.sbc presence. Attempts rollback on failure. |
| `Start-SEBTorchServer` | Starts Torch on the remote node. Service mode: uses `Start-Service`. Console mode: warns for manual start. Polls VRage API until responsive or timeout. Returns `Started`, `Method`, `APIResponding`, `ErrorMessage`. |
| `Stop-SEBTorchServer` | Stops Torch on the remote node. Service mode: uses `Stop-Service`. Console mode: sends shutdown via VRage API and waits for API to become unreachable. Returns `Stopped`, `Method`, `ErrorMessage`. |

## Dependencies

- **ConfigManager**: loading global, node, and instance configs
- **RemoteManager**: PSSession creation and remote execution
- **BackupEngine**: `Invoke-SEBBackup` for safety backup before restore
- **IntegrityManager**: Level 1 + Level 2 integrity checks on chain archives
- **NetworkThrottle**: transferring archives from C&C to node for extraction
- **NotificationManager**: sending restore notifications
- **VRageAPI**: server stop/start verification via API ping

## Usage Scenarios

**Scenario 1: Browse and select a restore point**
```powershell
$points = Get-SEBRestorePoints -InstanceName "PvPArena"
$validPoints = $points | Where-Object { $_.ChainValid }
$validPoints | Select-Object Timestamp, Type, ChainSequence | Format-Table

# Pick a restore point
$target = $validPoints[2]
$result = Invoke-SEBRestore -NodeName "GameServer01" -InstanceName "PvPArena" `
    -RestorePoint (Split-Path $target.ManifestFile -Leaf) -Force
```

**Scenario 2: Validate before restoring**
```powershell
$validation = Test-SEBRestoreChain -InstanceName "PvPArena" -RestorePoint "PvPArena_INC_20260227_180000.json"
if (-not $validation.Valid) {
    Write-Error "Cannot restore: $($validation.Errors -join '; ')"
    return
}
Write-Host "Chain is valid ($($validation.ChainLength) archives). Proceeding..."
$result = Invoke-SEBRestore -NodeName "GameServer01" -InstanceName "PvPArena" `
    -RestorePoint "PvPArena_INC_20260227_180000.json" -Force
```

**Scenario 3: Undo a bad restore**
```powershell
# Something went wrong after restore -- revert to pre-restore state
$undo = Undo-SEBRestore -NodeName "GameServer01" -InstanceName "PvPArena"
if ($undo.Success) {
    Write-Host "Reverted to previous state. Server should be running."
} else {
    Write-Error "Undo failed: $($undo.ErrorMessage)"
}
```
