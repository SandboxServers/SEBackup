# System Architecture

This document describes the SEBackup system architecture, module dependencies, and data flows.

## High-Level Architecture

SEBackup uses a hub-and-spoke model where a central Command & Control (C&C) server orchestrates backup operations across one or more remote compute nodes.

```
                        +---------------------+
                        |    Discord / Alerts  |
                        +----------^----------+
                                   |
                                   | Webhook
                                   |
+-----------------------------------------------------------------------+
|                          C&C Server                                   |
|                                                                       |
|  +-------------+   +-----------+   +-----------+   +---------------+  |
|  | Config      |   | Scheduler |   | Backup    |   | Restore       |  |
|  | Manager     |   | Manager   |   | Engine    |   | Engine        |  |
|  +------+------+   +-----+-----+   +-----+-----+   +-------+-------+  |
|         |               |               |                   |         |
|  +------+------+   +-----+-----+   +-----+-----+   +-------+-------+  |
|  | Credential  |   | Load      |   | Manifest  |   | Compression   |  |
|  | Manager     |   | Monitor   |   | Manager   |   | Manager       |  |
|  +------+------+   +-----------+   +-----------+   +---------------+  |
|         |                                                             |
|  +------+------+   +-----------+   +-----------+   +---------------+  |
|  | Remote      |   | Network   |   | Integrity |   | Notification  |  |
|  | Manager     |   | Throttle  |   | Manager   |   | Manager       |  |
|  +------+------+   +-----------+   +-----------+   +---------------+  |
|         |                                                             |
|  +------+------+   +-----------+   +-----------+   +---------------+  |
|  | VRage API   |   | VSS       |   | Logger    |   | Metrics       |  |
|  | Client      |   | Manager   |   |           |   | Collector     |  |
|  +-------------+   +-----------+   +-----------+   +---------------+  |
|         |                |                                            |
+---------|----------------|--------------------------------------------+
          |                |
          | WinRM (5985)   | SMB File Transfer
          |                |
+---------v----------------v--------------------------------------------+
|                      Compute Node                                     |
|                                                                       |
|  +-------------------+  +-------------------+  +-------------------+  |
|  | Torch Instance A  |  | Torch Instance B  |  | Torch Instance C  |  |
|  | (VRage API :8080) |  | (VRage API :8081) |  | (VRage API :8082) |  |
|  +-------------------+  +-------------------+  +-------------------+  |
|                                                                       |
|  +-----------------------+  +--------------------+                    |
|  | C:\SEBackup\staging\  |  | VSS Shadow Copies  |                    |
|  | (SMB shared)          |  | (temporary)        |                    |
|  +-----------------------+  +--------------------+                    |
|                                                                       |
+-----------------------------------------------------------------------+
          |
          | SMB / Robocopy / BITS
          v
+-----------------------------------------------------------------------+
|                        NAS / Network Storage                          |
|                        (Optional long-term)                           |
+-----------------------------------------------------------------------+
```

## Module Dependency Graph

Arrows point from the dependent module to the module it depends on.

```
BackupEngine
  |-- ConfigManager
  |-- CredentialManager
  |-- RemoteManager
  |     |-- CredentialManager
  |-- VRageAPI
  |-- VSSManager
  |-- ManifestManager
  |-- CompressionManager
  |-- IntegrityManager
  |     |-- ManifestManager
  |     |-- CompressionManager
  |-- LoadMonitor
  |     |-- VRageAPI (for sim speed)
  |-- NetworkThrottle
  |-- NotificationManager
  |-- MetricsCollector
  `-- Logger

RestoreEngine
  |-- ConfigManager
  |-- RemoteManager
  |-- ManifestManager
  |-- CompressionManager
  |-- IntegrityManager
  |-- NetworkThrottle
  |-- NotificationManager
  `-- Logger

SchedulerManager
  |-- ConfigManager
  |-- BackupEngine
  `-- Logger

All modules --> Logger (logging)
All modules --> ConfigManager (configuration, where applicable)
```

## Data Flow: Backup Operation

```
Step 1: INITIATION
+----------+                     +-----------+
| Schedule |---> or manual --->  | Backup    |
| Manager  |     invocation      | Engine    |
+----------+                     +-----+-----+
                                       |
Step 2: LOAD CHECK                     v
                                 +-----+-----+
                                 | Load      |  Queries CPU, memory,
                                 | Monitor   |  sim speed on node
                                 +-----+-----+
                                       |
                                       | OK to proceed?
                                       v
Step 3: WORLD SAVE              +------+------+
                                 | VRage API  |  Sends save command
                                 | Client     |  to Torch via HTTP
                                 +------+------+
                                       |
Step 4: VSS SNAPSHOT                   v
                          +------+-----+------+------+
                          | Remote     | VSS         |  Creates shadow
                          | Manager    | Manager     |  copy on node
                          +------+-----+------+------+
                                       |
Step 5: MANIFEST                       v
                                 +-----+-----+
                                 | Manifest  |  Walks VSS snapshot,
                                 | Manager   |  generates SHA256 hashes
                                 +-----+-----+
                                       |
Step 6: COMPARE & COMPRESS            v
                          +------+-----+------+------+
                          | Manifest   | Compression |  Compares manifests,
                          | Manager    | Manager     |  compresses changed files
                          +------+-----+------+------+
                                       |
Step 7: VSS CLEANUP                    v
                                 +-----+-----+
                                 | VSS       |  Removes shadow copy
                                 | Manager   |  (always, via finally)
                                 +-----+-----+
                                       |
Step 8: TRANSFER                       v
                          +------+-----+------+------+
                          | Network    | Remote      |  Transfers archive
                          | Throttle   | Manager     |  from node to C&C
                          +------+-----+------+------+
                                       |
Step 9: NAS OFFLOAD (optional)        v
                                 +-----+-----+
                                 | Network   |  Copies archive
                                 | Throttle  |  from C&C to NAS
                                 +-----+-----+
                                       |
Step 10: VERIFY                        v
                                 +-----+-----+
                                 | Integrity |  Checks archive CRC,
                                 | Manager   |  manifest cross-ref
                                 +-----+-----+
                                       |
Step 11: CLEANUP                       v
                                 +-----+-----+
                                 | Backup    |  Prunes old backups
                                 | Engine    |  per retention policy
                                 +-----+-----+
                                       |
Step 12: NOTIFY                        v
                                 +-----+-----+
                                 | Notif.    |  Sends Discord alert
                                 | Manager   |  with result summary
                                 +-----+-----+
```

## Data Flow: Restore Operation

```
Step 1: IDENTIFY CHAIN
+-------+     +----------+     +-----------+
| User  |---> | Restore  |---> | Manifest  |  Find full backup +
| Input |     | Engine   |     | Manager   |  all incrementals
+-------+     +-----+----+     +-----------+  in the chain
                    |
Step 2: EXTRACT FULL
                    v
              +-----+------+
              | Compression |  Extract base full
              | Manager     |  archive to temp dir
              +-----+------+
                    |
Step 3: APPLY INCREMENTALS (for each)
                    v
              +-----+------+
              | Compression |  Extract incremental
              | Manager     |  on top of previous
              +-----+------+
                    |
Step 4: APPLY DELETIONS
                    v
              +-----+------+
              | Manifest   |  Remove files that
              | Manager    |  were deleted in chain
              +-----+------+
                    |
Step 5: VERIFY RESTORED STATE
                    v
              +-----+------+
              | Integrity  |  Hash restored files,
              | Manager    |  compare to manifest
              +-----+------+
                    |
Step 6: DEPLOY (optional)
                    v
              +-----+------+     +----------+
              | Remote     |---> | Compute  |  Copy restored files
              | Manager    |     | Node     |  to live server path
              +-----+------+     +----------+
                    |
Step 7: NOTIFY
                    v
              +-----+------+
              | Notif.     |  Send restore result
              | Manager    |  notification
              +-----------+
```

## File System Layout

### C&C Server

```
C:\SEBackup\                        # Project root (or wherever you cloned it)
  SEBackup.psm1                     # Root module
  SEBackup.psd1                     # Root manifest
  Install.ps1                       # First-run installer
  Config\
    global.toml                     # System-wide config
    global.example.toml             # Example with documentation
    node.example.toml               # Example node config
    nodes\
      GamePC01.toml                 # Per-node config
      GamePC02.toml
  Credentials\
    GamePC01.cred                   # LocalMachine-DPAPI credentials (.cred.xml = legacy, migrated on first read)
    GamePC02.cred
  Logs\
    SEBackup_2026-02-27.log         # Daily rotating logs
  Data\
    lockfiles\
      GamePC01_PvPArena.lock        # Backup operation locks
  Modules\
    Logger\                         # (16 sub-module directories)
    ConfigManager\
    ...
  Scripts\                          # Operational scripts
  GUI\                              # WPF dashboard (future)
  Tests\                            # Pester tests
  docs\                             # Documentation

C:\SEBackup\Backups\                # Backup storage (configurable)
  GamePC01\
    PvPArena\
      manifests\                    # JSON manifest files
      archives\                     # Compressed backup archives
    Survival\
      manifests\
      archives\
```

### Compute Node

```
C:\SEBackup\                        # NodeAgent root
  instances\
    PvPArena.toml                   # Instance config
    Survival.toml
    instance.example.toml           # Example config
  staging\
    PvPArena\                       # Staging area (SMB shared)
    Survival\
  logs\                             # Node-side logs
  vss_mount\                        # Temporary VSS mount point
```

## Security Model

- **Credentials:** Stored encrypted with LocalMachine-scope DPAPI + per-machine entropy, machine-bound (not user-bound), ACL-restricted; see docs/UNATTENDED-AUTH.md. Never stored in plaintext.
- **WinRM:** Uses PowerShell Remoting over HTTP (port 5985) by default. Can be configured for HTTPS (port 5986) for encryption in transit.
- **SMB Shares:** Hidden shares (suffixed with `$`) with access restricted to Administrators.
- **VRage API:** Authenticated with HMAC-SHA1 signatures (nonce + date + key).
- **Least Privilege:** Only the SEBackup service account has access to backup shares and credentials.

## Threading and Concurrency

- **Log writes** are protected by a named system mutex (`Global\SEBackupLoggerMutex`), allowing multiple processes/runspaces to log concurrently without file corruption.
- **Backup operations** use per-instance lock files (`Data/lockfiles/{node}_{instance}.lock`) to prevent concurrent backups of the same instance.
- **Config reads** are cached with a configurable TTL (default 60 seconds) to avoid redundant file I/O.
