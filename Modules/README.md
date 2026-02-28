# SEBackup Modules

This directory contains the 16 sub-modules that make up the SEBackup system. Each module is self-contained with its own manifest, loader, public functions, and private helpers.

## Module Structure Pattern

Every module follows the same directory layout:

```
Modules/
  ModuleName/
    ModuleName.psm1      # Dot-sources Public/ and Private/ scripts, exports Public
    ModuleName.psd1      # Module manifest with FunctionsToExport
    Public/              # One exported function per file (Verb-SEBNoun.ps1)
    Private/             # One internal helper per file (not exported)
    README.md            # Module documentation
```

### Standard .psm1 Loader Pattern

Every `.psm1` file uses this pattern to auto-import all functions:

```powershell
$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public  = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1"  -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
```

Some modules also define module-scoped variables (e.g., `$script:CachedGlobalConfig` in ConfigManager, `$script:SEBSessions` in RemoteManager) that are initialized at the top of the `.psm1` file.

## Module Load Order

The root `SEBackup.psm1` imports all 16 modules in this specific order:

| # | Module | Reason |
|---|--------|--------|
| 1 | Logger | Foundation -- all other modules depend on `Write-SEBLog` |
| 2 | ConfigManager | Configuration loading used by nearly everything |
| 3 | CredentialManager | Credential retrieval needed before remote connections |
| 4 | RemoteManager | WinRM sessions needed by VSS, Backup, Restore |
| 5 | VRageAPI | VRage Remote API client for world saves and server info |
| 6 | VSSManager | Volume Shadow Copy lifecycle management |
| 7 | ManifestManager | SHA256 file manifests and diff comparison |
| 8 | CompressionManager | Archive creation and extraction |
| 9 | IntegrityManager | Three-level backup integrity verification |
| 10 | LoadMonitor | CPU, memory, sim speed load checks |
| 11 | NetworkThrottle | Bandwidth-limited file transfers |
| 12 | NotificationManager | Discord webhook notifications |
| 13 | MetricsCollector | Backup metrics and statistics |
| 14 | BackupEngine | Full/incremental backup orchestration |
| 15 | RestoreEngine | Backup restoration and world reconstruction |
| 16 | SchedulerManager | Windows Task Scheduler integration |

## Module Dependency Graph

```
SchedulerManager -----> ConfigManager -----> PSToml (external)
     |                       ^
     v                       |
BackupEngine -------+--------+
     |              |
     |    +---------+---------+---------+---------+
     |    |         |         |         |         |
     v    v         v         v         v         v
RestoreEngine  LoadMonitor  Notif.Mgr  Metrics  IntegrityMgr
     |              |                              |
     |    +---------+                    +---------+---------+
     |    |                              |                   |
     v    v                              v                   v
VSSManager  NetworkThrottle      ManifestManager    CompressionMgr
     |              |                    |
     v              v                    v
RemoteManager ---> CredentialManager   (SHA256 hashing)
     |
     v
Logger (used by all modules)
```

**Explicit manifest-declared dependencies:**
- `ConfigManager` requires `PSToml` (external TOML parser module)
- `RemoteManager` requires `CredentialManager` (v1.0.0)

**Runtime dependencies (not declared in manifests but used via function calls):**
- Most modules call `Write-SEBLog` from Logger (checked at runtime via `Get-Command`)
- BackupEngine calls functions from ConfigManager, RemoteManager, VRageAPI, VSSManager, ManifestManager, CompressionManager, IntegrityManager, LoadMonitor, NetworkThrottle, NotificationManager, and MetricsCollector
- RestoreEngine calls functions from ConfigManager, RemoteManager, BackupEngine, IntegrityManager, NetworkThrottle, and NotificationManager
- IntegrityManager calls functions from ManifestManager and CompressionManager

## Quick Reference

| Module | Purpose | Exported | Key Functions |
|--------|---------|:--------:|---------------|
| **Logger** | Thread-safe daily-rotating structured logging | 5 | `Write-SEBLog`, `Get-SEBLogEntries` |
| **ConfigManager** | TOML config loading, caching, merging, validation | 5 | `Get-SEBGlobalConfig`, `Get-SEBInstanceConfig`, `Test-SEBConfig` |
| **CredentialManager** | DPAPI-encrypted credential storage | 4 | `Save-SEBCredential`, `Get-SEBCredential` |
| **RemoteManager** | WinRM session lifecycle and remote execution | 7 | `New-SEBSession`, `Invoke-SEBRemoteCommand`, `Test-SEBConnection` |
| **VRageAPI** | HMAC-SHA1 VRage Remote API client | 4 | `Save-SEBVRageWorld`, `Test-SEBVRageAPI` |
| **VSSManager** | VSS shadow copy creation, mounting, cleanup | 6 | `Invoke-SEBWithShadowCopy`, `New-SEBShadowCopy` |
| **ManifestManager** | SHA256 file manifests and diff comparison | 6 | `New-SEBManifest`, `Compare-SEBManifest`, `Get-SEBManifestChain` |
| **CompressionManager** | 7-Zip / .NET compression abstraction | 5 | `Compress-SEBArchive`, `Expand-SEBArchive` |
| **IntegrityManager** | Three-level backup integrity verification | 5 | `Test-SEBArchiveIntegrity`, `Test-SEBChainIntegrity` |
| **LoadMonitor** | CPU, memory, sim speed load checks with backoff | 3 | `Test-SEBNodeLoad`, `Wait-SEBNodeLoad` |
| **NetworkThrottle** | Bandwidth-limited transfers (BITS/robocopy) | 4 | `Copy-SEBThrottled`, `Start-SEBBitsTransfer` |
| **NotificationManager** | Discord webhook notifications | 4 | `Send-SEBNotification`, `Send-SEBBackupNotification` |
| **MetricsCollector** | Backup metrics, disk space, health summaries | 5 | `Add-SEBMetric`, `Get-SEBHealthSummary` |
| **BackupEngine** | Full/incremental backup orchestration | 4 | `Invoke-SEBBackup`, `Invoke-SEBBackupAll` |
| **RestoreEngine** | Point-in-time restore reconstruction | 4 | `Invoke-SEBRestore`, `Get-SEBRestorePoints` |
| **SchedulerManager** | Windows Task Scheduler integration | 4 | `Register-SEBScheduledTask`, `Get-SEBScheduleStatus` |

**Total exported functions: 71**

## Adding a New Module

Follow these steps to add a new sub-module to the SEBackup system:

1. **Create the directory structure:**
   ```
   Modules/NewModule/
   Modules/NewModule/Public/
   Modules/NewModule/Private/
   ```

2. **Create the module loader** (`Modules/NewModule/NewModule.psm1`) using the standard dot-source pattern shown above.

3. **Create the module manifest** (`Modules/NewModule/NewModule.psd1`) with:
   - `RootModule = 'NewModule.psm1'`
   - `FunctionsToExport` listing all public function names
   - `PowerShellVersion = '7.0'`
   - Any `RequiredModules` dependencies

4. **Create public functions** in `Modules/NewModule/Public/` with:
   - One function per file, filename matches function name
   - `Verb-SEBNoun` naming convention
   - `[CmdletBinding()]` and `[Parameter()]` attributes
   - Comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.OUTPUTS`)

5. **Create private helpers** in `Modules/NewModule/Private/` (no `SEB` prefix needed).

6. **Register the module** in the root `SEBackup.psm1` by adding the module name to the `$Modules` array.

7. **Add exports** to the root `SEBackup.psd1` manifest's `FunctionsToExport` list.

8. **Create tests** in `Tests/NewModule/` using Pester v5+.

9. **Create documentation** in `Modules/NewModule/README.md`.

## Naming Conventions

- **Exported functions:** `Verb-SEBNoun` (e.g., `Write-SEBLog`, `Invoke-SEBBackup`)
- **Private functions:** No `SEB` prefix (e.g., `Format-LogLine`, `Find-7ZipPath`)
- **Approved verbs:** Use standard PowerShell verbs (`Get`, `Set`, `New`, `Remove`, `Invoke`, `Test`, `Write`, `Start`, `Stop`, `Add`, `Clear`, `Compare`, `Compress`, `Expand`, `Export`, `Import`, `Mount`, `Dismount`, `Register`, `Unregister`, `Update`, `Copy`, `Read`, `Save`, `Send`, `Wait`)
- **Module-scoped variables:** Use `$script:` scope modifier
