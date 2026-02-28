# CompressionManager Module

Archive compression and extraction abstraction layer. Supports two engines: 7-Zip (faster, better compression ratios) and .NET `System.IO.Compression` (built-in fallback). Automatically detects which engine is available.

## Exported Functions

### Compress-SEBArchive

Compresses a source directory into an archive file using the configured compression engine.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| SourcePath | string | Yes | -- | The directory to compress. |
| Destination | string | Yes | -- | The output archive file path (`.zip` or `.7z`). |
| Session | PSSession | No | -- | If provided, compression runs on the remote node. |
| Config | hashtable | No | -- | Compression config with `engine`, `level`, `threads` keys. |

**Output:** `PSCustomObject` with `Success` (bool), `ArchivePath` (string), `SizeBytes` (long), `Duration` (TimeSpan), `Engine` (string), `ErrorMessage` (string).

```powershell
Compress-SEBArchive -SourcePath "C:\staging\PvPArena" -Destination "C:\staging\PvPArena_FULL.7z" `
    -Session $session -Config $globalConfig.compression
```

### Expand-SEBArchive

Extracts an archive file to a destination directory.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| ArchivePath | string | Yes | -- | The archive file to extract. |
| Destination | string | Yes | -- | The directory to extract into. |
| Session | PSSession | No | -- | If provided, extraction runs on the remote node. |
| Overwrite | switch | No | `$false` | Overwrite existing files at the destination. |

**Output:** `PSCustomObject` with `Success` (bool), `ExtractedPath` (string), `FileCount` (int), `ErrorMessage` (string).

```powershell
$result = Expand-SEBArchive -ArchivePath "C:\backup.7z" -Destination "C:\restore_temp" -Overwrite
```

### Test-SEBArchive

Tests whether an archive file is valid and not corrupted by running the archive engine's built-in test command.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| ArchivePath | string | Yes | -- | The archive file to test. |
| Session | PSSession | No | -- | If provided, the test runs on the remote node. |

**Output:** `PSCustomObject` with `Valid` (bool), `ErrorMessage` (string).

```powershell
$test = Test-SEBArchive -ArchivePath "C:\backups\PvPArena_FULL.7z"
if ($test.Valid) { Write-Host "Archive is intact." }
```

### Get-SEBArchiveContents

Lists the files contained within an archive without extracting them.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| ArchivePath | string | Yes | -- | The archive file to list. |
| Session | PSSession | No | -- | If provided, listing runs on the remote node. |

**Output:** `PSCustomObject[]` -- array of entries with `Path` (string), `Size` (long), `CompressedSize` (long), `Modified` (datetime).

```powershell
$contents = Get-SEBArchiveContents -ArchivePath "C:\backups\PvPArena_FULL.7z"
$contents | Format-Table Path, Size, CompressedSize
```

### Get-SEBCompressionEngine

Detects and returns the available compression engine on the local machine or a remote node.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | No | -- | If provided, detection runs on the remote node. |
| PreferredEngine | string | No | `7zip` | The preferred engine: `7zip` or `dotnet`. |

**Output:** `PSCustomObject` with `Engine` (string: `7zip` or `dotnet`), `Path` (string, 7-Zip executable path or `$null`), `Available` (bool).

```powershell
$engine = Get-SEBCompressionEngine -Session $session
Write-Host "Using compression engine: $($engine.Engine)"
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Find-7ZipPath` | Searches for the 7-Zip executable in common installation paths (`C:\Program Files\7-Zip\7z.exe`), the `7Zip4Powershell` module, the system PATH, and the node agent directory. Returns the path or `$null`. |

## Dependencies

- **Optional:** 7-Zip installed on the machine where compression runs (falls back to `System.IO.Compression`).
- **Optional:** `7Zip4Powershell` PowerShell module.

## Configuration

Compression settings come from the `[compression]` section of `global.toml`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `engine` | string | `7zip` | Preferred compression engine: `7zip` or `dotnet`. |
| `level` | int/string | `5` | Compression level (1-9 for 7-Zip, `Optimal`/`Fastest` for .NET). |
| `threads` | int | `0` (auto) | Number of threads for 7-Zip compression (0 = auto). |

## Usage Scenarios

**Scenario 1: Compressing a full backup on the node**
```powershell
$compResult = Compress-SEBArchive -SourcePath $stagingDir -Destination $archivePath `
    -Session $session -Config $globalConfig.compression
Write-Host "Compressed to $([math]::Round($compResult.SizeBytes / 1MB, 2)) MB using $($compResult.Engine)"
```

**Scenario 2: Verifying an archive before restore**
```powershell
$test = Test-SEBArchive -ArchivePath $archivePath
if (-not $test.Valid) {
    Write-Error "Archive is corrupted: $($test.ErrorMessage)"
    return
}
```

**Scenario 3: Checking compression engine availability**
```powershell
$engine = Get-SEBCompressionEngine -Session $session -PreferredEngine "7zip"
if ($engine.Engine -eq 'dotnet') {
    Write-Warning "7-Zip not found on node. Using .NET compression (slower)."
}
```
