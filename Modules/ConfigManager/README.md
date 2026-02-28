# ConfigManager Module

TOML configuration loading, caching, merging, and validation for the SEBackup system. Handles the three-tier configuration model: global config, per-node config, and per-instance config.

## Exported Functions

### Get-SEBGlobalConfig

Loads and returns the global configuration from `Config/global.toml`. Results are cached in memory with a configurable TTL to avoid repeated file reads.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Force | switch | No | `$false` | Bypasses the cache and forces a fresh read from disk. |

**Output:** `hashtable` -- the parsed global configuration.

```powershell
$config = Get-SEBGlobalConfig
$config = Get-SEBGlobalConfig -Force
```

### Get-SEBNodeConfig

Loads and returns the configuration for a specific compute node from `Config/nodes/{NodeName}.toml`, or all node configs when `-All` is specified.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | No | -- | The name of the node (matches the TOML filename without extension). |
| All | switch | No | `$false` | Returns all node configurations as an array. |

**Output:** `hashtable` or `hashtable[]` -- the parsed node configuration(s). Each config includes `_NodeName` as a metadata key.

```powershell
$nodeConfig = Get-SEBNodeConfig -NodeName "GameServer01"
$allNodes = Get-SEBNodeConfig -All
```

### Get-SEBInstanceConfig

Reads a per-instance configuration TOML file from a remote compute node via an active PSSession. Instance configs live at `C:\SEBackup\instances\{InstanceName}.toml` on the node.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | Yes | -- | An active PSSession connected to the compute node. |
| InstanceName | string | Yes | -- | The name of the instance to load. |

**Output:** `hashtable` -- the parsed instance configuration with `_InstanceName` and `_NodeName` metadata keys.

```powershell
$session = New-SEBSession -NodeName "GameServer01" -NodeConfig $nodeConfig
$instanceConfig = Get-SEBInstanceConfig -Session $session -InstanceName "PvPArena"
```

### Get-SEBAllInstanceConfigs

Discovers and loads all instance configuration files from a remote compute node.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Session | PSSession | Yes | -- | An active PSSession connected to the compute node. |

**Output:** `hashtable[]` -- array of parsed instance configurations.

```powershell
$allInstances = Get-SEBAllInstanceConfigs -Session $session
$allInstances | ForEach-Object { Write-Host $_['_InstanceName'] }
```

### Test-SEBConfig

Validates the global, node, and/or instance configuration against the expected schema. Checks for required keys, valid value types, and valid value ranges.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| GlobalConfig | hashtable | No | -- | A global config to validate. |
| NodeConfig | hashtable | No | -- | A node config to validate. |
| InstanceConfig | hashtable | No | -- | An instance config to validate. |

**Output:** `PSCustomObject` with `Valid` (bool), `Errors` (string[]), and `Warnings` (string[]).

```powershell
$result = Test-SEBConfig -GlobalConfig (Get-SEBGlobalConfig)
if (-not $result.Valid) { $result.Errors | ForEach-Object { Write-Error $_ } }
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Merge-ConfigOverrides` | Merges instance-level overrides on top of global defaults, producing a final effective configuration. |
| `Resolve-ConfigPaths` | Resolves relative paths in config values to absolute paths based on the project root. |

The `Test-SEBConfig` file also contains inline private validation helpers: `Test-GlobalConfigSchema`, `Test-NodeConfigSchema`, and `Test-InstanceConfigSchema`.

## Module-Scoped Variables

| Variable | Purpose |
|----------|---------|
| `$script:CachedGlobalConfig` | In-memory cache of the parsed global config. |
| `$script:CachedGlobalConfigTime` | Timestamp when the cache was last refreshed. |
| `$script:CacheTTLSeconds` | How long the cache is valid (default 60 seconds). |

## Dependencies

- **PSToml** (external module) -- required for `ConvertFrom-Toml` / `Import-PSToml`.

## Configuration Files

| File | Location | Purpose |
|------|----------|---------|
| `global.toml` | `Config/` on C&C | System-wide settings for all modules. |
| `{node}.toml` | `Config/nodes/` on C&C | Per-node connection info (hostname, credentials reference). |
| `{instance}.toml` | `C:\SEBackup\instances\` on node | Per-instance settings (world path, VRage API, staging, overrides). |

## Usage Scenarios

**Scenario 1: Loading the full config stack for a backup operation**
```powershell
$global = Get-SEBGlobalConfig
$node = Get-SEBNodeConfig -NodeName "GameServer01"
$session = New-SEBSession -NodeName "GameServer01" -NodeConfig $node.node
$instance = Get-SEBInstanceConfig -Session $session -InstanceName "PvPArena"
```

**Scenario 2: Validating configuration before first use**
```powershell
$global = Get-SEBGlobalConfig -Force
$result = Test-SEBConfig -GlobalConfig $global
if (-not $result.Valid) {
    $result.Errors | ForEach-Object { Write-Error "Config error: $_" }
    return
}
```

**Scenario 3: Discovering all instances on all nodes**
```powershell
$allNodes = Get-SEBNodeConfig -All
foreach ($node in $allNodes) {
    $session = New-SEBSession -NodeName $node['_NodeName'] -NodeConfig $node.node
    $instances = Get-SEBAllInstanceConfigs -Session $session
    Write-Host "Node $($node['_NodeName']): $($instances.Count) instance(s)"
}
```
