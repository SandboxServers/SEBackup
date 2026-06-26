# Contributing to SEBackup

Thanks for your interest in contributing to SEBackup! This guide covers the conventions and workflow for the project.

## Development Setup

1. **PowerShell 7+** is required — [install from GitHub](https://github.com/PowerShell/PowerShell/releases)
2. Clone the repo and run `Install.ps1` to set up dependencies
3. Install [Pester](https://pester.dev/) for testing: `Install-Module Pester -Force`
4. Install [PSToml](https://www.powershellgallery.com/packages/PSToml) for config parsing: `Install-Module PSToml -Force`

## Project Structure

```
SEBackup/
├── SEBackup.psd1 / .psm1      # Root module (imports all sub-modules)
├── Config/                      # TOML configuration files
├── Modules/                     # One folder per sub-module
│   └── {ModuleName}/
│       ├── {ModuleName}.psm1    # Dot-source loader
│       ├── {ModuleName}.psd1    # Module manifest
│       ├── Public/              # Exported functions (one per file)
│       └── Private/             # Internal helpers (one per file)
├── Scripts/                     # CLI entry points and setup scripts
├── GUI/                         # WPF dashboard
├── NodeAgent/                   # Files deployed to compute nodes
├── Tests/                       # Pester tests
└── docs/                        # User-facing documentation
```

## Module Conventions

### One Function Per File

Every function lives in its own `.ps1` file named after the function. Public functions go in `Public/`, internal helpers go in `Private/`.

### Naming

All exported functions use the **SEB** prefix: `Verb-SEBNoun`

```powershell
# Good
function Invoke-SEBBackup { }
function Get-SEBNodeConfig { }
function Test-SEBArchiveIntegrity { }

# Bad — no prefix
function Invoke-Backup { }
function Get-Config { }
```

### Module Loader Pattern

Every `.psm1` uses this exact pattern:

```powershell
$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
```

### Function Documentation

Every exported function must have full comment-based help:

```powershell
function Get-SEBExample {
    <#
    .SYNOPSIS
        Brief one-line description.

    .DESCRIPTION
        Detailed description of what the function does.

    .PARAMETER Name
        Description of the parameter.

    .EXAMPLE
        Get-SEBExample -Name "test"
        Description of what this example does.

    .OUTPUTS
        System.String — describe the output object.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )
    # ...
}
```

### Error Handling

- Use `try/catch` blocks — never silently swallow errors
- Log via `Write-SEBLog` (check availability with `Get-Command Write-SEBLog -ErrorAction SilentlyContinue` first)
- VSS operations **must** use `try/finally` and always clean up shadow copies
- Notification failures must never block backup operations
- Return result objects with `Success` properties rather than throwing for expected failure modes

### Credentials

- **Never** store plaintext passwords
- Store node credentials via Save-/Update-SEBCredential, which protect the password with LocalMachine-scope DPAPI (ProtectedData) + per-machine entropy in the {Node}.cred envelope; do not reintroduce Export-Clixml for the write path.
- Credential files go in `Credentials/` and are `.gitignore`d

### Remote Execution

- Use `Invoke-SEBRemoteCommand` wrapper (not raw `Invoke-Command`) for retry logic and logging
- Use `New-SEBSession` for cached PSSession management
- Heavy file operations should run locally on the node, not stream over WinRM

## Adding a New Module

1. Create the folder structure:
   ```
   Modules/NewModule/
   ├── NewModule.psm1    # Copy the loader pattern above
   ├── NewModule.psd1    # Copy an existing manifest, update GUID and exports
   ├── Public/           # Your exported functions
   └── Private/          # Internal helpers
   ```

2. Generate a new GUID for the manifest: `[guid]::NewGuid()`

3. Add the module name to the `$Modules` array in `SEBackup.psm1`

4. Add exported functions to the `FunctionsToExport` array in `SEBackup.psd1`

5. Write Pester tests in `Tests/`

## Testing

Run the full test suite:

```powershell
Invoke-Pester -Path ./Tests/ -Output Detailed
```

Run tests for a specific module:

```powershell
Invoke-Pester -Path ./Tests/ConfigManager.Tests.ps1 -Output Detailed
```

### Continuous Integration

`build.ps1` is the single entry point GitHub-hosted CI uses (`.github/workflows/ci.yml`,
`windows-latest`); run it locally to reproduce CI exactly:

```powershell
./build.ps1                       # analyzer (Error+ParseError, baselined) + Pester (excludes E2E/Integration)
./build.ps1 -InstallDeps          # also installs the pinned PSToml / Pester / PSScriptAnalyzer versions
./build.ps1 -Coverage             # also measures coverage and enforces the ratchet gate (below)
./build.ps1 -InstallDeps -Coverage # exactly what CI runs
```

### Code coverage gate and ratchet

CI runs `build.ps1 -Coverage` (alias `-CodeCoverage`), which folds JaCoCo code coverage over
`Modules/` into the **same** Pester run (no second pass) and writes `coverage.xml` (gitignored;
uploaded as the `coverage-report` CI artifact next to `pester-results`/`testResults.xml`). Coverage
is **opt-in** because the breakpoint instrumentation adds measurable wall-clock — about **+14s**
on the current suite (~44s → ~58s, roughly a 30% increase) — so a plain `./build.ps1` quick run
skips it, and the gate only applies when coverage was actually measured.

The gate is a **ratchet**: coverage can hold or climb, never silently fall. It enforces **three**
independent checks so no single module can quietly shed its tests behind another module's gains,
and so the baseline itself can't be edited down to disarm the gate:

- The committed baseline lives in **`coverage-baseline.json`** (`{ "overall": <pct>, "perModule": { ... } }`).
  `overall` is Pester's JaCoCo overall %; each `perModule` value is that module's command hit-ratio
  (the same number the gate computes at runtime).
- **Overall ratchet** — the build **FAILS** if measured overall drops more than the tolerance
  (**0.30 pts** — ~15× the ~0.02pt run-to-run jitter) below `overall`.
- **Per-module ratchet** — the build also **FAILS** if **any** module's hit-ratio drops more than
  the same 0.30 pt tolerance below its **own** `perModule` baseline. This runs **every** build (not
  only when overall falls), so a module losing its tests trips the gate even if overall stays flat.
  A baseline module that produces **no** coverage (deleted, or its tests stopped running) also fails;
  a **new** module not yet in the map prints a `WARN` telling you to add its entry.
- **Absolute hard floor** — independent of the baseline, the build **FAILS** if the measured overall
  (or the committed `overall` itself) is below **50%** (a documented constant well under the real
  ~57.31%). This catches a gutted suite *and* a baseline tampered down to a tiny number.
- When coverage rises more than ~1 pt above the baseline, the build prints a
  `ratchet: baseline can be raised to X%` hint. It does **not** auto-raise — see below.

**Raising the baseline (do this when you add tests that lift coverage):**

1. Run `./build.ps1 -Coverage`. Note the printed overall % (and the ratchet hint). The build also
   prints each baseline module's current hit-ratio in the `== Coverage ratchet ==` block, plus a
   `WARN` line listing any **new** module not yet in the map.
2. Edit `coverage-baseline.json`:
   - Set `overall` to the new printed overall %.
   - **Update the `perModule` entries too** — the ratchet hint only mentions the overall, but the
     per-module floors are enforced independently, so raise each module you improved to its new
     current value, and **add an entry for any module the build WARNed was missing** (use the value
     it printed). Leaving a `perModule` value stale just keeps an old (lower) floor for that module;
     omitting a new module entirely means it stays ungated at the per-module level until you add it.
   - If a module was intentionally **removed** from `Modules/`, delete its `perModule` entry (the
     build FAILs on a baseline module that produced no coverage).
3. Commit it in the same PR. Raising the floor — overall *and* per-module — is deliberate so the new
   minimum is reviewed.

Never *lower* the `overall` or a `perModule` value to make a red build pass — fix the missing tests
instead. (A baseline `overall` below the 50% absolute floor is rejected outright as tampered.)

### Test Guidelines

- Unit tests should not require remote nodes or running game servers
- Mock remote operations with Pester's `Mock` command
- Test pure logic modules (ManifestManager, ConfigManager) thoroughly
- Integration/E2E tests that require real infrastructure (VSS, WinRM, a running Torch server, or
  real LocalMachine DPAPI) **must** be tagged `-Tag 'Integration'` or `-Tag 'E2E'` on the
  `Describe`/`Context`/`It`. `build.ps1` (and thus GitHub-hosted CI) excludes those tags — they
  can only pass on the local 3-instance Torch harness — so an untagged infra test runs on
  `windows-latest` and will fail CI.

## Pull Request Guidelines

1. **Branch** from `main` — use descriptive branch names (`feature/load-monitor`, `fix/vss-cleanup`)
2. **One PR per feature/fix** — keep changes focused
3. **Test** your changes — add or update Pester tests
4. **Document** new features — update relevant `docs/` files and function help
5. **Follow conventions** — SEB prefix, one function per file, full comment-based help

### PR Description Template

```markdown
## Summary
- Brief description of what changed and why

## Test plan
- [ ] How to verify this works
- [ ] Any specific scenarios to test

## Config changes
- List any new TOML fields added (with defaults)
```

## Common Tasks

### Testing VRage API connectivity
```powershell
Import-Module ./SEBackup.psd1
Test-SEBVRageAPI -Hostname "192.168.1.101" -Port 8080 -SecurityKey "Ab3dEf9H"
```

### Running a manual backup
```powershell
.\Scripts\Invoke-Backup.ps1 -NodeName "gaming-pc-01" -InstanceName "PvPArena" -ForceFull
```

### Checking node health
```powershell
.\Scripts\Test-NodeConnection.ps1 -NodeName "gaming-pc-01"
```
