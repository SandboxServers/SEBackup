#Requires -Version 7.0
<#
.SYNOPSIS
    Registers a Space Engineers Torch server instance on an already-configured node.

.DESCRIPTION
    Configures all components needed for SEBackup to manage a specific Torch server
    instance on a remote node. This includes auto-detecting paths, configuring the
    VRage Remote API, creating staging directories and SMB shares, and writing
    the instance configuration TOML file on the node.

    The node must already be set up using Setup-Node.ps1 before running this script.

    Steps performed:
    1.  Loads node config, gets credential, creates PSSession
    2.  Auto-detects Torch install path if not provided
    3.  Discovers data paths based on run_mode (service vs console)
    4.  Lists world saves and lets user select one (or uses -WorldName)
    5.  Checks VRage Remote API config in SpaceEngineers-Dedicated.cfg
    6.  Generates a random security key if needed
    7.  Creates staging directory on the node
    8.  Creates secured SMB share for the instance
    9.  Writes instance TOML config on the node
    10. Tests from C&C: SMB share access, VRage API ping
    11. Prints results summary

.PARAMETER NodeName
    The name of the previously configured node (must match a Config/nodes/{NodeName}.toml file).

.PARAMETER InstanceName
    A friendly name for this server instance. Used as the config filename and share identifier.

.PARAMETER TorchInstallPath
    The full path to the Torch server installation directory on the node. If not
    provided, common paths are searched and Windows services are checked.

.PARAMETER WorldName
    The name of the world save to back up. If not provided, the script lists
    available worlds and prompts for selection.

.PARAMETER RunMode
    How the Torch server runs: "service" (Windows service) or "console" (manual launch).
    Defaults to "service". Affects where data files are located.

.PARAMETER StagingDrive
    The drive letter to use for the staging directory on the node. Defaults to "D".
    The staging path will be {StagingDrive}:\SEBackup\staging\{InstanceName}\.

.PARAMETER VRagePort
    The TCP port for the VRage Remote API. Defaults to 8080.

.EXAMPLE
    .\Register-Instance.ps1 -NodeName "GameServer01" -InstanceName "PvPArena"
    # Auto-detects Torch path, prompts for world selection.

.EXAMPLE
    .\Register-Instance.ps1 -NodeName "GameServer01" -InstanceName "Creative" `
        -TorchInstallPath "D:\TorchServers\Creative" -WorldName "CreativeWorld" -RunMode console
    # Specifies all paths explicitly for a console-mode server.

.EXAMPLE
    .\Register-Instance.ps1 -NodeName "GameServer01" -InstanceName "Survival" `
        -StagingDrive "C" -VRagePort 8081
    # Uses C: drive for staging and a non-default VRage API port.

.OUTPUTS
    None. Results are displayed interactively via Write-Host.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$NodeName,

    [Parameter(Mandatory, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$InstanceName,

    [Parameter()]
    [string]$TorchInstallPath,

    [Parameter()]
    [string]$WorldName,

    [Parameter()]
    [ValidateSet('service', 'console')]
    [string]$RunMode = 'service',

    [Parameter()]
    [ValidatePattern('^[A-Z]$')]
    [string]$StagingDrive = 'D',

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$VRagePort = 8080
)

# ── Import SEBackup modules ──────────────────────────────────────────────────
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$modulesRoot = Join-Path $projectRoot 'Modules'

$requiredModules = @('ConfigManager', 'CredentialManager', 'RemoteManager', 'Logger', 'VRageAPI')
foreach ($mod in $requiredModules) {
    $modPath = Join-Path $modulesRoot "$mod\$mod.psm1"
    if (Test-Path $modPath) {
        Import-Module $modPath -Force -ErrorAction Stop
    }
    else {
        Write-Warning "Module not found: $modPath"
    }
}

# ── Results tracking ─────────────────────────────────────────────────────────
$checks = [ordered]@{
    'Node Config Loaded'  = $null
    'PSSession'           = $null
    'Torch Path Found'    = $null
    'Data Path Found'     = $null
    'World Selected'      = $null
    'VRage API Config'    = $null
    'Staging Directory'   = $null
    'SMB Share'           = $null
    'Instance Config'     = $null
    'SMB Access Test'     = $null
    'VRage API Test'      = $null
}

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║           SEBackup Instance Registration                    ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Node     : $NodeName" -ForegroundColor White
Write-Host "  Instance : $InstanceName" -ForegroundColor White
Write-Host "  Run Mode : $RunMode" -ForegroundColor White
Write-Host ''

# ══════════════════════════════════════════════════════════════════════════════
# Step 1: Load node config, get credential, create session
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[1/10] Loading node configuration...' -ForegroundColor Yellow
$nodeConfig = $null
$session = $null
$hostname = $null

try {
    $nodeConfig = Get-SEBNodeConfig -NodeName $NodeName
    if (-not $nodeConfig) {
        throw "Node config not found for '$NodeName'. Run Setup-Node.ps1 first."
    }
    $hostname = $nodeConfig.node.hostname
    $checks['Node Config Loaded'] = $true
    Write-Host "  [PASS] Node config loaded (hostname: $hostname)." -ForegroundColor Green
}
catch {
    $checks['Node Config Loaded'] = $false
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Run Setup-Node.ps1 to configure the node first.' -ForegroundColor DarkYellow
    return
}

Write-Host '[1/10] Creating PSSession...' -ForegroundColor Yellow
try {
    $session = New-SEBSession -NodeName $NodeName -NodeConfig $nodeConfig.node
    $checks['PSSession'] = $true
    Write-Host "  [PASS] PSSession established (ID: $($session.Id))." -ForegroundColor Green
}
catch {
    $checks['PSSession'] = $false
    Write-Host "  [FAIL] Cannot connect to node: $_" -ForegroundColor Red
    return
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 2: Auto-detect Torch install path if not provided
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[2/10] Locating Torch installation...' -ForegroundColor Yellow
$torchPath = $TorchInstallPath

if (-not $torchPath) {
    try {
        $torchPath = Invoke-Command -Session $session -ScriptBlock {
            param($InstanceName, $RunMode)

            $searchPaths = @(
                "C:\TorchServers\$InstanceName"
                "C:\Torch\$InstanceName"
                "D:\TorchServers\$InstanceName"
                'C:\TorchServers'
                'C:\Torch'
                'D:\TorchServers'
            )

            # Check specific instance paths first
            foreach ($path in $searchPaths) {
                $torchExe = Join-Path $path 'Torch.Server.exe'
                if (Test-Path $torchExe) {
                    return $path
                }
            }

            # Service mode: check for Windows services matching Torch
            if ($RunMode -eq 'service') {
                $torchServices = Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*Torch*' -or $_.DisplayName -like '*Torch*' }

                if ($torchServices) {
                    foreach ($svc in $torchServices) {
                        $svcPath = $svc.PathName -replace '"', '' -replace '\s+--.*$', ''
                        $svcDir = Split-Path $svcPath -Parent -ErrorAction SilentlyContinue
                        if ($svcDir -and (Test-Path $svcDir)) {
                            return $svcDir
                        }
                    }
                }
            }

            # Broad search in common parent directories
            $parentDirs = @('C:\TorchServers', 'D:\TorchServers', 'C:\Torch', 'D:\Torch')
            foreach ($parentDir in $parentDirs) {
                if (Test-Path $parentDir) {
                    $found = Get-ChildItem -Path $parentDir -Directory -ErrorAction SilentlyContinue |
                        Where-Object { Test-Path (Join-Path $_.FullName 'Torch.Server.exe') } |
                        Select-Object -First 1
                    if ($found) {
                        return $found.FullName
                    }
                }
            }

            return $null
        } -ArgumentList $InstanceName, $RunMode -ErrorAction Stop

        if ($torchPath) {
            $checks['Torch Path Found'] = $true
            Write-Host "  [PASS] Torch installation found: $torchPath" -ForegroundColor Green
        }
        else {
            $checks['Torch Path Found'] = $false
            Write-Host '  [FAIL] Could not auto-detect Torch installation.' -ForegroundColor Red
            Write-Host '         Specify -TorchInstallPath explicitly.' -ForegroundColor DarkYellow
            return
        }
    }
    catch {
        $checks['Torch Path Found'] = $false
        Write-Host "  [FAIL] Torch detection error: $_" -ForegroundColor Red
        return
    }
}
else {
    # Verify provided path exists
    $pathExists = Invoke-Command -Session $session -ScriptBlock {
        param($path)
        Test-Path $path -PathType Container
    } -ArgumentList $torchPath -ErrorAction SilentlyContinue

    if ($pathExists) {
        $checks['Torch Path Found'] = $true
        Write-Host "  [PASS] Torch path verified: $torchPath" -ForegroundColor Green
    }
    else {
        $checks['Torch Path Found'] = $false
        Write-Host "  [FAIL] Specified Torch path does not exist: $torchPath" -ForegroundColor Red
        return
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 3: Discover data paths based on run_mode
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[3/10] Discovering data paths...' -ForegroundColor Yellow
$dataRoot = $null

try {
    $dataRoot = Invoke-Command -Session $session -ScriptBlock {
        param($RunMode, $InstanceName)

        if ($RunMode -eq 'service') {
            # Service mode: ProgramData path
            $path = "C:\ProgramData\SpaceEngineersDedicated\$InstanceName"
            if (Test-Path $path) {
                return $path
            }
            # Try without instance name subfolder
            $path = 'C:\ProgramData\SpaceEngineersDedicated'
            if (Test-Path $path) {
                return $path
            }
        }
        else {
            # Console mode: AppData\Roaming
            $appDataPath = [Environment]::GetFolderPath('ApplicationData')
            $path = Join-Path $appDataPath 'SpaceEngineersDedicated'
            if (Test-Path $path) {
                return $path
            }
        }

        return $null
    } -ArgumentList $RunMode, $InstanceName -ErrorAction Stop

    if ($dataRoot) {
        $checks['Data Path Found'] = $true
        Write-Host "  [PASS] Data root: $dataRoot" -ForegroundColor Green
    }
    else {
        $checks['Data Path Found'] = $false
        Write-Host '  [WARN] Data path not found. This is normal for first-time setups.' -ForegroundColor DarkYellow
        # Use default path for config generation
        if ($RunMode -eq 'service') {
            $dataRoot = "C:\ProgramData\SpaceEngineersDedicated\$InstanceName"
        }
        else {
            $dataRoot = '%APPDATA%\SpaceEngineersDedicated'
        }
        Write-Host "         Using default: $dataRoot" -ForegroundColor DarkGray
        $checks['Data Path Found'] = $true
    }
}
catch {
    $checks['Data Path Found'] = $false
    Write-Host "  [FAIL] Data path discovery error: $_" -ForegroundColor Red
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 4: List world saves, let user select
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[4/10] Discovering world saves...' -ForegroundColor Yellow
$selectedWorld = $WorldName

if (-not $selectedWorld) {
    try {
        $worlds = Invoke-Command -Session $session -ScriptBlock {
            param($DataRoot)

            $savesPath = Join-Path $DataRoot 'Saves'
            if (-not (Test-Path $savesPath)) {
                return @()
            }

            $worldDirs = Get-ChildItem -Path $savesPath -Directory -ErrorAction SilentlyContinue
            $worldList = [System.Collections.Generic.List[object]]::new()

            foreach ($dir in $worldDirs) {
                $sandboxFile = Join-Path $dir.FullName 'Sandbox.sbc'
                $hasSandbox = Test-Path $sandboxFile
                $lastModified = $dir.LastWriteTime

                $worldList.Add(@{
                    Name         = $dir.Name
                    Path         = $dir.FullName
                    HasSandbox   = $hasSandbox
                    LastModified = $lastModified
                })
            }

            return $worldList.ToArray()
        } -ArgumentList $dataRoot -ErrorAction Stop

        if ($worlds -and $worlds.Count -gt 0) {
            Write-Host ''
            Write-Host '  Available worlds:' -ForegroundColor White
            for ($i = 0; $i -lt $worlds.Count; $i++) {
                $world = $worlds[$i]
                $worldName = if ($world -is [hashtable]) { $world.Name } else { $world.Name }
                $lastMod = if ($world -is [hashtable]) { $world.LastModified } else { $world.LastModified }
                Write-Host "    [$($i + 1)] $worldName  (Last modified: $lastMod)" -ForegroundColor White
            }
            Write-Host ''

            do {
                $selection = Read-Host '  Select a world (enter number)'
                $selectionInt = 0
                $valid = [int]::TryParse($selection, [ref]$selectionInt)
            } while (-not $valid -or $selectionInt -lt 1 -or $selectionInt -gt $worlds.Count)

            $selectedWorldObj = $worlds[$selectionInt - 1]
            $selectedWorld = if ($selectedWorldObj -is [hashtable]) { $selectedWorldObj.Name } else { $selectedWorldObj.Name }

            $checks['World Selected'] = $true
            Write-Host "  [PASS] Selected world: $selectedWorld" -ForegroundColor Green
        }
        else {
            Write-Host '  [WARN] No world saves found. You can configure this later.' -ForegroundColor DarkYellow
            $selectedWorld = 'UNCONFIGURED'
            $checks['World Selected'] = $true
        }
    }
    catch {
        Write-Host "  [WARN] Could not list worlds: $_" -ForegroundColor DarkYellow
        $selectedWorld = 'UNCONFIGURED'
        $checks['World Selected'] = $true
    }
}
else {
    $checks['World Selected'] = $true
    Write-Host "  [PASS] Using specified world: $selectedWorld" -ForegroundColor Green
}

# Build world save path
$worldSavePath = if ($dataRoot -like '*%*') {
    "$dataRoot\Saves\$selectedWorld"
}
else {
    Join-Path $dataRoot "Saves\$selectedWorld"
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 5: Check VRage Remote API configuration
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[5/10] Checking VRage Remote API configuration...' -ForegroundColor Yellow
$vrageSecurityKey = $null

try {
    $vrageResult = Invoke-Command -Session $session -ScriptBlock {
        param($DataRoot, $DesiredPort)

        $result = @{
            ConfigFound     = $false
            ApiEnabled      = $false
            SecurityKey     = $null
            Port            = $null
            ConfigPath      = $null
            Modified        = $false
            Error           = $null
        }

        # Look for the dedicated server config file
        $configPaths = @(
            (Join-Path $DataRoot 'SpaceEngineers-Dedicated.cfg')
            (Join-Path $DataRoot 'SpaceEngineers-Dedicated.cfg.bak')
        )

        $configPath = $null
        foreach ($cp in $configPaths) {
            if (Test-Path $cp) {
                $configPath = $cp
                break
            }
        }

        if (-not $configPath) {
            $result.Error = 'SpaceEngineers-Dedicated.cfg not found'
            return $result
        }

        $result.ConfigFound = $true
        $result.ConfigPath = $configPath

        try {
            [xml]$xml = Get-Content -Path $configPath -Raw -ErrorAction Stop

            $apiEnabled = $xml.SelectSingleNode('//RemoteApiEnabled')
            $securityKey = $xml.SelectSingleNode('//RemoteSecurityKey')
            $apiPort = $xml.SelectSingleNode('//RemoteApiPort')

            $result.ApiEnabled = if ($apiEnabled) { $apiEnabled.InnerText -eq 'true' } else { $false }
            $result.SecurityKey = if ($securityKey) { $securityKey.InnerText } else { $null }
            $result.Port = if ($apiPort) { [int]$apiPort.InnerText } else { $null }
        }
        catch {
            $result.Error = "Failed to parse config XML: $($_.Exception.Message)"
        }

        return $result
    } -ArgumentList $dataRoot, $VRagePort -ErrorAction Stop

    if ($vrageResult.ConfigFound) {
        if ($vrageResult.ApiEnabled -and $vrageResult.SecurityKey) {
            $vrageSecurityKey = $vrageResult.SecurityKey
            $VRagePort = if ($vrageResult.Port) { $vrageResult.Port } else { $VRagePort }
            $checks['VRage API Config'] = $true
            Write-Host "  [PASS] VRage API is enabled (port: $VRagePort)." -ForegroundColor Green
        }
        else {
            Write-Host '  [NOTE] VRage Remote API is not enabled or has no security key.' -ForegroundColor DarkYellow

            $enableApi = Read-Host '  Enable VRage Remote API and generate a security key? (Y/n)'
            if ($enableApi -ne 'n' -and $enableApi -ne 'N') {
                # Generate random security key
                $vrageSecurityKey = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ })

                $enableResult = Invoke-Command -Session $session -ScriptBlock {
                    param($ConfigPath, $SecurityKey, $Port)

                    try {
                        [xml]$xml = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop

                        # Set or create RemoteApiEnabled
                        $apiNode = $xml.SelectSingleNode('//RemoteApiEnabled')
                        if ($apiNode) {
                            $apiNode.InnerText = 'true'
                        }
                        else {
                            $root = $xml.DocumentElement
                            $newNode = $xml.CreateElement('RemoteApiEnabled')
                            $newNode.InnerText = 'true'
                            $root.AppendChild($newNode) | Out-Null
                        }

                        # Set or create RemoteSecurityKey
                        $keyNode = $xml.SelectSingleNode('//RemoteSecurityKey')
                        if ($keyNode) {
                            $keyNode.InnerText = $SecurityKey
                        }
                        else {
                            $root = $xml.DocumentElement
                            $newNode = $xml.CreateElement('RemoteSecurityKey')
                            $newNode.InnerText = $SecurityKey
                            $root.AppendChild($newNode) | Out-Null
                        }

                        # Set or create RemoteApiPort
                        $portNode = $xml.SelectSingleNode('//RemoteApiPort')
                        if ($portNode) {
                            $portNode.InnerText = $Port.ToString()
                        }
                        else {
                            $root = $xml.DocumentElement
                            $newNode = $xml.CreateElement('RemoteApiPort')
                            $newNode.InnerText = $Port.ToString()
                            $root.AppendChild($newNode) | Out-Null
                        }

                        $xml.Save($ConfigPath)
                        return @{ Success = $true; Error = $null }
                    }
                    catch {
                        return @{ Success = $false; Error = $_.Exception.Message }
                    }
                } -ArgumentList $vrageResult.ConfigPath, $vrageSecurityKey, $VRagePort -ErrorAction Stop

                if ($enableResult.Success) {
                    $checks['VRage API Config'] = $true
                    Write-Host "  [PASS] VRage API enabled with key: $vrageSecurityKey" -ForegroundColor Green
                    Write-Host '         NOTE: Restart the Torch server for changes to take effect.' -ForegroundColor DarkYellow
                }
                else {
                    $checks['VRage API Config'] = $false
                    Write-Host "  [FAIL] Could not update config: $($enableResult.Error)" -ForegroundColor Red
                }
            }
            else {
                $checks['VRage API Config'] = $false
                Write-Host '  [SKIP] VRage API not configured. Backup world saves via API will not work.' -ForegroundColor DarkYellow
                $vrageSecurityKey = ''
            }
        }
    }
    else {
        $checks['VRage API Config'] = $false
        Write-Host "  [WARN] $($vrageResult.Error)" -ForegroundColor DarkYellow
        Write-Host '         VRage API config can be set up later.' -ForegroundColor DarkGray
        $vrageSecurityKey = ''
    }
}
catch {
    $checks['VRage API Config'] = $false
    Write-Host "  [FAIL] VRage API check error: $_" -ForegroundColor Red
    $vrageSecurityKey = ''
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 6: Create staging directory on the node
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[6/10] Creating staging directory...' -ForegroundColor Yellow
$stagingPath = "${StagingDrive}:\SEBackup\staging\$InstanceName"

try {
    $stagingResult = Invoke-Command -Session $session -ScriptBlock {
        param($StagingPath)

        if (-not (Test-Path $StagingPath)) {
            New-Item -Path $StagingPath -ItemType Directory -Force | Out-Null
            return @{ Created = $true; Path = $StagingPath }
        }
        return @{ Created = $false; Path = $StagingPath }
    } -ArgumentList $stagingPath -ErrorAction Stop

    $checks['Staging Directory'] = $true
    if ($stagingResult.Created) {
        Write-Host "  [PASS] Staging directory created: $stagingPath" -ForegroundColor Green
    }
    else {
        Write-Host "  [PASS] Staging directory already exists: $stagingPath" -ForegroundColor Green
    }
}
catch {
    $checks['Staging Directory'] = $false
    Write-Host "  [FAIL] Staging directory creation failed: $_" -ForegroundColor Red
    Write-Host "         Verify that drive ${StagingDrive}: exists on the node." -ForegroundColor DarkYellow
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 7: Create secured SMB share
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[7/10] Creating SMB share...' -ForegroundColor Yellow
$shareName = "SEBackup_${InstanceName}`$"
$shareNameClean = "SEBackup_${InstanceName}$"  # For display/use
$nodeUsername = $nodeConfig.node.username
if (-not $nodeUsername) { $nodeUsername = 'SEBackup' }

try {
    $shareResult = Invoke-Command -Session $session -ScriptBlock {
        param($ShareName, $SharePath, $Username)

        $result = @{ Created = $false; AlreadyExists = $false; Error = $null }

        # Get the computer name for the full user reference
        $computerName = $env:COMPUTERNAME

        # Check if share already exists
        $existingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
        if ($existingShare) {
            $result.AlreadyExists = $true
            return $result
        }

        try {
            New-SmbShare -Name $ShareName `
                -Path $SharePath `
                -FullAccess "$computerName\$Username" `
                -NoAccess 'Everyone' `
                -ErrorAction Stop | Out-Null
            $result.Created = $true
        }
        catch {
            $result.Error = $_.Exception.Message
        }

        return $result
    } -ArgumentList $shareNameClean, $stagingPath, $nodeUsername -ErrorAction Stop

    if ($shareResult.Created) {
        $checks['SMB Share'] = $true
        Write-Host "  [PASS] SMB share created: $shareNameClean" -ForegroundColor Green
    }
    elseif ($shareResult.AlreadyExists) {
        $checks['SMB Share'] = $true
        Write-Host "  [PASS] SMB share already exists: $shareNameClean" -ForegroundColor Green
    }
    else {
        $checks['SMB Share'] = $false
        Write-Host "  [FAIL] SMB share creation failed: $($shareResult.Error)" -ForegroundColor Red
    }
}
catch {
    $checks['SMB Share'] = $false
    Write-Host "  [FAIL] SMB share error: $_" -ForegroundColor Red
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 8: Write instance TOML config on the node
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[8/10] Writing instance configuration on node...' -ForegroundColor Yellow

# Escape backslashes for TOML basic strings ("C:\Foo" must be written "C:\\Foo").
$torchPathToml = $torchPath -replace '\\', '\\\\'
$worldSavePathToml = $worldSavePath -replace '\\', '\\\\'
$stagingPathToml = $stagingPath -replace '\\', '\\\\'
$dataRootToml = $dataRoot -replace '\\', '\\\\'

# Canonical instance schema -- the keys the SEBackup engine actually reads at runtime
# (see Modules/BackupEngine/Public/Invoke-SEBBackup.ps1, Modules/RestoreEngine, and
# Modules/BackupEngine/Private/Test-SEBPreFlight.ps1). The operational keys
# (run_mode, world_path, staging_path, share_name) are FLAT top-level keys and MUST appear
# before any [table] header -- in TOML, bare keys after a header belong to that table, so
# nesting them under [instance] (as older versions did) made the engine read $null for all
# of them. [vrage_api] is the one nested table the engine reads (port / security_key).
$instanceToml = @"
# SEBackup Instance Configuration: $InstanceName
# Generated by Register-Instance.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

# --- Operational keys read by the backup/restore engine (must stay top-level) ---
run_mode     = "$RunMode"
world_path   = "$worldSavePathToml"
staging_path = "$stagingPathToml"
share_name   = "$shareNameClean"

[instance]
name         = "$InstanceName"
display_name = "$InstanceName"

[vrage_api]
port         = $VRagePort
security_key = "$vrageSecurityKey"

# Informational paths discovered during registration (not required by the engine).
[torch]
install_path = "$torchPathToml"
data_root    = "$dataRootToml"
"@

try {
    if ($PSCmdlet.ShouldProcess("Instance config on node for $InstanceName", 'Write')) {
        Invoke-Command -Session $session -ScriptBlock {
            param($InstanceName, $TomlContent)

            $instanceConfigPath = "C:\SEBackup\instances\$InstanceName.toml"
            Set-Content -Path $instanceConfigPath -Value $TomlContent -Encoding UTF8 -Force
            return $instanceConfigPath
        } -ArgumentList $InstanceName, $instanceToml -ErrorAction Stop
    }

    $checks['Instance Config'] = $true
    Write-Host "  [PASS] Instance config written: C:\SEBackup\instances\$InstanceName.toml" -ForegroundColor Green
}
catch {
    $checks['Instance Config'] = $false
    Write-Host "  [FAIL] Instance config write failed: $_" -ForegroundColor Red
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 9: Test SMB share access from C&C
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[9/10] Testing SMB share access from C&C...' -ForegroundColor Yellow
try {
    $credential = Get-SEBCredential -NodeName $NodeName
    $uncPath = "\\$hostname\$shareNameClean"
    $shareOk = Test-SEBShare -SharePath $uncPath -Credential $credential

    if ($shareOk) {
        $checks['SMB Access Test'] = $true
        Write-Host "  [PASS] SMB share accessible: $uncPath" -ForegroundColor Green
    }
    else {
        $checks['SMB Access Test'] = $false
        Write-Host "  [FAIL] Cannot access SMB share: $uncPath" -ForegroundColor Red
        Write-Host '         Check firewall rules and share permissions on the node.' -ForegroundColor DarkYellow
    }
}
catch {
    $checks['SMB Access Test'] = $false
    Write-Host "  [FAIL] SMB access test error: $_" -ForegroundColor Red
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 10: Test VRage API from C&C
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[10/10] Testing VRage Remote API...' -ForegroundColor Yellow
if ($vrageSecurityKey) {
    try {
        $vrageOk = Test-SEBVRageAPI -Hostname $hostname -Port $VRagePort -SecurityKey $vrageSecurityKey

        if ($vrageOk) {
            $checks['VRage API Test'] = $true
            Write-Host "  [PASS] VRage API responding at ${hostname}:${VRagePort}." -ForegroundColor Green
        }
        else {
            $checks['VRage API Test'] = $false
            Write-Host '  [FAIL] VRage API not responding.' -ForegroundColor Red
            Write-Host '         The Torch server may not be running or may need a restart.' -ForegroundColor DarkYellow
            Write-Host '         The API will work once the server is running with the updated config.' -ForegroundColor DarkGray
        }
    }
    catch {
        $checks['VRage API Test'] = $false
        Write-Host "  [FAIL] VRage API test error: $_" -ForegroundColor Red
    }
}
else {
    $checks['VRage API Test'] = 'Skipped'
    Write-Host '  [SKIP] VRage API not configured. Skipping test.' -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════════════════════
# Final Results Summary
# ══════════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║              Instance Registration Results                  ║' -ForegroundColor Cyan
Write-Host '╠══════════════════════════════════════════════════════════════╣' -ForegroundColor Cyan

$passCount = 0
$failCount = 0
$skipCount = 0

foreach ($check in $checks.GetEnumerator()) {
    $status = $check.Value
    $name = $check.Key.PadRight(22)

    if ($status -eq $true) {
        $passCount++
        $icon = 'PASS'
        $color = 'Green'
    }
    elseif ($status -eq $false) {
        $failCount++
        $icon = 'FAIL'
        $color = 'Red'
    }
    else {
        $skipCount++
        $icon = 'SKIP'
        $color = 'DarkGray'
    }

    Write-Host "║  [$icon]  $name                           ║" -ForegroundColor $color
}

Write-Host '╠══════════════════════════════════════════════════════════════╣' -ForegroundColor Cyan
Write-Host "║  Total: $passCount passed, $failCount failed, $skipCount skipped" -ForegroundColor White
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan

if ($failCount -eq 0) {
    Write-Host ''
    Write-Host "  Instance '$InstanceName' on node '$NodeName' is ready for backups!" -ForegroundColor Green
    Write-Host ''
    Write-Host '  Next steps:' -ForegroundColor White
    Write-Host "    1. Start/restart the Torch server if VRage API config was changed" -ForegroundColor DarkGray
    Write-Host "    2. Run a test backup:" -ForegroundColor DarkGray
    Write-Host "       .\Invoke-Backup.ps1 -NodeName '$NodeName' -InstanceName '$InstanceName'" -ForegroundColor DarkGray
}
else {
    Write-Host ''
    Write-Host "  Instance '$InstanceName' registration completed with errors." -ForegroundColor Yellow
    Write-Host '  Please review the failures above.' -ForegroundColor White
}

Write-Host ''

# Cleanup session
if ($session) {
    Remove-SEBSession -NodeName $NodeName -ErrorAction SilentlyContinue
}
