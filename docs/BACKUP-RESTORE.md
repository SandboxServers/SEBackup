# Backup & Restore Guide

This document explains how SEBackup backups work, how to restore from a backup, and how to verify backup integrity.

## How Backups Work

### The Backup Pipeline

When you run a backup (either manually or via the scheduler), SEBackup performs these steps for each Torch instance:

1. **Load check** -- If load awareness is enabled, SEBackup queries CPU, memory, and sim speed on the compute node. If the server is too busy, the backup is deferred with exponential backoff until conditions improve or the timeout expires.

2. **VRage API world save** -- SEBackup sends a save command to the Torch server via the VRage Remote API. This tells the game to flush all in-memory world data to disk. The server does NOT need to stop -- players can keep playing.

3. **VSS shadow copy** -- A Volume Shadow Copy (VSS snapshot) is created on the compute node. This captures a point-in-time, crash-consistent copy of the game files. The snapshot is read-only and does not affect the running server.

4. **Manifest generation** -- SEBackup walks the VSS snapshot and generates a SHA256 hash manifest of every file. This manifest is a JSON file listing every file path, its hash, size, and modification time.

5. **Manifest comparison** -- The new manifest is compared against the previous backup's manifest. Files are classified as Added, Modified, Deleted, or Unchanged.

6. **Archive compression** -- Only changed files (Added + Modified) are compressed into an archive. For full backups, all files are included. The archive is created on the compute node in the staging directory.

7. **VSS cleanup** -- The shadow copy is removed from the compute node. This always happens, even if previous steps failed (guaranteed via try/finally).

8. **File transfer** -- The compressed archive and manifest are transferred from the compute node's staging directory to the C&C server via SMB share. Bandwidth throttling is applied if configured.

9. **NAS offload** -- If a NAS path is configured, the archive is copied from the C&C to the NAS.

10. **Integrity verification** -- The archive's integrity is verified on the C&C (CRC check, manifest cross-reference).

11. **Retention cleanup** -- Old backups that exceed the retention policy are pruned.

12. **Notification** -- A Discord notification (or other configured method) is sent with the result.

### Full vs. Incremental Backups

SEBackup uses **incremental backup chains** to minimize storage and transfer time.

**Full backup:**
- Contains ALL files from the Torch instance
- Creates a new chain (previous incrementals are no longer needed for this chain)
- Larger archive size, longer transfer time
- Triggered automatically per the `full_backup_interval_hours` setting (default: weekly) or when the incremental chain length exceeds `max_incremental_chain_length`

**Incremental backup:**
- Contains only files that **changed** since the previous backup (full or incremental)
- Much smaller archive size (typically 80-95% smaller than a full)
- Faster to create and transfer
- Depends on the parent backup -- you need the full backup plus all incrementals in the chain to perform a complete restore

### Backup Directory Structure

Backups are organized on the C&C server like this:

```
C:\SEBackup\Backups\
  GamePC01\
    PvPArena\
      manifests\
        20260227_020000_full.json
        20260227_080000_incr.json
        20260227_140000_incr.json
        20260227_200000_incr.json
      archives\
        20260227_020000_full.7z
        20260227_080000_incr.7z
        20260227_140000_incr.7z
        20260227_200000_incr.7z
    Survival\
      manifests\
        ...
      archives\
        ...
  GamePC02\
    ...
```

Each backup file is named with a timestamp and type: `YYYYMMDD_HHmmss_full` or `YYYYMMDD_HHmmss_incr`.

### Manifest Files

Manifest files are JSON documents that contain:

```json
{
  "instance": "PvPArena",
  "node": "GamePC01",
  "timestamp": "2026-02-27T02:00:00Z",
  "type": "full",
  "parent_manifest": null,
  "files": {
    "Saves\\PvPWorld\\SANDBOX_0_0_0_.sbs": {
      "sha256": "a1b2c3d4...",
      "size": 52428800,
      "last_modified": "2026-02-27T01:59:30Z"
    },
    "Saves\\PvPWorld\\SANDBOX_0_0_0_.sbc": {
      "sha256": "e5f6a7b8...",
      "size": 1048576,
      "last_modified": "2026-02-27T01:59:30Z"
    }
  }
}
```

Incremental manifests include a `parent_manifest` field pointing to the previous manifest in the chain.

## How to Restore

### Restoring from the Command Line

To restore a Torch instance to a specific point in time:

```powershell
Import-Module .\SEBackup.psd1

# List available backups for an instance
Get-SEBBackupHistory -NodeName "GamePC01" -InstanceName "PvPArena"
```

This shows a table of all available backups with their timestamps, types (full/incremental), and sizes.

To restore:

```powershell
# Restore to the latest backup
.\Scripts\Invoke-Restore.ps1 -NodeName "GamePC01" -InstanceName "PvPArena" -Latest

# Restore to a specific backup by timestamp
.\Scripts\Invoke-Restore.ps1 -NodeName "GamePC01" -InstanceName "PvPArena" -Timestamp "2026-02-27T02:00:00"

# Restore to a local directory (for inspection, without overwriting the live server)
.\Scripts\Invoke-Restore.ps1 -NodeName "GamePC01" -InstanceName "PvPArena" -Latest -OutputPath "C:\Temp\Restore"
```

### What Restore Does

1. **Identifies the chain** -- For an incremental backup, SEBackup identifies the full backup at the start of the chain and all incrementals up to the requested point.

2. **Extracts the full backup** -- The base full archive is extracted to a temporary directory.

3. **Applies incrementals** -- Each incremental archive is extracted on top, overwriting modified files and adding new ones. Deleted files (tracked in the manifest) are removed.

4. **Verifies integrity** -- The restored files are hashed and compared against the manifest to ensure nothing is corrupted.

5. **Deploys to the node** -- If restoring to the live server (not a local directory):
   - The Torch server is optionally stopped
   - The restored files are copied to the instance's world path on the compute node
   - The Torch server is optionally restarted

> **IMPORTANT:** Restoring to a live server will overwrite the current world data. Make sure you have a current backup before restoring, or use `-OutputPath` to restore to a temporary location first.

### Restoring from the GUI

(The WPF dashboard GUI is under development. When completed, you will be able to browse backup history, preview changed files, and perform restores from a visual interface.)

## Integrity Verification

SEBackup provides three levels of backup verification:

### Level 1: Archive Integrity

Checks that the archive file itself is not corrupted (CRC/hash validation):

```powershell
Test-SEBArchiveIntegrity -ArchivePath "C:\SEBackup\Backups\GamePC01\PvPArena\archives\20260227_020000_full.7z"
```

### Level 2: Manifest Integrity

Cross-references the archive contents against the manifest to ensure all expected files are present with correct hashes:

```powershell
Test-SEBManifestIntegrity -ManifestPath "C:\SEBackup\Backups\GamePC01\PvPArena\manifests\20260227_020000_full.json"
```

### Level 3: Chain Integrity

Validates an entire incremental chain from the full backup to the latest incremental, ensuring the chain is complete and all links are valid:

```powershell
Test-SEBChainIntegrity -NodeName "GamePC01" -InstanceName "PvPArena"
```

### Generating an Integrity Report

To get a comprehensive report covering all backups:

```powershell
$report = Get-SEBIntegrityReport -NodeName "GamePC01" -InstanceName "PvPArena"
Write-SEBIntegrityReport -Report $report -OutputPath "C:\Temp\integrity_report.html"
```

## Viewing What Changed

You can compare any two manifests to see exactly which files were added, modified, or deleted:

```powershell
$current = Read-SEBManifest -Path "...\20260227_080000_incr.json"
$previous = Read-SEBManifest -Path "...\20260227_020000_full.json"
$diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous

Write-Host "Added:     $($diff.AddedCount)"
Write-Host "Modified:  $($diff.ModifiedCount)"
Write-Host "Deleted:   $($diff.DeletedCount)"
Write-Host "Unchanged: $($diff.UnchangedCount)"

# List the specific files that changed:
$diff.Added
$diff.Modified
$diff.Deleted
```

## Tips

- **Backup before restoring.** Always make sure you have a current backup before overwriting live server data with a restore.
- **Test restores periodically.** Use `-OutputPath` to restore to a temporary directory and verify the data looks correct.
- **Monitor your disk space.** Backups accumulate over time. Keep an eye on the retention settings.
- **Check the logs.** Detailed backup/restore logs are in `Logs/SEBackup_YYYY-MM-DD.log`.
