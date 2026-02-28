#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    First-run setup script for the SEBackup Command & Control (C&C) server.

.DESCRIPTION
    Run this script once on the machine that will serve as the SEBackup C&C server.
    It checks prerequisites, installs required PowerShell modules, creates the
    project directory structure, copies example configuration files, tests WinRM
    client configuration, and prints a summary of next steps.

    This script does NOT configure remote compute nodes. To set up a compute node,
    see docs/SETUP-NODE.md or run Setup-Node.ps1 after completing this script.

.EXAMPLE
    # Run from an elevated PowerShell 7 prompt:
    .\Install.ps1

.EXAMPLE
    # Run with verbose output for troubleshooting:
    .\Install.ps1 -Verbose

.NOTES
    Requires: PowerShell 7.0+, Administrator privileges, Internet access (for
    module installation).
#>
[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
$banner = @"

  ============================================================
   SEBackup - Space Engineers Torch Server Backup & Restore
   Command & Control (C&C) First-Run Installer
  ============================================================

"@
Write-Host $banner -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Step 1: Check PowerShell version
# ---------------------------------------------------------------------------
Write-Host "[1/7] Checking PowerShell version..." -ForegroundColor White

$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -lt 7) {
    Write-Host "  FAIL: PowerShell 7.0 or later is required." -ForegroundColor Red
    Write-Host "  You are running PowerShell $psVersion." -ForegroundColor Red
    Write-Host "  Download PowerShell 7: https://aka.ms/powershell-release?tag=stable" -ForegroundColor Yellow
    exit 1
}
Write-Host "  OK: PowerShell $psVersion" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 2: Install PSToml module
# ---------------------------------------------------------------------------
Write-Host "`n[2/7] Checking for PSToml module..." -ForegroundColor White

$psToml = Get-Module -Name PSToml -ListAvailable -ErrorAction SilentlyContinue
if ($psToml) {
    Write-Host "  OK: PSToml $($psToml[0].Version) is already installed." -ForegroundColor Green
} else {
    Write-Host "  Installing PSToml module from PSGallery..." -ForegroundColor Yellow
    try {
        Install-Module -Name PSToml -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
        $psToml = Get-Module -Name PSToml -ListAvailable
        Write-Host "  OK: PSToml $($psToml[0].Version) installed successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "  FAIL: Could not install PSToml: $_" -ForegroundColor Red
        Write-Host "  Try running: Install-Module -Name PSToml -Force -Scope AllUsers" -ForegroundColor Yellow
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Step 3: Optionally install 7Zip4Powershell module
# ---------------------------------------------------------------------------
Write-Host "`n[3/7] Checking for 7Zip4Powershell module (optional)..." -ForegroundColor White

$sevenZipMod = Get-Module -Name 7Zip4Powershell -ListAvailable -ErrorAction SilentlyContinue
if ($sevenZipMod) {
    Write-Host "  OK: 7Zip4Powershell $($sevenZipMod[0].Version) is already installed." -ForegroundColor Green
} else {
    Write-Host "  7Zip4Powershell is not installed. This module is optional." -ForegroundColor Yellow
    Write-Host "  It provides faster compression than the built-in .NET compression." -ForegroundColor Yellow
    $install7z = Read-Host "  Install 7Zip4Powershell now? (y/N)"
    if ($install7z -eq 'y' -or $install7z -eq 'Y') {
        try {
            Install-Module -Name 7Zip4Powershell -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
            $sevenZipMod = Get-Module -Name 7Zip4Powershell -ListAvailable
            Write-Host "  OK: 7Zip4Powershell $($sevenZipMod[0].Version) installed." -ForegroundColor Green
        }
        catch {
            Write-Host "  WARNING: Could not install 7Zip4Powershell: $_" -ForegroundColor Yellow
            Write-Host "  This is optional. SEBackup will use .NET compression as a fallback." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Skipped. SEBackup will use .NET compression (System.IO.Compression)." -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# Step 4: Create directory structure
# ---------------------------------------------------------------------------
Write-Host "`n[4/7] Creating directory structure..." -ForegroundColor White

$projectRoot = $PSScriptRoot
$directories = @(
    (Join-Path $projectRoot 'Config')
    (Join-Path $projectRoot 'Config' 'nodes')
    (Join-Path $projectRoot 'Credentials')
    (Join-Path $projectRoot 'Logs')
    (Join-Path $projectRoot 'Data')
    (Join-Path $projectRoot 'Data' 'lockfiles')
)

$createdDirs = @()
foreach ($dir in $directories) {
    if (-not (Test-Path -Path $dir -PathType Container)) {
        try {
            New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            $createdDirs += $dir
            Write-Host "  Created: $dir" -ForegroundColor Green
        }
        catch {
            Write-Host "  FAIL: Could not create '$dir': $_" -ForegroundColor Red
        }
    } else {
        Write-Host "  Exists:  $dir" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# Step 5: Copy example configs if real configs don't exist
# ---------------------------------------------------------------------------
Write-Host "`n[5/7] Checking configuration files..." -ForegroundColor White

$configFiles = @(
    @{
        Example = Join-Path $projectRoot 'Config' 'global.example.toml'
        Real    = Join-Path $projectRoot 'Config' 'global.toml'
        Name    = 'global.toml'
    }
)

foreach ($cfg in $configFiles) {
    if (-not (Test-Path -Path $cfg.Real -PathType Leaf)) {
        if (Test-Path -Path $cfg.Example -PathType Leaf) {
            try {
                Copy-Item -Path $cfg.Example -Destination $cfg.Real -ErrorAction Stop
                Write-Host "  Created: $($cfg.Name) (copied from example)" -ForegroundColor Green
                Write-Host "    >> IMPORTANT: Edit $($cfg.Real) before running backups!" -ForegroundColor Yellow
            }
            catch {
                Write-Host "  FAIL: Could not copy example config for $($cfg.Name): $_" -ForegroundColor Red
            }
        } else {
            Write-Host "  WARNING: Example config not found: $($cfg.Example)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Exists:  $($cfg.Name)" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# Step 6: Test WinRM client configuration
# ---------------------------------------------------------------------------
Write-Host "`n[6/7] Testing WinRM client configuration..." -ForegroundColor White

try {
    $winrmService = Get-Service -Name WinRM -ErrorAction Stop
    if ($winrmService.Status -eq 'Running') {
        Write-Host "  OK: WinRM service is running." -ForegroundColor Green
    } else {
        Write-Host "  WARNING: WinRM service exists but is not running (status: $($winrmService.Status))." -ForegroundColor Yellow
        Write-Host "  Start it with: Start-Service WinRM" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "  WARNING: Could not query WinRM service: $_" -ForegroundColor Yellow
    Write-Host "  WinRM is needed for remote node management. Run:" -ForegroundColor Yellow
    Write-Host "    Enable-PSRemoting -Force" -ForegroundColor Yellow
}

# Check TrustedHosts
try {
    $trustedHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
    if ([string]::IsNullOrWhiteSpace($trustedHosts)) {
        Write-Host "  NOTE: TrustedHosts is empty. You will need to add your compute node" -ForegroundColor Yellow
        Write-Host "  hostnames or IP addresses before connecting. Example:" -ForegroundColor Yellow
        Write-Host '    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.1.101,192.168.1.102"' -ForegroundColor Yellow
    } else {
        Write-Host "  OK: TrustedHosts = $trustedHosts" -ForegroundColor Green
    }
}
catch {
    Write-Host "  NOTE: Could not read TrustedHosts. WinRM may not be configured." -ForegroundColor Yellow
    Write-Host "  Run: Enable-PSRemoting -Force" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Step 7: Print setup summary and next steps
# ---------------------------------------------------------------------------
Write-Host "`n[7/7] Setup summary" -ForegroundColor White
Write-Host "  ============================================================" -ForegroundColor Cyan

$summary = @(
    @{ Label = "PowerShell";        Status = "v$psVersion" }
    @{ Label = "PSToml";            Status = if ($psToml) { "v$($psToml[0].Version)" } else { "MISSING" } }
    @{ Label = "7Zip4Powershell";   Status = if ($sevenZipMod) { "v$($sevenZipMod[0].Version)" } else { "Not installed (optional)" } }
    @{ Label = "Directory structure"; Status = if ($createdDirs.Count -gt 0) { "$($createdDirs.Count) created" } else { "All present" } }
)

foreach ($item in $summary) {
    $color = if ($item.Status -match 'MISSING') { 'Red' } elseif ($item.Status -match 'optional') { 'Yellow' } else { 'Green' }
    Write-Host ("  {0,-22} {1}" -f $item.Label, $item.Status) -ForegroundColor $color
}

Write-Host "  ============================================================" -ForegroundColor Cyan

Write-Host "`n  Next steps:" -ForegroundColor White
Write-Host "  1. Edit Config\global.toml with your storage paths and preferences." -ForegroundColor Yellow
Write-Host "  2. For each compute node, run:" -ForegroundColor Yellow
Write-Host "       .\Scripts\Setup-Node.ps1 -NodeName <name> -Hostname <ip_or_hostname>" -ForegroundColor Gray
Write-Host "  3. For each Torch server instance, run:" -ForegroundColor Yellow
Write-Host "       .\Scripts\Register-Instance.ps1 -NodeName <node> -InstanceName <name>" -ForegroundColor Gray
Write-Host "  4. Run your first backup:" -ForegroundColor Yellow
Write-Host "       .\Scripts\Invoke-Backup.ps1 -All" -ForegroundColor Gray
Write-Host "  5. (Optional) Register a scheduled task:" -ForegroundColor Yellow
Write-Host "       .\Scripts\Register-Schedule.ps1 -Action Register" -ForegroundColor Gray
Write-Host ""
Write-Host "  For detailed instructions, see:" -ForegroundColor White
Write-Host "    docs\QUICKSTART.md" -ForegroundColor Gray
Write-Host "    docs\SETUP-CC.md" -ForegroundColor Gray
Write-Host "    docs\SETUP-NODE.md" -ForegroundColor Gray
Write-Host "    docs\SETUP-INSTANCE.md" -ForegroundColor Gray
Write-Host ""
Write-Host "  SEBackup C&C setup complete." -ForegroundColor Green
Write-Host ""
