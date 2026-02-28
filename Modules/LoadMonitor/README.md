# LoadMonitor Module

CPU, memory, and game simulation speed monitoring with configurable thresholds and backoff strategies. Prevents backups from starting when a compute node is under heavy load to avoid impacting game server performance.

## Exported Functions

### Test-SEBNodeLoad

Checks the current load on a remote compute node against configured thresholds.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | Yes | -- | An active PSSession to the compute node. |
| Config | hashtable | Yes | -- | The `load_awareness` config section with threshold values. |

**Output:** `PSCustomObject` with `Safe` (bool), `CpuPercent` (double), `MemoryPercent` (double), `SimSpeed` (double or `$null`), `PlayerCount` (int or `$null`), `Reasons` (string[]).

```powershell
$load = Test-SEBNodeLoad -Session $session -Config $globalConfig.load_awareness
if (-not $load.Safe) {
    Write-Warning "Node too busy: $($load.Reasons -join '; ')"
}
```

### Wait-SEBNodeLoad

Polls a node's load at regular intervals and waits until load drops below thresholds or a maximum wait time is reached. Uses configurable backoff behavior (defer or skip).

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | Yes | -- | An active PSSession to the compute node. |
| Config | hashtable | Yes | -- | The `load_awareness` config section with threshold and backoff values. |

**Output:** `PSCustomObject` with `Proceeded` (bool), `WaitedSeconds` (double), `Attempts` (int), `FinalLoad` (PSCustomObject).

```powershell
$wait = Wait-SEBNodeLoad -Session $session -Config $globalConfig.load_awareness
if ($wait.Proceeded) {
    Write-Host "Safe to proceed after waiting $([math]::Round($wait.WaitedSeconds))s."
} else {
    Write-Warning "Timed out waiting for safe load levels."
}
```

### Get-SEBNodeMetrics

Retrieves current system metrics from a remote compute node: CPU usage, memory usage, disk I/O, and active processes.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | Yes | -- | An active PSSession to the compute node. |

**Output:** `PSCustomObject` with `CpuPercent` (double), `MemoryPercent` (double), `MemoryUsedGB` (double), `MemoryTotalGB` (double), `DiskReadBytesPerSec` (long), `DiskWriteBytesPerSec` (long), `TopProcesses` (PSCustomObject[]).

```powershell
$metrics = Get-SEBNodeMetrics -Session $session
Write-Host "CPU: $($metrics.CpuPercent)%, RAM: $($metrics.MemoryPercent)%"
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Get-SEBPlayerCount` | Queries the VRage Remote API to get the current player count on a Torch server instance. Used as a load indicator -- high player counts correlate with server load. |

## Dependencies

- **RemoteManager**: executes monitoring commands on remote nodes via PSSessions.
- **VRageAPI** (optional): `Get-SEBPlayerCount` uses `Get-SEBServerInfo` to query player counts.

## Configuration

Load awareness settings come from the `[load_awareness]` section of `global.toml`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Enable or disable load awareness checks. |
| `cpu_threshold` | int | `80` | Maximum CPU usage percentage. |
| `memory_threshold` | int | `85` | Maximum memory usage percentage. |
| `sim_speed_threshold` | float | `0.8` | Minimum acceptable game sim speed (1.0 = normal). |
| `max_wait_minutes` | int | `30` | Maximum time to wait for load to drop. |
| `poll_interval_seconds` | int | `30` | How often to re-check load during waiting. |
| `on_high_load` | string | `defer` | Behavior when load is high: `defer` (wait) or `skip` (abort). |

## Usage Scenarios

**Scenario 1: Pre-backup load check with automatic waiting**
```powershell
$load = Test-SEBNodeLoad -Session $session -Config $globalConfig.load_awareness
if (-not $load.Safe) {
    $wait = Wait-SEBNodeLoad -Session $session -Config $globalConfig.load_awareness
    if (-not $wait.Proceeded) {
        Write-Error "Backup deferred: node did not reach safe load levels."
        return
    }
}
# Proceed with backup...
```

**Scenario 2: Monitoring node health**
```powershell
$metrics = Get-SEBNodeMetrics -Session $session
Write-Host "CPU: $($metrics.CpuPercent)%"
Write-Host "Memory: $($metrics.MemoryUsedGB)/$($metrics.MemoryTotalGB) GB ($($metrics.MemoryPercent)%)"
$metrics.TopProcesses | Select-Object -First 5 | Format-Table Name, CPU, WorkingSetMB
```

**Scenario 3: Checking if now is a good time for maintenance**
```powershell
$load = Test-SEBNodeLoad -Session $session -Config @{
    cpu_threshold = 50
    memory_threshold = 70
    sim_speed_threshold = 0.9
}
if ($load.Safe) { Write-Host "Good time for maintenance." }
```
