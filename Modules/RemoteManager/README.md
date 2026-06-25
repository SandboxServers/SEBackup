# RemoteManager Module

WinRM/PSRemoting session lifecycle management, remote command execution with retry logic, and SMB share path utilities. All remote operations in SEBackup flow through this module.

## Exported Functions

### New-SEBSession

Creates a new PSSession to a compute node using stored DPAPI credentials and the node's hostname from configuration.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The name of the compute node (matches the credential and config file names). |
| NodeConfig | hashtable | Yes | -- | The node configuration hashtable containing at least `hostname`. |

**Output:** `PSSession` -- an active PowerShell remoting session, or `$null` on failure.

```powershell
$nodeConfig = Get-SEBNodeConfig -NodeName "GameServer01"
$session = New-SEBSession -NodeName "GameServer01" -NodeConfig $nodeConfig.node
```

### Remove-SEBSession

Closes and cleans up one or more PSSessions created by `New-SEBSession`.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | No | -- | A specific session to remove. |
| NodeName | string | No | -- | Removes the cached session for this node name. |
| All | switch | No | `$false` | Removes all cached sessions. |

**Output:** None

```powershell
Remove-SEBSession -Session $session
Remove-SEBSession -NodeName "GameServer01"
Remove-SEBSession -All
```

### Test-SEBSessionExists

Reports whether an OPEN cached session already exists for a node. Use it to
determine session ownership before calling `New-SEBSession`: if a session
already exists, `New-SEBSession` returns the cached one (which the caller must
not tear down); if not, the caller owns the session it creates.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The node name to check the session cache for. |

**Output:** `System.Boolean` -- `$true` if an open cached session exists, else `$false`.

```powershell
$preexisted = Test-SEBSessionExists -NodeName "GameServer01"
$session = New-SEBSession -NodeName "GameServer01"
try { Invoke-Command -Session $session -ScriptBlock { ... } }
finally { if (-not $preexisted) { Remove-SEBSession -NodeName "GameServer01" } }
```

### Test-SEBConnection

Tests whether a PSSession can be established to a compute node. Does not maintain the session -- it is created and immediately removed.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The node name to test connectivity to. |
| NodeConfig | hashtable | No | -- | The node configuration. If omitted, loaded from config files. |

**Output:** `System.Boolean` -- `$true` if the connection test succeeds.

```powershell
if (Test-SEBConnection -NodeName "GameServer01") {
    Write-Host "Node is reachable."
}
```

### Invoke-SEBRemoteCommand

Executes a script block on a remote node via an existing PSSession. Includes retry logic, session-health/reconnect handling, error handling, and logging.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | Yes | -- | An active PSSession to the target node. |
| ScriptBlock | scriptblock | Yes | -- | The script block to execute remotely. |
| ArgumentList | object[] | No | -- | Arguments to pass to the script block. |
| RetryCount | int | No | `1` | Retries on failure (total attempts = RetryCount + 1). **Pass `0` for any non-idempotent / mutating block** so a post-mutation transport drop is not silently re-run. See "Idempotency and -RetryCount" below. |
| SessionRef | ref | No | -- | `[ref]` to the caller's session variable; updated in place when the wrapper reconnects a dead session. See "Reconnect propagation" below. |

**Output:** The return value of the remote script block.

```powershell
$result = Invoke-SEBRemoteCommand -Session $session -ScriptBlock {
    param($path)
    Get-ChildItem -Path $path -Recurse -File
} -ArgumentList "C:\GameData"
```

#### Idempotency and -RetryCount

The wrapper retries on transport-level failures. Because `Invoke-Command` can throw AFTER the
remote block has already run (the link drops while the result is coming back), a retry can
RE-EXECUTE the block. That is fine for idempotent work (reads, hashing/verification, metrics,
disk space) but dangerous for anything that mutates node state (VSS create/mount/remove, world
rename + robocopy, service start/stop, file deletes, best-effort cleanups). **Migrate mutating
calls with `-RetryCount 0`** so a transport failure fails fast into the caller's own
rollback/abort handling instead of running the mutation twice.

#### Reconnect propagation

If a session is found dead, the wrapper reconnects ONCE (preserving the original hostname/IP and
the friendly node/credential key, and reusing a healthy cached session if one exists). Any caller
that holds a session in a local variable across MULTIPLE calls should pass `-SessionRef
([ref]$session)` so the refreshed live session is written back into that variable; otherwise the
local keeps pointing at the dead handle until the next call re-detects it. By-value helpers that
cannot take a `[ref]` (e.g. the CompressionManager paths and `Invoke-SEBWithShadowCopy`) instead
re-fetch the live session from the cache via `New-SEBSession -NodeName <node>` (a cache hit
returns the live handle) immediately before each raw data-path call.

### Get-SEBSharePath

Constructs the UNC path to a node's SMB share based on hostname and share name from configuration.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeConfig | hashtable | Yes | -- | Hashtable with a `hostname` key. |
| InstanceConfig | hashtable | Yes | -- | Hashtable with a `share_name` key. |

**Output:** `System.String` -- UNC path like `\\192.168.1.101\SEBackup_PvPArena`.

```powershell
$sharePath = Get-SEBSharePath -NodeConfig @{ hostname = "192.168.1.101" } -InstanceConfig @{ share_name = "SEBackup_PvP" }
```

### Test-SEBShare

Tests whether an SMB share path is accessible from the C&C machine.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| SharePath | string | Yes | -- | The UNC path to test. |
| Credential | PSCredential | No | -- | Credential to use for accessing the share. |

**Output:** `System.Boolean` -- `$true` if the share is accessible.

```powershell
$accessible = Test-SEBShare -SharePath "\\GameServer01\SEBackup_PvP" -Credential $cred
```

### Mount-SEBShare

Maps an SMB share as a PSDrive or ensures it is accessible for file operations.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| SharePath | string | Yes | -- | The UNC path to mount. |
| Credential | PSCredential | No | -- | Credential for share access. |
| DriveLetter | string | No | auto | Optional drive letter for the mapping. |

**Output:** `PSCustomObject` with `Mounted` (bool), `DriveLetter` (string), `SharePath` (string).

```powershell
$mount = Mount-SEBShare -SharePath "\\GameServer01\SEBackup_PvP" -Credential $cred
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Test-SEBSessionUsable` | The single liveness predicate (`State=Opened` AND `Availability=Available`) shared by `New-SEBSession`, `Test-SEBSessionExists`, and `Invoke-SEBRemoteCommand`, so "is this session usable" has exactly one definition. |

## Module-Scoped Variables

| Variable | Purpose |
|----------|---------|
| `$script:SEBSessions` | Hashtable cache of active PSSessions keyed by node name. |

## Dependencies

- **CredentialManager** (declared in manifest as `RequiredModules`): uses `Get-SEBCredential` to retrieve stored credentials for session creation.

## Configuration

RemoteManager uses settings from node configuration files (`Config/nodes/{node}.toml`):

| Key | Section | Description |
|-----|---------|-------------|
| `hostname` | `[node]` | IP address or hostname of the compute node. |

## Usage Scenarios

**Scenario 1: Creating a session and running a remote command**
```powershell
$nodeConfig = Get-SEBNodeConfig -NodeName "GameServer01"
$session = New-SEBSession -NodeName "GameServer01" -NodeConfig $nodeConfig.node
$freeSpace = Invoke-SEBRemoteCommand -Session $session -ScriptBlock {
    (Get-PSDrive C).Free / 1GB
}
Write-Host "Free space: $([math]::Round($freeSpace, 2)) GB"
Remove-SEBSession -NodeName "GameServer01"
```

**Scenario 2: Testing connectivity to all nodes**
```powershell
$nodes = Get-SEBNodeConfig -All
foreach ($node in $nodes) {
    $name = $node['_NodeName']
    $ok = Test-SEBConnection -NodeName $name -NodeConfig $node.node
    Write-Host "${name}: $(if ($ok) { 'CONNECTED' } else { 'UNREACHABLE' })"
}
```

**Scenario 3: Accessing files via SMB share**
```powershell
$sharePath = Get-SEBSharePath -NodeConfig @{ hostname = "192.168.1.101" } -InstanceConfig @{ share_name = "SEBackup_PvP" }
if (Test-SEBShare -SharePath $sharePath -Credential $cred) {
    Get-ChildItem -Path $sharePath
}
```
