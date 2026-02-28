# NetworkThrottle Module

Bandwidth-limited file transfers between compute nodes, the C&C server, and NAS storage. Supports three transfer methods with automatic fallback: BITS (Background Intelligent Transfer Service), robocopy with inter-packet gap throttling, and plain `Copy-Item`.

## Exported Functions

### Copy-SEBThrottled

Copies a file from source to destination using bandwidth throttling based on the configured method and limits.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Source | string | Yes | -- | The source file path (local or UNC). |
| Destination | string | Yes | -- | The destination file path (local or UNC). |
| Config | hashtable | No | -- | The `[network]` config section with `method`, `bandwidth_limit_mbps`, etc. |

**Output:** `PSCustomObject` with `Success` (bool), `Method` (string), `Duration` (TimeSpan), `BytesCopied` (long), `ErrorMessage` (string).

```powershell
Copy-SEBThrottled -Source "\\GameServer01\staging\backup.7z" `
    -Destination "C:\Backups\backup.7z" -Config $globalConfig.network
```

### Start-SEBBitsTransfer

Starts a BITS (Background Intelligent Transfer Service) transfer job for a file. BITS provides built-in bandwidth management and resumes interrupted transfers automatically.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Source | string | Yes | -- | The source file path. |
| Destination | string | Yes | -- | The destination file path. |
| DisplayName | string | No | auto | A display name for the BITS job. |
| BandwidthLimitMbps | int | No | unlimited | Maximum bandwidth in Mbps. |
| Priority | string | No | `Normal` | BITS job priority: `Foreground`, `High`, `Normal`, `Low`. |

**Output:** `PSCustomObject` with `JobId` (GUID), `Success` (bool), `Duration` (TimeSpan), `ErrorMessage` (string).

```powershell
$job = Start-SEBBitsTransfer -Source "\\server\share\file.7z" `
    -Destination "C:\local\file.7z" -BandwidthLimitMbps 100
```

### Get-SEBTransferStatus

Checks the status of a BITS transfer job.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| JobId | guid | Yes | -- | The BITS job ID to check. |

**Output:** `PSCustomObject` with `JobId` (GUID), `State` (string), `BytesTransferred` (long), `BytesTotal` (long), `PercentComplete` (double), `ErrorMessage` (string).

```powershell
$status = Get-SEBTransferStatus -JobId $job.JobId
Write-Host "Progress: $($status.PercentComplete)%"
```

### Stop-SEBTransfer

Cancels an in-progress BITS transfer job.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| JobId | guid | Yes | -- | The BITS job ID to cancel. |

**Output:** `System.Boolean` -- `$true` if the job was cancelled.

```powershell
Stop-SEBTransfer -JobId $job.JobId
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `ConvertTo-RobocopyIpg` | Converts a bandwidth limit in Mbps to a robocopy inter-packet gap (IPG) value in milliseconds. The IPG is the delay between each 64 KB packet, used to throttle transfer speed. |
| `Test-BITSAvailable` | Tests whether the BITS PowerShell module is available on the current machine. Returns `$true` if `Start-BitsTransfer` exists. |

## Transfer Method Selection

The module uses this fallback chain:

1. **BITS** (`method = "bits"`) -- Best for large files. Provides built-in resume, bandwidth management, and low priority. Requires the BITS Windows service and `BitsTransfer` PowerShell module.
2. **Robocopy** (`method = "robocopy"`) -- Uses the `/IPG` (inter-packet gap) flag for throttling. Available on all Windows machines. Good for LAN transfers.
3. **Copy-Item** (`method = "copy"` or fallback) -- Simple PowerShell file copy with no throttling. Used when BITS and robocopy are unavailable or inappropriate.

## Dependencies

- **Optional:** BITS Windows service and `BitsTransfer` PowerShell module.
- **Optional:** `robocopy.exe` (built into Windows).

## Configuration

Network settings come from the `[network]` section of `global.toml`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `method` | string | `robocopy` | Transfer method: `bits`, `robocopy`, or `copy`. |
| `bandwidth_limit_mbps` | int | `0` (unlimited) | Maximum bandwidth usage in Mbps. |
| `bits_priority` | string | `Normal` | BITS job priority level. |
| `robocopy_ipg` | int | auto-calculated | Robocopy inter-packet gap in ms (auto-calculated from `bandwidth_limit_mbps` if not set). |

## Usage Scenarios

**Scenario 1: Throttled archive transfer from node to C&C**
```powershell
Copy-SEBThrottled -Source "\\192.168.1.101\SEBackup_PvP\PvPArena_FULL.7z" `
    -Destination "C:\SEBackup\Backups\PvPArena\full\PvPArena_FULL.7z" `
    -Config @{ method = "robocopy"; bandwidth_limit_mbps = 100 }
```

**Scenario 2: BITS transfer with progress monitoring**
```powershell
$job = Start-SEBBitsTransfer -Source $source -Destination $dest -BandwidthLimitMbps 50
do {
    $status = Get-SEBTransferStatus -JobId $job.JobId
    Write-Host "Transfer: $($status.PercentComplete)% ($($status.State))"
    Start-Sleep -Seconds 5
} while ($status.State -eq 'Transferring')
```

**Scenario 3: NAS offsite copy with low priority**
```powershell
Copy-SEBThrottled -Source $ccArchivePath -Destination $nasArchivePath `
    -Config @{ method = "bits"; bandwidth_limit_mbps = 50; bits_priority = "Low" }
```
