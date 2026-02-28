# VRageAPI Module

HMAC-SHA1 authenticated HTTP client for the VRage Remote API exposed by Space Engineers Torch servers. Used to trigger world saves before backup snapshots and to query server status.

## Exported Functions

### Invoke-SEBVRageRequest

Sends an authenticated HTTP request to the VRage Remote API. Generates HMAC-SHA1 authentication headers using the configured security key.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Hostname | string | Yes | -- | The hostname or IP address of the Torch server. |
| Port | int | Yes | -- | The VRage API port number. |
| SecurityKey | string | Yes | -- | The HMAC-SHA1 security key for authentication. |
| Endpoint | string | Yes | -- | The API endpoint path (e.g., `server`, `session/save`). |
| Method | string | No | `GET` | HTTP method: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`. |
| Body | string | No | -- | Optional request body (JSON string). |
| TimeoutSeconds | int | No | `30` | Request timeout in seconds. |

**Output:** `PSCustomObject` with `Success` (bool), `StatusCode` (int), `Data` (object), `ErrorMessage` (string).

```powershell
$result = Invoke-SEBVRageRequest -Hostname "192.168.1.101" -Port 8080 `
    -SecurityKey "mykey123" -Endpoint "server" -Method GET
```

### Save-SEBVRageWorld

Triggers a world save on the Torch server via the VRage Remote API and waits for completion. This flushes the game state to disk before taking a VSS snapshot.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Hostname | string | Yes | -- | The hostname or IP address of the Torch server. |
| Port | int | Yes | -- | The VRage API port number. |
| SecurityKey | string | Yes | -- | The HMAC-SHA1 security key. |
| TimeoutSeconds | int | No | `60` | Maximum seconds to wait for the save to complete. |

**Output:** `PSCustomObject` with `Success` (bool), `Duration` (TimeSpan), `ErrorMessage` (string).

```powershell
$saveResult = Save-SEBVRageWorld -Hostname "192.168.1.101" -Port 8080 `
    -SecurityKey "mykey123" -TimeoutSeconds 90
if ($saveResult.Success) {
    Write-Host "World saved in $([math]::Round($saveResult.Duration.TotalSeconds, 1))s"
}
```

### Test-SEBVRageAPI

Tests whether the VRage Remote API is reachable and responding on the specified host and port.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Hostname | string | Yes | -- | The hostname or IP address to test. |
| Port | int | Yes | -- | The VRage API port number. |
| SecurityKey | string | Yes | -- | The HMAC-SHA1 security key. |

**Output:** `System.Boolean` -- `$true` if the API responds successfully.

```powershell
if (Test-SEBVRageAPI -Hostname "192.168.1.101" -Port 8080 -SecurityKey "mykey123") {
    Write-Host "VRage API is online."
}
```

### Get-SEBServerInfo

Retrieves server information from the VRage Remote API, including server name, world name, version, player count, and sim speed.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Hostname | string | Yes | -- | The hostname or IP address. |
| Port | int | Yes | -- | The VRage API port number. |
| SecurityKey | string | Yes | -- | The HMAC-SHA1 security key. |

**Output:** `PSCustomObject` with `ServerName`, `WorldName`, `Version`, `Players`, `SimSpeed`, `SimCpuLoad`, `IsReady` properties, or `$null` on failure.

```powershell
$info = Get-SEBServerInfo -Hostname "192.168.1.101" -Port 8080 -SecurityKey "mykey123"
Write-Host "Server: $($info.ServerName), Players: $($info.Players), SimSpeed: $($info.SimSpeed)"
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `New-SEBVRageAuthHeaders` | Generates the HMAC-SHA1 authentication headers required by the VRage Remote API. Computes a nonce, timestamp, and signature over the request URL. |

## Dependencies

None (uses built-in `System.Security.Cryptography.HMACSHA1` and `Invoke-RestMethod`).

## Configuration

VRage API settings come from per-instance configuration (`{instance}.toml` on each node):

| Key | Section | Default | Description |
|-----|---------|---------|-------------|
| `port` | `[vrage_api]` | from global defaults | API port number (typically 8080). |
| `security_key` | `[vrage_api]` | -- | HMAC-SHA1 security key. |
| `save_timeout_seconds` | `[vrage_api]` | from global defaults | Timeout for world save operations. |

## Usage Scenarios

**Scenario 1: Trigger a world save before backup**
```powershell
$saveResult = Save-SEBVRageWorld -Hostname $nodeHostname -Port 8080 `
    -SecurityKey $instanceConfig.vrage_api.security_key -TimeoutSeconds 60
if (-not $saveResult.Success) {
    Write-Warning "World save failed: $($saveResult.ErrorMessage)"
}
```

**Scenario 2: Check if a server is running before restore**
```powershell
$isOnline = Test-SEBVRageAPI -Hostname "192.168.1.101" -Port 8080 -SecurityKey "key"
if ($isOnline) {
    Write-Host "Server is running -- must stop before restore."
}
```

**Scenario 3: Monitor server health**
```powershell
$info = Get-SEBServerInfo -Hostname "192.168.1.101" -Port 8080 -SecurityKey "key"
if ($info.SimSpeed -lt 0.5) {
    Write-Warning "Sim speed is critically low: $($info.SimSpeed)"
}
```
