# SEBackup - Claude Code Instructions

This is the SEBackup project: a Space Engineers Torch Server Backup & Restore System built in PowerShell 7. Read and follow these instructions when working on this codebase.

## Project Overview

SEBackup is a Command & Control (C&C) system that manages backups across multiple Space Engineers Torch server instances running on remote Windows compute nodes. It uses WinRM/PSRemoting for remote execution, VSS for zero-downtime snapshots, and a three-tier storage model (node staging, C&C local, NAS offload).

## Module Structure

Every module lives under `Modules/{ModuleName}/` and follows this exact pattern:

```
Modules/
  ModuleName/
    ModuleName.psm1      # Dot-sources Public/ and Private/ scripts, exports Public
    ModuleName.psd1      # Module manifest with FunctionsToExport
    Public/              # One exported function per file
      Verb-SEBNoun.ps1
    Private/             # One internal function per file
      Helper-Function.ps1
```

- **One function per file.** The file name must match the function name.
- **Public/** functions are exported and available to callers.
- **Private/** functions are internal to that module only.
- Every `.psm1` file uses this pattern to auto-import:

```powershell
$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
```

## Naming Conventions

- **All exported functions** use the `SEB` prefix: `Verb-SEBNoun` (e.g., `Write-SEBLog`, `Invoke-SEBBackup`, `New-SEBShadowCopy`).
- **Private/internal functions** do NOT use the `SEB` prefix (e.g., `Format-LogLine`, `Find-7ZipPath`, `Resolve-ConfigPaths`).
- **Use approved PowerShell verbs** (Get, Set, New, Remove, Invoke, Test, Write, Read, Start, Stop, etc.).
- **Module-scoped variables** use the `$script:` scope modifier.

## Configuration System

- Config format: **TOML** via the `PSToml` module (`ConvertFrom-Toml` / `ConvertTo-Toml`).
- **C&C configs** live in `Config/` on the C&C machine:
  - `Config/global.toml` -- system-wide settings
  - `Config/nodes/{nodename}.toml` -- per-node connection info
- **Node configs** live in `C:\SEBackup\instances\` on each compute node:
  - `C:\SEBackup\instances\{instancename}.toml` -- per-instance settings
- Example configs with full documentation are provided as `*.example.toml` files.
- The `ConfigManager` module handles loading, caching, merging defaults, and validation.

## Dependencies

- **Required:** PSToml (TOML parser for PowerShell)
- **Optional:** 7Zip4Powershell (faster compression; falls back to System.IO.Compression)
- **System:** PowerShell 7.0+, Windows 10/Server 2016+, WinRM enabled, VSS service

## Testing

- Test framework: **Pester** (v5+)
- Test files go in `Tests/{ModuleName}/` directories.
- Root-level integration tests go in `Tests/`.
- Test file naming: `{FunctionName}.Tests.ps1` or `{ModuleName}.Tests.ps1`
- Run tests: `Invoke-Pester -Path Tests/`

## Adding a New Module

1. Create the directory: `Modules/NewModule/`
2. Create subdirectories: `Modules/NewModule/Public/`, `Modules/NewModule/Private/`
3. Create `Modules/NewModule/NewModule.psm1` using the standard dot-source pattern above.
4. Create `Modules/NewModule/NewModule.psd1` with `FunctionsToExport` listing all public functions.
5. Add the module name to the `$Modules` array in the root `SEBackup.psm1`.
6. Add the exported functions to `FunctionsToExport` in the root `SEBackup.psd1`.
7. Create test files in `Tests/NewModule/`.

## Error Handling Rules

- **Always** use `try/catch` around operations that can fail (file I/O, remote calls, API requests).
- **Always** log errors via `Write-SEBLog -Level ERROR -Message "..."`.
- **Never** silently swallow errors. At minimum, log them.
- Use `-ErrorAction Stop` on cmdlets inside try blocks to ensure errors are caught.
- Return `$null` or a result object with error information; do not throw unhandled exceptions from exported functions unless the situation is truly unrecoverable.

## VSS (Volume Shadow Copy) Rules

- **ALWAYS** use `try/finally` when working with shadow copies.
- **ALWAYS** clean up shadow copies in the `finally` block, even if the operation fails.
- Use `Invoke-SEBWithShadowCopy` when possible -- it handles the lifecycle automatically.
- Orphan cleanup: `Clear-SEBOrphanShadowCopies` removes leftover shadow copies.
- VSS operations run on compute nodes via `Invoke-SEBRemoteCommand`.

## Credential Handling Rules

- Credentials are stored using **DPAPI encryption** via `Export-Clixml` / `Import-Clixml`.
- Credential files live in `Credentials/{nodename}.cred.xml`.
- **Never** store plaintext passwords in config files, scripts, or logs.
- Use `Save-SEBCredential` / `Get-SEBCredential` from the CredentialManager module.
- DPAPI credentials are machine-and-user bound. They only work for the user who created them on the same machine.

## Remote Execution Rules

- **Always** use `Invoke-SEBRemoteCommand` from the RemoteManager module for remote operations.
- **Never** use raw `Invoke-Command` directly -- the wrapper provides retry logic, session management, logging, and error handling.
- Sessions are created via `New-SEBSession` and cleaned up via `Remove-SEBSession`.
- Test connectivity first with `Test-SEBConnection`.

## Logging

- Use `Write-SEBLog` for all log output. Do not use `Write-Host` in module code (except in Install.ps1 and interactive scripts).
- Available levels: `DEBUG`, `INFO`, `WARN`, `ERROR`.
- Use `Start-SEBLogContext` / `Stop-SEBLogContext` to set a context prefix for a block of operations.
- Log files are daily-rotating: `Logs/SEBackup_yyyy-MM-dd.log`.

## Code Style

- Use full cmdlet names, not aliases (`Get-ChildItem` not `gci`, `ForEach-Object` not `%`).
- Use `[CmdletBinding()]` on all functions.
- Use `[Parameter()]` attributes with `Mandatory`, `Position`, `ValidateSet`, etc.
- Include comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.OUTPUTS`) on all public functions.
- Use `[OutputType()]` attributes where the return type is known.

## Key File Locations

```
SEBackup.psm1              # Root module (imports all sub-modules)
SEBackup.psd1              # Root module manifest
Install.ps1                # C&C first-run installer
Config/global.toml         # Global configuration
Config/nodes/              # Per-node config files
Credentials/               # DPAPI-encrypted credential files
Logs/                      # Daily rotating log files
Data/lockfiles/            # Backup operation lock files
Modules/                   # All sub-modules
Scripts/                   # Standalone operational scripts
GUI/                       # WPF dashboard (future)
NodeAgent/                 # Files deployed to compute nodes
Tests/                     # Pester test files
docs/                      # Documentation
```
