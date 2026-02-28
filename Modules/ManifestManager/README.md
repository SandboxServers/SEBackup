# ManifestManager Module

SHA256 file manifest generation, comparison, chain traversal, and persistence. Manifests are JSON files that record the hash, size, and modification time of every file in a world save, enabling incremental backup detection and integrity verification.

## Exported Functions

### New-SEBManifest

Generates a new manifest by scanning all files in a source directory, computing SHA256 hashes, and recording file metadata. For incremental backups, inherits the chain ID and increments the chain sequence from the previous manifest.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| SourcePath | string | Yes | -- | The directory to scan (typically the VSS shadow copy mount). |
| PreviousManifest | hashtable | No | -- | The previous manifest for chain linking. If omitted, a new chain is started (full backup). |
| Session | PSSession | No | -- | If provided, the scan runs on the remote node via Invoke-Command. |

**Output:** `hashtable` -- manifest v2 JSON structure with keys: `version`, `type`, `timestamp`, `chain_id`, `chain_sequence`, `files` (hashtable of relative path -> `{ sha256, size, modified }`), `deleted_files` (array for incrementals).

```powershell
$manifest = New-SEBManifest -SourcePath "C:\VSS_Mount\Saves\PvPWorld" -Session $session
$manifest = New-SEBManifest -SourcePath $vssPath -PreviousManifest $lastManifest -Session $session
```

### Compare-SEBManifest

Compares two manifests and returns the diff: added, modified, deleted, and unchanged files.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| CurrentManifest | hashtable | Yes | -- | The new (current) manifest. |
| PreviousManifest | hashtable | Yes | -- | The old (baseline) manifest to compare against. |

**Output:** `PSCustomObject` with `Added` (string[]), `Modified` (string[]), `Deleted` (string[]), `Unchanged` (string[]), `AddedCount`, `ModifiedCount`, `DeletedCount`, `UnchangedCount`, `TotalChanges` (int).

```powershell
$diff = Compare-SEBManifest -CurrentManifest $newManifest -PreviousManifest $oldManifest
Write-Host "Changed: $($diff.AddedCount) added, $($diff.ModifiedCount) modified, $($diff.DeletedCount) deleted"
```

### Get-SEBManifestChain

Loads the full chain of manifests from the initial full backup (sequence 0) through the specified target manifest, following chain IDs.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| ManifestDir | string | Yes | -- | The directory containing manifest JSON files. |
| ChainId | string | Yes | -- | The chain ID to follow. |
| TargetSequence | int | No | latest | The maximum chain sequence to include. |

**Output:** `hashtable[]` -- ordered array of manifest hashtables from sequence 0 to the target.

```powershell
$chain = Get-SEBManifestChain -ManifestDir $manifestDir -ChainId "abc-123" -TargetSequence 5
```

### Read-SEBManifest

Reads and parses a manifest JSON file from disk.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Path | string | Yes | -- | The full path to the manifest JSON file. |

**Output:** `hashtable` -- the parsed manifest.

```powershell
$manifest = Read-SEBManifest -Path "C:\SEBackup\Backups\PvPArena\manifests\PvPArena_FULL_20260227.json"
```

### Write-SEBManifest

Serializes a manifest hashtable to a JSON file on disk.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Manifest | hashtable | Yes | -- | The manifest to write. |
| Path | string | Yes | -- | The destination file path. |

**Output:** None

```powershell
Write-SEBManifest -Manifest $manifest -Path "C:\SEBackup\Backups\PvPArena\manifests\PvPArena_INC_20260227.json"
```

### Get-SEBLatestManifest

Finds the most recent manifest file for an instance by scanning the manifest directory and sorting by filename (which contains the timestamp).

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| ManifestDir | string | Yes | -- | The directory containing manifest JSON files. |
| Type | string | No | any | Filter by type: `full` or `incremental`. |

**Output:** `hashtable` -- the latest manifest, or `$null` if none found.

```powershell
$latest = Get-SEBLatestManifest -ManifestDir $manifestDir
$latestFull = Get-SEBLatestManifest -ManifestDir $manifestDir -Type "full"
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Get-SEBFileHash` | Computes the SHA256 hash of a file. Thin wrapper around `Get-FileHash` for consistent error handling. |
| `Test-SEBManifestSchema` | Validates that a manifest hashtable conforms to the v2 schema (required keys, types, structure). |

## Manifest v2 JSON Schema

```json
{
    "version": 2,
    "type": "full|incremental",
    "timestamp": "2026-02-27T10:30:00.0000000Z",
    "chain_id": "guid-string",
    "chain_sequence": 0,
    "files": {
        "relative/path/to/file.sbc": {
            "sha256": "abcdef1234...",
            "size": 12345,
            "modified": "2026-02-27T10:00:00.0000000Z"
        }
    },
    "deleted_files": ["relative/path/to/removed.vx2"]
}
```

## Dependencies

None (uses built-in `Get-FileHash`, `ConvertFrom-Json`, `ConvertTo-Json`).

## Usage Scenarios

**Scenario 1: Full backup manifest generation**
```powershell
$manifest = New-SEBManifest -SourcePath $vssMountPath -Session $session
# chain_id is a new GUID, chain_sequence is 0, type is "full"
Write-SEBManifest -Manifest $manifest -Path $manifestFilePath
```

**Scenario 2: Incremental backup with diff comparison**
```powershell
$previousManifest = Get-SEBLatestManifest -ManifestDir $manifestDir
$currentManifest = New-SEBManifest -SourcePath $vssMountPath -PreviousManifest $previousManifest -Session $session
$diff = Compare-SEBManifest -CurrentManifest $currentManifest -PreviousManifest $previousManifest
# $diff.Added and $diff.Modified contain the files to archive
```

**Scenario 3: Walking a backup chain for restore**
```powershell
$chain = Get-SEBManifestChain -ManifestDir $manifestDir -ChainId $targetManifest.chain_id
foreach ($m in $chain) {
    Write-Host "Sequence $($m.chain_sequence): $($m.type), $($m.files.Count) files"
}
```
