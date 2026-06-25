# Configuration Reference

This document describes every configuration field in the SEBackup system. There are three types of config files, and each one is covered in its own section below.

## Configuration File Locations

| File | Location | Format |
|------|----------|--------|
| Global config | `Config/global.toml` on C&C | TOML |
| Node config | `Config/nodes/{nodename}.toml` on C&C | TOML |
| Instance config | `C:\SEBackup\instances\{instancename}.toml` on compute node | TOML |

All config files use the [TOML](https://toml.io/) format. Windows paths in TOML files must use double backslashes (`C:\\Path\\To\\Folder`) because the backslash is an escape character.

Example config files with detailed comments are included:
- `Config/global.example.toml`
- `Config/node.example.toml`
- `NodeAgent/instance.example.toml`

---

## Global Configuration (`Config/global.toml`)

This file controls system-wide behavior. It lives on the C&C machine.

### [storage]

Controls where backup archives are stored.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `cc_backup_root` | string (path) | `"C:\\SEBackup\\Backups"` | Local path on the C&C server where backup archives are stored after transfer from compute nodes. Each node and instance gets a subdirectory. Must have sufficient free space. |
| `nas_backup_path` | string (path) | `""` (empty = disabled) | UNC path or mapped drive for long-term NAS/network storage. Backups are copied here after landing on the C&C. Leave empty to disable NAS offloading. Examples: `"\\\\NAS01\\Backups\\SE"`, `"Z:\\SEBackups"` |

### [retention]

Controls how many backups are kept and for how long.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `cc_full_count` | integer | `2` | Number of full backup sets to retain on the C&C server. A "set" is one full backup plus all its incremental children. Minimum: 1. Recommended: 2-3. |
| `nas_retention_days` | integer | `90` | Number of days to retain backups on the NAS before automatic cleanup. Only applies when `nas_backup_path` is configured. Set to `0` to disable NAS retention cleanup (keep forever). |

### [schedule]

Controls when and how often backups run automatically.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Master switch for the backup scheduler. Set to `false` to disable all automatic backups (manual only). |
| `interval_hours` | integer | `6` | Hours between incremental backup runs. Lower = more frequent backups but more I/O. Recommended: 4-8 for active servers, 12-24 for low-activity servers. |
| `full_backup_interval_hours` | integer | `168` | Hours between forced full backups. 168 = weekly. Full backups capture all files regardless of what changed. Should be a multiple of `interval_hours`. |
| `max_incremental_chain_length` | integer | `48` | Maximum number of incrementals in a chain before forcing a full. Longer chains = more efficient storage but slower restores. If this limit is hit before `full_backup_interval_hours`, a full backup is forced early. |
| `start_time` | string | `"02:00"` | Preferred start time for the first backup of the day (24-hour format, `"HH:mm"`). The scheduler aligns backup runs near this time. |

### [compression]

Controls how backup archives are compressed.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `engine` | string | `"auto"` | Compression engine to use. `"auto"` = use 7-Zip if available, fall back to .NET. `"7zip"` = force 7-Zip (must be installed on nodes). `"dotnet"` = force .NET built-in (no external dependencies). |
| `level_7zip` | integer (1-9) | `5` | 7-Zip compression level. 1 = fastest (least compression), 9 = best compression (slowest). 5 is a balanced default. Only applies when engine is `"auto"` or `"7zip"`. |

### [network]

Controls bandwidth usage when transferring backups from nodes to C&C.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_bandwidth_mbps` | integer | `100` | Maximum bandwidth for backup transfers in megabits per second. Set to `0` for unlimited. Prevents backup transfers from saturating the network. |
| `robocopy_ipg_ms` | integer | `0` | Robocopy inter-packet gap in milliseconds. Higher values = slower but gentler transfers. 0 = no throttling, 10-50 = light, 100+ = heavy. Only applies to robocopy transfers. |

### [load_awareness]

Controls server load monitoring before backup operations.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable or disable load-aware scheduling. When `false`, backups proceed regardless of server load. |
| `max_cpu_percent` | integer (0-100) | `80` | Maximum CPU usage (%) on the compute node before deferring backups. Measured as an average. |
| `max_memory_percent` | integer (0-100) | `85` | Maximum memory usage (%) before deferring backups. |
| `sim_speed_threshold` | float (0.0-1.0) | `0.8` | Minimum sim speed required before proceeding. 1.0 = full speed, 0.5 = half speed. Obtained via the VRage Remote API. Below this, the server is considered too loaded. |
| `check_interval_seconds` | integer | `30` | Seconds between load checks when waiting for conditions to improve. |
| `backoff_multiplier` | float | `2.0` | Multiplier for exponential backoff. Each consecutive failed check multiplies the wait time by this factor. |
| `max_backoff_minutes` | integer | `60` | Maximum minutes to wait in backoff before giving up. After this, the backup either proceeds anyway or is skipped, depending on implementation. |

### [notifications]

Controls alert notifications.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Master switch for notifications. `false` = silence all alerts. |
| `on_success` | boolean | `false` | Send a notification when a backup completes successfully. Can be noisy for frequent schedules. |
| `on_failure` | boolean | `true` | Send a notification when a backup fails. Strongly recommended to keep `true`. |
| `on_warning` | boolean | `true` | Send a notification for non-fatal warnings (e.g., high load delays, skipped instances). |
| `webhook_url` | string | `""` (empty) | Webhook URL for sending notifications. For Discord, use a Discord webhook URL. |
| `method` | string | `"discord"` | Notification delivery method. Currently only `"discord"` is supported. |

### [defaults.vrage_api]

Default VRage Remote API settings, used for all instances unless overridden.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | integer | `8080` | Default TCP port for the VRage Remote API. |
| `save_timeout_seconds` | integer | `120` | Seconds to wait for a world save to complete before timing out. Increase for very large worlds. |

### [defaults.vss]

Default Volume Shadow Copy (VSS) settings.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mount_base` | string (path) | `"C:\\SEBackup\\vss_mount"` | Base directory for mounting VSS shadow copies on compute nodes. Must be on an NTFS volume. Created automatically. |

---

## Node Configuration (`Config/nodes/{nodename}.toml`)

Each compute node has its own config file on the C&C machine. The filename (without the `.toml` extension) becomes the node identifier.

### [node]

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `display_name` | string | (none) | Human-friendly display name for logs, notifications, and the GUI. |
| `hostname` | string | (none) | Hostname or IP address of the compute node. Used for PSRemoting connections. Can be an IP, DNS name, or FQDN. |
| `username` | string | (none) | Username for the PSRemoting connection. Must have Administrator privileges on the node. The password is stored in the separate credential file, not here. |

**Credentials** are stored separately in `Credentials/{nodename}.cred` using LocalMachine-scope DPAPI (machine-bound so unattended scheduled tasks can decrypt; see [docs/UNATTENDED-AUTH.md](UNATTENDED-AUTH.md)). Create them with the `Save-SEBCredential` function:

```powershell
Save-SEBCredential -NodeName "gamingpc01"
```

---

## Instance Configuration (`C:\SEBackup\instances\{instancename}.toml`)

Each Torch server instance on a compute node has its own config file on that node. The filename (without `.toml`) becomes the instance identifier. `Register-Instance.ps1` normally generates this file for you; the fields below are what the backup and restore engine actually reads.

> **TOML ordering matters.** The operational keys (`run_mode`, `world_path`, `staging_path`, `share_name`) are **top-level** keys and must appear **before** the first `[table]` header. In TOML, a bare key written after a `[section]` header belongs to that section, so moving these under `[instance]` makes the engine read them as missing.

### Top-level operational keys

These are read directly by the engine (`Invoke-SEBBackup`, `Invoke-SEBRestore`, `Test-SEBPreFlight`, `Start`/`Stop-SEBTorchServer`).

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `world_path` | string (path) | (required) | Absolute path to the world save data directory (the folder containing `Sandbox.sbc`). This is the data SEBackup snapshots, archives, and restores. |
| `share_name` | string | (required) | Name of the SMB share on the node exposing the staging directory (typically `SEBackup_{instance}$`). The C&C pulls finished archives from it. |
| `staging_path` | string (path) | `C:\SEBackup\staging` | Local staging area on the node where the world is copied from the VSS snapshot and compressed. |
| `run_mode` | string | `"service"` | How the Torch server runs: `"service"` (Windows service) or `"console"`. Controls how the restore engine stops/starts the server. |
| `service_name` | string | `TorchServer_{name}` | Optional. The Windows service name when `run_mode = "service"`. |
| `process_name` | string | `Torch.Server` | Optional. Process image name to wait on when stopping a `console`-mode server. |

### [instance]

Identity metadata.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | (none) | Internal name for this instance. Should match the filename stem. Must be unique within a node. Letters, numbers, underscores only. |
| `display_name` | string | (none) | Human-readable display name for logs, notifications, and the GUI. |
| `description` | string | `""` | Optional description for documentation purposes. |

### [vrage_api]

Overrides the global `[defaults.vrage_api]` settings for this instance.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | integer | Global default (`8080`) | TCP port for the VRage Remote API on this instance. Each instance on the same node must use a unique port. |
| `security_key` | string | `""` | VRage Remote API security key (the Base64 "Remote API" key from `SpaceEngineers-Dedicated.cfg`). Used to authenticate save/ping requests. Empty means the pre-backup save and post-restore ping are skipped. |
| `save_timeout_seconds` | integer | Global default (`120`) | Override the save timeout for this instance. Increase for very large worlds. |

> **Migration note.** Older configs nested these values differently (`[paths].world_save`, `[smb].share_name`, `[vss].volume`, `run_mode` under `[instance]`, and `[vrage_api].key`). `Get-SEBInstanceConfig` still reads those legacy layouts by normalizing them onto the keys above, but re-running `Register-Instance.ps1` rewrites the file in the current schema.

### [torch] (optional, informational)

Recorded by `Register-Instance.ps1` for reference. The engine operates on the top-level `world_path`, not on these.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `install_path` | string (path) | (none) | Absolute path to the Torch server installation directory (where `Torch.Server.exe` lives). |
| `data_root` | string (path) | (none) | The Torch instance data root discovered during registration. |

---

## Configuration Merging

SEBackup uses a layered configuration system. Settings are merged in this order (later values override earlier ones):

1. **Built-in defaults** -- Hardcoded in the `ConfigManager` module
2. **Global config** -- `Config/global.toml` on the C&C
3. **Instance config** -- `C:\SEBackup\instances\{instance}.toml` on the node

For example, if `global.toml` sets `[defaults.vrage_api] port = 8080` and an instance config sets `[vrage_api] port = 9090`, the instance will use port 9090.

## Tips

- **Paths must use double backslashes** in TOML: `"C:\\Folder\\File"` not `"C:\Folder\File"`
- **Boolean values** are lowercase: `true` or `false` (not `True`, `False`, `"true"`)
- **Comments** start with `#` and continue to the end of the line
- **Strings** must be quoted: `"like this"`
- **Numbers** are unquoted: `42` or `3.14`
- You can validate a config with: `Test-SEBConfig -Path "Config\global.toml"`
