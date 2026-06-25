#Requires -Version 7.0
<#
.SYNOPSIS
    Bootstraps the SEBackup NodeAgent directory structure on a compute node.

.DESCRIPTION
    Called by Setup-Node.ps1 via Invoke-Command to initialize the C:\SEBackup
    directory structure on a remote Space Engineers Torch server node. This
    script is designed to run on the node itself (not from the C&C).

    Steps performed:
    1. Creates the directory structure: C:\SEBackup\instances\, C:\SEBackup\staging\, C:\SEBackup\logs\
    2. Copies instance.example.toml to C:\SEBackup\instances\ (generated inline)
    3. Installs the PSToml module if not present
    4. Verifies 7-Zip is installed and notes the result
    5. Returns a results object summarizing what was created/installed

.EXAMPLE
    # Typically invoked remotely from Setup-Node.ps1:
    Invoke-Command -Session $session -ScriptBlock { & C:\SEBackup\NodeAgent\Install-NodeAgent.ps1 }

.EXAMPLE
    # Or run directly on the node:
    .\Install-NodeAgent.ps1

.OUTPUTS
    PSCustomObject
    A results object with properties: DirectoriesCreated, PSTomlInstalled,
    SevenZipAvailable, SevenZipPath, ExampleConfigCreated, Errors.
#>
[CmdletBinding()]
param()

$results = [PSCustomObject]@{
    DirectoriesCreated   = [System.Collections.Generic.List[string]]::new()
    PSTomlInstalled      = $false
    PSTomlAlreadyPresent = $false
    SevenZipAvailable    = $false
    SevenZipPath         = $null
    ExampleConfigCreated = $false
    Errors               = [System.Collections.Generic.List[string]]::new()
}

# -----------------------------------------------------------------
# Step 1: Create directory structure
# -----------------------------------------------------------------
$baseDir = 'C:\SEBackup'
$directories = @(
    $baseDir
    (Join-Path $baseDir 'instances')
    (Join-Path $baseDir 'staging')
    (Join-Path $baseDir 'logs')
)

foreach ($dir in $directories) {
    try {
        if (-not (Test-Path -Path $dir -PathType Container)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            $results.DirectoriesCreated.Add($dir)
        }
    }
    catch {
        $results.Errors.Add("Failed to create directory '$dir': $_")
    }
}

# -----------------------------------------------------------------
# Step 2: Create instance.example.toml
# -----------------------------------------------------------------
$exampleTomlPath = Join-Path $baseDir 'instances\instance.example.toml'
$exampleTomlContent = @'
# SEBackup Instance Configuration
# Copy this file and rename it to match your instance name (e.g., MyServer.toml).
# All paths use Windows-style double backslashes.
#
# Register-Instance.ps1 normally writes this file for you. The operational keys
# (run_mode, world_path, staging_path, share_name) are TOP-LEVEL and must stay
# above the first [table] header -- in TOML a bare key after a "[section]" header
# belongs to that section, so moving them under [instance] makes the engine read
# them as missing.

# --- Operational keys read by the backup/restore engine ---
run_mode     = "service"            # "service" or "console"
world_path   = "C:\\ProgramData\\SpaceEngineersDedicated\\MyServer\\Saves\\MyWorld"
staging_path = "D:\\SEBackup\\staging\\MyServer"
share_name   = "SEBackup_MyServer$"

[instance]
name         = "MyServer"
display_name = "My Space Engineers Server"

[vrage_api]
port         = 8080
security_key = ""                   # Base64 Remote API key; set during Register-Instance

# Informational only (not required by the engine):
# [torch]
# install_path = "C:\\TorchServer"
# data_root    = "C:\\ProgramData\\SpaceEngineersDedicated\\MyServer"

# Optional overrides (uncomment to override global.toml defaults):
# [compression]
# engine     = "7zip"
# level_7zip = 5
'@

try {
    if (-not (Test-Path -Path $exampleTomlPath)) {
        Set-Content -Path $exampleTomlPath -Value $exampleTomlContent -Encoding UTF8 -Force
        $results.ExampleConfigCreated = $true
    }
    else {
        # File already exists, skip
        $results.ExampleConfigCreated = $false
    }
}
catch {
    $results.Errors.Add("Failed to create example config: $_")
}

# -----------------------------------------------------------------
# Step 3: Install PSToml module if not present
# -----------------------------------------------------------------
try {
    $psToml = Get-Module -Name PSToml -ListAvailable -ErrorAction SilentlyContinue
    if ($psToml) {
        $results.PSTomlAlreadyPresent = $true
        $results.PSTomlInstalled = $false
    }
    else {
        Install-Module -Name PSToml -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
        $results.PSTomlInstalled = $true
    }
}
catch {
    $results.Errors.Add("Failed to install PSToml module: $_")
}

# -----------------------------------------------------------------
# Step 4: Verify 7-Zip is installed
# -----------------------------------------------------------------
$sevenZipPaths = @(
    (Join-Path $env:ProgramFiles '7-Zip\7z.exe')
    (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
    'C:\Program Files\7-Zip\7z.exe'
)

foreach ($szPath in $sevenZipPaths) {
    if ($szPath -and (Test-Path -Path $szPath -PathType Leaf)) {
        $results.SevenZipAvailable = $true
        $results.SevenZipPath = $szPath
        break
    }
}

if (-not $results.SevenZipAvailable) {
    # Not an error -- backup will fall back to Compress-Archive
    # Just note it in results
    $results.SevenZipPath = $null
}

return $results
