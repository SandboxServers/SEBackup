# VSSManager Module

Volume Shadow Copy Service (VSS) lifecycle management for zero-downtime backups. Creates, mounts, and cleans up shadow copies on remote compute nodes via PSRemoting.

## Exported Functions

### New-SEBShadowCopy

Creates a new VSS shadow copy on the specified volume of a remote compute node.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | Yes | -- | An active PSSession to the compute node. |
| VolumeLetter | string | Yes | -- | The drive letter to snapshot (e.g., `C`). |

**Output:** `PSCustomObject` with `ShadowId` (string/GUID), `ShadowPath` (string), `CreatedAt` (datetime), `VolumeLetter` (string).

```powershell
$shadow = New-SEBShadowCopy -Session $session -VolumeLetter "C"
Write-Host "Shadow created: $($shadow.ShadowId) at $($shadow.ShadowPath)"
```

### Remove-SEBShadowCopy

Removes a VSS shadow copy by its shadow ID on a remote compute node.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | Yes | -- | An active PSSession to the compute node. |
| ShadowId | string | Yes | -- | The GUID of the shadow copy to remove. |

**Output:** `System.Boolean` -- `$true` if successfully removed.

```powershell
Remove-SEBShadowCopy -Session $session -ShadowId $shadow.ShadowId
```

### Mount-SEBShadowCopy

Mounts a VSS shadow copy to a directory path on the remote node, making the snapshot accessible as a regular folder.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | Yes | -- | An active PSSession to the compute node. |
| ShadowPath | string | Yes | -- | The device path of the shadow copy. |
| MountPoint | string | No | auto-generated | The local directory to mount the shadow copy to. |

**Output:** `System.String` -- the mount point path.

```powershell
$mountPath = Mount-SEBShadowCopy -Session $session -ShadowPath $shadow.ShadowPath
```

### Dismount-SEBShadowCopy

Unmounts a previously mounted VSS shadow copy.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | Yes | -- | An active PSSession to the compute node. |
| MountPoint | string | Yes | -- | The directory where the shadow copy is mounted. |

**Output:** `System.Boolean` -- `$true` if successfully dismounted.

```powershell
Dismount-SEBShadowCopy -Session $session -MountPoint $mountPath
```

### Invoke-SEBWithShadowCopy

High-level wrapper that manages the full VSS lifecycle (create, mount, execute, dismount, remove) automatically with `try/finally` cleanup. This is the preferred way to work with shadow copies.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | Yes | -- | An active PSSession to the compute node. |
| VolumeLetter | string | Yes | -- | The drive letter to snapshot. |
| ScriptBlock | scriptblock | Yes | -- | Code to execute while the shadow copy is mounted. Receives `$ShadowMountPath` as a parameter. |

**Output:** The return value of the provided script block.

```powershell
Invoke-SEBWithShadowCopy -Session $session -VolumeLetter "C" -ScriptBlock {
    param($ShadowMountPath)
    Get-ChildItem -Path (Join-Path $ShadowMountPath "GameData\Saves") -Recurse -File
}
```

### Clear-SEBOrphanShadowCopies

Finds and removes orphaned VSS shadow copies that were not properly cleaned up (e.g., due to a crash or interrupted backup).

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | Yes | -- | An active PSSession to the compute node. |
| MaxAgeHours | int | No | `4` | Shadow copies older than this threshold are considered orphans. |

**Output:** `PSCustomObject` with `RemovedCount` (int), `Errors` (string[]).

```powershell
$cleanup = Clear-SEBOrphanShadowCopies -Session $session -MaxAgeHours 2
Write-Host "Removed $($cleanup.RemovedCount) orphaned shadow copies."
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Test-SEBVSSService` | Checks whether the Volume Shadow Copy service is running on the remote node. Returns `$true` if running, `$false` otherwise. |

## Dependencies

- **RemoteManager**: All VSS operations execute on remote nodes via PSSessions.

## Important Rules

- **ALWAYS** use `try/finally` when working with shadow copies directly.
- **ALWAYS** clean up shadow copies in the `finally` block, even if the operation fails.
- **Prefer `Invoke-SEBWithShadowCopy`** -- it handles the entire lifecycle automatically.
- VSS operations run on compute nodes, not on the C&C server.

## Usage Scenarios

**Scenario 1: Safe backup with automatic cleanup (recommended)**
```powershell
Invoke-SEBWithShadowCopy -Session $session -VolumeLetter "D" -ScriptBlock {
    param($ShadowMountPath)
    $worldPath = Join-Path $ShadowMountPath "TorchServer\Saves\PvPWorld"
    # Generate manifest, copy files, etc.
}
# Shadow copy is automatically cleaned up regardless of success/failure
```

**Scenario 2: Manual shadow copy lifecycle**
```powershell
$shadow = New-SEBShadowCopy -Session $session -VolumeLetter "C"
try {
    $mountPath = Mount-SEBShadowCopy -Session $session -ShadowPath $shadow.ShadowPath
    # Work with files at $mountPath...
}
finally {
    Dismount-SEBShadowCopy -Session $session -MountPoint $mountPath
    Remove-SEBShadowCopy -Session $session -ShadowId $shadow.ShadowId
}
```

**Scenario 3: Cleaning up after a crash**
```powershell
$result = Clear-SEBOrphanShadowCopies -Session $session -MaxAgeHours 1
if ($result.RemovedCount -gt 0) {
    Write-Host "Cleaned up $($result.RemovedCount) orphaned shadows."
}
```
