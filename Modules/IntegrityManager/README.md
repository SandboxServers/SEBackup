# IntegrityManager Module

Three-level backup integrity verification system. Validates that backups are complete, uncorrupted, and restorable by checking archive integrity, manifest consistency, and full chain reconstruction.

## Verification Levels

| Level | Function | What It Checks |
|:-----:|----------|----------------|
| 1 | `Test-SEBArchiveIntegrity` | Archive CRC/hash -- is the archive file valid and uncorrupted? |
| 2 | `Test-SEBManifestIntegrity` | Manifest cross-check -- do the archive contents match the manifest? |
| 3 | `Test-SEBChainIntegrity` | Full chain reconstruction -- can the entire chain be reconstructed to produce the expected final state? |

## Exported Functions

### Test-SEBArchiveIntegrity

**Level 1:** Tests whether an archive file is structurally valid by running the compression engine's built-in integrity test.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| ArchivePath | string | Yes | -- | The archive file to verify. |
| Session | PSSession | No | -- | If provided, the test runs on the remote node. |

**Output:** `PSCustomObject` with `Valid` (bool), `ArchivePath` (string), `ErrorMessage` (string).

```powershell
$l1 = Test-SEBArchiveIntegrity -ArchivePath "C:\Backups\PvPArena\full\PvPArena_FULL_20260227.7z"
if (-not $l1.Valid) { Write-Error "Archive corrupted: $($l1.ErrorMessage)" }
```

### Test-SEBManifestIntegrity

**Level 2:** Cross-references a manifest file against an archive to verify that all files listed in the manifest are present in the archive and that file counts match.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| ManifestPath | string | Yes | -- | Path to the manifest JSON file. |
| ArchivePath | string | Yes | -- | Path to the corresponding archive. |
| Session | PSSession | No | -- | If provided, checks run on the remote node. |

**Output:** `PSCustomObject` with `Valid` (bool), `ManifestFileCount` (int), `ArchiveFileCount` (int), `MissingFromArchive` (string[]), `ExtraInArchive` (string[]), `ErrorMessage` (string).

```powershell
$l2 = Test-SEBManifestIntegrity -ManifestPath $manifestPath -ArchivePath $archivePath
if ($l2.MissingFromArchive.Count -gt 0) {
    Write-Warning "Missing files: $($l2.MissingFromArchive -join ', ')"
}
```

### Test-SEBChainIntegrity

**Level 3:** Validates an entire backup chain by extracting all archives in sequence order to a temporary directory and comparing the final state against the target manifest using SHA256 hashes.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| InstanceName | string | Yes | -- | The instance name to validate. |
| ChainId | string | Yes | -- | The chain ID to validate. |
| BackupRoot | string | No | from global config | The root backup directory. |
| TempDir | string | No | auto | Temporary directory for reconstruction. |

**Output:** `PSCustomObject` with `Valid` (bool), `ChainLength` (int), `FilesVerified` (int), `Mismatches` (string[]), `Duration` (TimeSpan), `ErrorMessage` (string).

```powershell
$l3 = Test-SEBChainIntegrity -InstanceName "PvPArena" -ChainId "abc-123-def"
Write-Host "Chain valid: $($l3.Valid), verified $($l3.FilesVerified) files in $($l3.Duration.TotalSeconds)s"
```

### Get-SEBIntegrityReport

Generates a comprehensive integrity report for an instance by running all three verification levels on the most recent backup chain.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| InstanceName | string | Yes | -- | The instance name to report on. |
| BackupRoot | string | No | from global config | The root backup directory. |
| SkipLevel3 | switch | No | `$false` | Skips the Level 3 chain reconstruction (which can be slow). |

**Output:** `PSCustomObject` with `InstanceName` (string), `ReportTime` (datetime), `Level1Results` (PSCustomObject[]), `Level2Results` (PSCustomObject[]), `Level3Result` (PSCustomObject or `$null`), `OverallValid` (bool), `Summary` (string).

```powershell
$report = Get-SEBIntegrityReport -InstanceName "PvPArena"
Write-Host $report.Summary
```

### Write-SEBIntegrityReport

Serializes an integrity report to a JSON file for archival.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Report | PSCustomObject | Yes | -- | The integrity report object from `Get-SEBIntegrityReport`. |
| OutputPath | string | Yes | -- | The file path to write the report to. |

**Output:** None

```powershell
$report = Get-SEBIntegrityReport -InstanceName "PvPArena"
Write-SEBIntegrityReport -Report $report -OutputPath "C:\Reports\PvPArena_integrity.json"
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Compare-ReconstructedState` | Compares the SHA256 hashes of files in a reconstructed directory against the expected manifest. Returns mismatched and missing file lists. |

## Dependencies

- **ManifestManager**: reads and parses manifest files.
- **CompressionManager**: tests archives and extracts files for Level 3 verification.

## Usage Scenarios

**Scenario 1: Post-backup verification (run automatically by BackupEngine)**
```powershell
$l1 = Test-SEBArchiveIntegrity -ArchivePath $archivePath
$l2 = Test-SEBManifestIntegrity -ManifestPath $manifestPath -ArchivePath $archivePath
$passed = $l1.Valid -and $l2.Valid
```

**Scenario 2: Periodic full-chain verification**
```powershell
$report = Get-SEBIntegrityReport -InstanceName "PvPArena"
if (-not $report.OverallValid) {
    Send-SEBNotification -Message "Integrity check FAILED for PvPArena" -Level Error
}
Write-SEBIntegrityReport -Report $report -OutputPath "C:\Reports\$(Get-Date -Format 'yyyyMMdd').json"
```

**Scenario 3: Pre-restore chain validation**
```powershell
$l3 = Test-SEBChainIntegrity -InstanceName "PvPArena" -ChainId $targetChainId
if (-not $l3.Valid) {
    Write-Error "Cannot restore: chain integrity failed with $($l3.Mismatches.Count) mismatches"
}
```
