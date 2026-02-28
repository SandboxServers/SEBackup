# SEBackup

**Space Engineers Torch Server Backup & Restore System**

A PowerShell 7 command-and-control (C&C) system for managing automated backups of Space Engineers dedicated servers running the [Torch](https://torchapi.net/) server wrapper. Designed for server hosts who run multiple game server instances across one or more Windows machines.

## Features

- **Zero-downtime VSS backups** -- Uses Windows Volume Shadow Copy to snapshot game data while the server is running. No need to stop the server or kick players.
- **Incremental backup chains** -- After the first full backup, only changed files are archived. Reduces storage usage and backup time by 80-95% on typical servers.
- **Multi-node command and control** -- Manage backups across multiple compute nodes from a single C&C machine using WinRM/PowerShell Remoting.
- **Three-tier storage** -- Backups flow from the compute node staging area to the C&C server to an optional NAS/network share. Configurable retention policies at each tier.
- **TOML configuration** -- Human-readable configuration files with extensive comments. No registry edits, no XML, no JSON.
- **Load-aware scheduling** -- Monitors CPU, memory, and game sim speed before starting backups. Automatically defers if the server is under heavy load.
- **Bandwidth throttling** -- Limits network usage during file transfers via BITS or robocopy IPG so backups don't lag the game server.
- **Discord notifications** -- Get alerts on backup success, failure, or warnings via Discord webhooks. Know immediately if something goes wrong.
- **Integrity verification** -- Three-level verification: archive CRC checks, manifest cross-referencing, and full chain reconstruction validation.
- **VRage Remote API integration** -- Triggers a world save via the Torch/SE Remote API before taking the VSS snapshot, ensuring the latest game state is captured.
- **WPF Dashboard GUI** -- (Planned) Visual dashboard for monitoring backup status, browsing history, and performing restores.

## Architecture

```
                         SEBackup Architecture
  ============================================================

  C&C Server (your management PC)
  +----------------------------------------------------------+
  |  SEBackup PowerShell Modules                             |
  |  +----------+  +-----------+  +------------+             |
  |  | Config   |  | Scheduler |  | Backup     |             |
  |  | Manager  |  | Manager   |  | Engine     |             |
  |  +----------+  +-----------+  +-----+------+             |
  |                                     |                    |
  |  +----------+  +-----------+  +-----+------+             |
  |  | Notif.   |  | Integrity |  | Manifest   |             |
  |  | Manager  |  | Manager   |  | Manager    |             |
  |  +----------+  +-----------+  +------------+             |
  +-----+---------------------+--------------------+---------+
        |   WinRM/PSRemoting  |  SMB File Transfer |
        v                     v                    v
  Compute Node 1         Compute Node 2         NAS / Network
  +-----------------+    +-----------------+    +-------------+
  | Torch Server A  |    | Torch Server C  |    | Long-term   |
  | Torch Server B  |    | Torch Server D  |    | backup      |
  |                 |    |                 |    | storage     |
  | VSS Snapshots   |    | VSS Snapshots   |    |             |
  | Local Staging   |    | Local Staging   |    |             |
  +-----------------+    +-----------------+    +-------------+

  Data Flow:
  1. C&C triggers VRage API world save on the Torch instance
  2. C&C creates a VSS shadow copy on the compute node (via WinRM)
  3. C&C generates a file manifest from the VSS snapshot
  4. Changed files are compressed into an incremental archive
  5. Archive is transferred from node staging to C&C local storage
  6. Archive is optionally copied to NAS for long-term retention
  7. Integrity verification runs on the completed backup
  8. Old backups are pruned per retention policy
  9. Discord notification is sent with the result
```

## Quick Start

### Prerequisites

- **Windows 10** or **Windows Server 2016** (or later) on all machines
- **PowerShell 7.0+** on the C&C machine and all compute nodes
- **Administrator access** to all machines
- **WinRM/PSRemoting** enabled on all compute nodes
- **Torch server** installed and running on compute nodes

### Setup (5 minutes)

```powershell
# 1. Install PowerShell 7 if you haven't already
#    Download from: https://aka.ms/powershell-release?tag=stable

# 2. Clone or download this repository to your C&C machine
git clone https://github.com/SandboxServers/SEBackup.git
cd SEBackup

# 3. Run the C&C installer (elevated PowerShell 7 prompt)
.\Install.ps1

# 4. Edit the global config with your storage paths
notepad Config\global.toml

# 5. Set up each compute node
.\Scripts\Setup-Node.ps1 -NodeName "GamePC01" -Hostname "192.168.1.101"

# 6. Register each Torch server instance
.\Scripts\Register-Instance.ps1 -NodeName "GamePC01" -InstanceName "PvPArena"

# 7. Run your first backup
.\Scripts\Invoke-Backup.ps1 -All
```

For the full step-by-step walkthrough, see [docs/QUICKSTART.md](docs/QUICKSTART.md).

### Optional: Scheduled Backups

```powershell
# Register a Windows scheduled task for automatic backups
.\Scripts\Register-Schedule.ps1 -Action Register
```

### Optional: Discord Notifications

See [docs/DISCORD-SETUP.md](docs/DISCORD-SETUP.md) for webhook setup instructions.

## Screenshots

*Screenshots will be added here when the WPF dashboard GUI is completed.*

## Configuration Overview

SEBackup uses TOML configuration files. Here is where each config lives:

| File | Location | Purpose |
|------|----------|---------|
| `global.toml` | `Config/` on C&C | System-wide settings (storage, schedule, compression, network, notifications) |
| `{node}.toml` | `Config/nodes/` on C&C | Per-node connection info (hostname, credentials reference) |
| `{instance}.toml` | `C:\SEBackup\instances\` on node | Per-instance settings (paths, VRage API, overrides) |

Every setting is documented in the example config files (`*.example.toml`) with descriptions, defaults, and valid values. See [docs/CONFIG-REFERENCE.md](docs/CONFIG-REFERENCE.md) for the complete reference.

## Module Reference

SEBackup is organized into 16 sub-modules:

| Module | Purpose |
|--------|---------|
| **Logger** | Thread-safe, daily-rotating structured logging |
| **ConfigManager** | TOML config loading, caching, merging, validation |
| **CredentialManager** | DPAPI-encrypted credential storage |
| **RemoteManager** | WinRM session lifecycle, remote command execution, SMB shares |
| **VRageAPI** | HMAC-SHA1 authenticated VRage Remote API client |
| **VSSManager** | VSS shadow copy creation, mounting, cleanup |
| **ManifestManager** | SHA256 file manifests, diff comparison, chain traversal |
| **CompressionManager** | 7-Zip / .NET compression abstraction |
| **IntegrityManager** | Three-level backup integrity verification |
| **LoadMonitor** | CPU, memory, sim speed load checks with backoff |
| **NetworkThrottle** | Bandwidth-limited transfers via BITS/robocopy |
| **NotificationManager** | Discord webhook notifications |
| **MetricsCollector** | Backup metrics and statistics (in development) |
| **BackupEngine** | Full/incremental backup orchestration |
| **RestoreEngine** | Backup restoration (in development) |
| **SchedulerManager** | Windows Task Scheduler integration |

## Development Status

SEBackup is under active development. The following modules are complete or in progress:

| Module | Status |
|--------|--------|
| Logger | Complete |
| ConfigManager | Complete |
| CredentialManager | Complete |
| RemoteManager | Complete |
| VRageAPI | Complete |
| VSSManager | Complete |
| ManifestManager | Complete |
| CompressionManager | Complete |
| IntegrityManager | Complete |
| LoadMonitor | Structure created |
| NetworkThrottle | Complete |
| NotificationManager | Structure created |
| MetricsCollector | Structure created |
| BackupEngine | Structure created |
| RestoreEngine | Structure created |
| SchedulerManager | Structure created |
| GUI / Dashboard | Structure created |

## Requirements

- **Operating System:** Windows 10 / Windows Server 2016 or later
- **PowerShell:** 7.0 or later
- **WinRM:** Enabled on all compute nodes (`Enable-PSRemoting -Force`)
- **VSS:** Volume Shadow Copy service running on compute nodes
- **Network:** TCP port 5985 (WinRM HTTP) open between C&C and nodes
- **Disk:** Sufficient free space on C&C for backup storage
- **Optional:** 7-Zip installed on compute nodes for faster compression
- **Optional:** NAS/network share accessible from C&C for offsite backups

## Documentation

- [Quick Start Guide](docs/QUICKSTART.md) -- From download to first backup
- [C&C Server Setup](docs/SETUP-CC.md) -- Setting up the management machine
- [Compute Node Setup](docs/SETUP-NODE.md) -- Preparing game server machines
- [Instance Registration](docs/SETUP-INSTANCE.md) -- Registering Torch server instances
- [Configuration Reference](docs/CONFIG-REFERENCE.md) -- Every config field documented
- [Backup & Restore Guide](docs/BACKUP-RESTORE.md) -- How backups and restores work
- [Architecture](docs/ARCHITECTURE.md) -- System design and data flow
- [Discord Notifications](docs/DISCORD-SETUP.md) -- Setting up Discord alerts
- [Network & Bandwidth](docs/NETWORK.md) -- Bandwidth limiting and network topology
- [Troubleshooting](docs/TROUBLESHOOTING.md) -- Common problems and fixes

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

Copyright (c) 2026 SandboxServers
