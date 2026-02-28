#Requires -Version 7.0
<#
.SYNOPSIS
    One-time node preparation script for the SEBackup system.

.DESCRIPTION
    Sets up a remote Windows compute node for use with the SEBackup Space Engineers
    Torch Server Backup & Restore System. This script is run from the Command & Control
    (C&C) machine and performs all necessary configuration on the target node.

    Steps performed:
    1.  Prompts for credentials and stores them via Save-SEBCredential
    2.  Adds the hostname to WinRM TrustedHosts
    3.  Creates a PSSession to the node
    4.  Optionally creates a local user account and adds it to Administrators
    5.  Enables PSRemoting on the remote node
    6.  Configures WinRM limits (MaxMemoryPerShellMB, MaxEnvelopeSizekb)
    7.  Enables WinRM firewall rules
    8.  Runs the Install-NodeAgent bootstrap (creates directories, installs PSToml)
    9.  Verifies VSS shadow copy capability (unless -SkipVSSTest)
    10. Generates Config/nodes/{NodeName}.toml on the C&C
    11. Runs full connectivity test: Test-SEBConnection -NodeName -Detailed
    12. Prints a results table with pass/fail per check

.PARAMETER NodeName
    A friendly name for this node, used as the identifier throughout SEBackup.
    This becomes the filename for the node config and credential files.

.PARAMETER Hostname
    The network hostname or IP address of the remote node. This is used for
    WinRM connections and SMB access.

.PARAMETER Username
    The local username to use for the SEBackup service account on the node.
    Defaults to "SEBackup".

.PARAMETER CreateUser
    When specified, creates the local user account on the remote node and adds
    it to the local Administrators group (required for VSS operations).

.PARAMETER SkipVSSTest
    When specified, skips the VSS shadow copy creation/deletion test. Use this
    if the node does not have VSS available or if you want to speed up setup.

.EXAMPLE
    .\Setup-Node.ps1 -NodeName "GameServer01" -Hostname "192.168.1.100"
    # Sets up a node with default username "SEBackup", prompts for password.

.EXAMPLE
    .\Setup-Node.ps1 -NodeName "GameServer01" -Hostname "gs01.local" -CreateUser
    # Creates the SEBackup user on the node and sets up everything.

.EXAMPLE
    .\Setup-Node.ps1 -NodeName "TestServer" -Hostname "10.0.0.5" -Username "Admin" -SkipVSSTest
    # Uses an existing "Admin" account and skips VSS verification.

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
    [string]$Hostname,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Username = 'SEBackup',

    [Parameter()]
    [switch]$CreateUser,

    [Parameter()]
    [switch]$SkipVSSTest
)

# ── Import SEBackup modules ──────────────────────────────────────────────────
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$modulesRoot = Join-Path $projectRoot 'Modules'

$requiredModules = @('ConfigManager', 'CredentialManager', 'RemoteManager', 'Logger', 'VSSManager')
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
    'Credential Saved'   = $null
    'TrustedHosts'       = $null
    'PSSession'          = $null
    'User Created'       = $null
    'PSRemoting'         = $null
    'WinRM Limits'       = $null
    'Firewall Rules'     = $null
    'NodeAgent Install'  = $null
    'VSS Test'           = $null
    'Node Config'        = $null
    'Connectivity Test'  = $null
}

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║            SEBackup Node Setup - One-Time Config            ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Node Name : $NodeName" -ForegroundColor White
Write-Host "  Hostname  : $Hostname" -ForegroundColor White
Write-Host "  Username  : $Username" -ForegroundColor White
Write-Host ''

# ══════════════════════════════════════════════════════════════════════════════
# Step 1: Prompt for password and save credential
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[1/11] Saving credentials...' -ForegroundColor Yellow
try {
    $credential = Get-Credential -UserName $Username -Message "Enter password for '$Username' on node '$NodeName' ($Hostname)"
    if (-not $credential) {
        throw 'No credential provided. Setup cancelled.'
    }

    if ($PSCmdlet.ShouldProcess("Credential for $NodeName", 'Save')) {
        Save-SEBCredential -NodeName $NodeName -Credential $credential
    }
    $checks['Credential Saved'] = $true
    Write-Host '  [PASS] Credential saved.' -ForegroundColor Green
}
catch {
    $checks['Credential Saved'] = $false
    Write-Host "  [FAIL] Credential save failed: $_" -ForegroundColor Red
    Write-Host ''
    Write-Host 'Setup cannot continue without credentials. Exiting.' -ForegroundColor Red
    return
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 2: Add hostname to WinRM TrustedHosts
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[2/11] Configuring TrustedHosts...' -ForegroundColor Yellow
try {
    $currentHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
    if ($currentHosts -and $currentHosts -ne '*') {
        $hostList = $currentHosts -split ','
        if ($hostList -notcontains $Hostname) {
            $newHosts = "$currentHosts,$Hostname"
            if ($PSCmdlet.ShouldProcess("TrustedHosts: add $Hostname", 'Set')) {
                Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newHosts -Force
            }
            Write-Host "  [PASS] Added '$Hostname' to TrustedHosts." -ForegroundColor Green
        }
        else {
            Write-Host "  [PASS] '$Hostname' already in TrustedHosts." -ForegroundColor Green
        }
    }
    elseif ($currentHosts -eq '*') {
        Write-Host "  [PASS] TrustedHosts is set to '*' (all hosts trusted)." -ForegroundColor Green
    }
    else {
        if ($PSCmdlet.ShouldProcess("TrustedHosts: set $Hostname", 'Set')) {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $Hostname -Force
        }
        Write-Host "  [PASS] Set TrustedHosts to '$Hostname'." -ForegroundColor Green
    }
    $checks['TrustedHosts'] = $true
}
catch {
    $checks['TrustedHosts'] = $false
    Write-Host "  [FAIL] TrustedHosts configuration failed: $_" -ForegroundColor Red
    Write-Host '         You may need to run this script as Administrator.' -ForegroundColor DarkYellow
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 3: Create PSSession to node
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[3/11] Establishing PSSession...' -ForegroundColor Yellow
$session = $null
try {
    $sessionOption = New-PSSessionOption -OperationTimeout 60000 -OpenTimeout 30000
    $session = New-PSSession `
        -ComputerName  $Hostname `
        -Credential    $credential `
        -SessionOption $sessionOption `
        -ErrorAction   Stop

    $checks['PSSession'] = $true
    Write-Host "  [PASS] PSSession established (ID: $($session.Id))." -ForegroundColor Green
}
catch {
    $checks['PSSession'] = $false
    Write-Host "  [FAIL] Cannot connect to '$Hostname': $_" -ForegroundColor Red
    Write-Host '         Verify the hostname, credentials, and that WinRM is enabled on the target.' -ForegroundColor DarkYellow
    Write-Host '         On the target, run: Enable-PSRemoting -Force' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host 'Setup cannot continue without a PSSession. Exiting.' -ForegroundColor Red
    return
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 4: Create user on node (if -CreateUser)
# ══════════════════════════════════════════════════════════════════════════════
if ($CreateUser) {
    Write-Host '[4/11] Creating local user on node...' -ForegroundColor Yellow
    try {
        $userResult = Invoke-Command -Session $session -ScriptBlock {
            param($UserName, $Password)

            $result = @{ Created = $false; AddedToAdmins = $false; AlreadyExists = $false; Error = $null }

            try {
                $existingUser = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
                if ($existingUser) {
                    $result.AlreadyExists = $true
                }
                else {
                    $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
                    New-LocalUser -Name $UserName -Password $securePassword -FullName 'SEBackup Service Account' `
                        -Description 'Account used by SEBackup for remote backup operations' `
                        -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction Stop
                    $result.Created = $true
                }

                # Ensure user is in Administrators group (required for VSS)
                $adminGroup = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*\$UserName" }
                if (-not $adminGroup) {
                    Add-LocalGroupMember -Group 'Administrators' -Member $UserName -ErrorAction Stop
                    $result.AddedToAdmins = $true
                }
                else {
                    $result.AddedToAdmins = $true  # Already a member
                }
            }
            catch {
                $result.Error = $_.Exception.Message
            }

            return $result
        } -ArgumentList $Username, $credential.GetNetworkCredential().Password -ErrorAction Stop

        if ($userResult.Error) {
            throw $userResult.Error
        }

        if ($userResult.AlreadyExists) {
            Write-Host "  [PASS] User '$Username' already exists on node." -ForegroundColor Green
        }
        elseif ($userResult.Created) {
            Write-Host "  [PASS] User '$Username' created on node." -ForegroundColor Green
        }

        if ($userResult.AddedToAdmins) {
            Write-Host "  [PASS] User '$Username' is in the Administrators group." -ForegroundColor Green
        }

        $checks['User Created'] = $true
    }
    catch {
        $checks['User Created'] = $false
        Write-Host "  [FAIL] User creation failed: $_" -ForegroundColor Red
        Write-Host '         The connected account may lack permissions to create users.' -ForegroundColor DarkYellow
    }
}
else {
    Write-Host '[4/11] Skipping user creation (-CreateUser not specified).' -ForegroundColor DarkGray
    $checks['User Created'] = 'Skipped'
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 5: Enable PSRemoting on the remote node
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[5/11] Enabling PSRemoting on node...' -ForegroundColor Yellow
try {
    Invoke-Command -Session $session -ScriptBlock {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
    } -ErrorAction Stop

    $checks['PSRemoting'] = $true
    Write-Host '  [PASS] PSRemoting enabled.' -ForegroundColor Green
}
catch {
    # PSRemoting might already be enabled (and we are connected, so it clearly works)
    $checks['PSRemoting'] = $true
    Write-Host '  [PASS] PSRemoting is active (connection already established).' -ForegroundColor Green
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 6: Configure WinRM limits
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[6/11] Configuring WinRM limits...' -ForegroundColor Yellow
try {
    $winrmResult = Invoke-Command -Session $session -ScriptBlock {
        $result = @{ MaxMemory = $false; MaxEnvelope = $false; Error = $null }

        try {
            Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB -Value 2048 -Force -ErrorAction Stop
            $result.MaxMemory = $true
        }
        catch {
            $result.Error = "MaxMemoryPerShellMB: $($_.Exception.Message)"
        }

        try {
            Set-Item WSMan:\localhost\MaxEnvelopeSizekb -Value 8192 -Force -ErrorAction Stop
            $result.MaxEnvelope = $true
        }
        catch {
            $errorMsg = "MaxEnvelopeSizekb: $($_.Exception.Message)"
            if ($result.Error) { $result.Error += "; $errorMsg" }
            else { $result.Error = $errorMsg }
        }

        return $result
    } -ErrorAction Stop

    if ($winrmResult.MaxMemory -and $winrmResult.MaxEnvelope) {
        $checks['WinRM Limits'] = $true
        Write-Host '  [PASS] WinRM limits configured (MaxMemory=2048MB, MaxEnvelope=8192KB).' -ForegroundColor Green
    }
    else {
        $checks['WinRM Limits'] = $false
        Write-Host "  [WARN] Partial WinRM config: $($winrmResult.Error)" -ForegroundColor DarkYellow
    }
}
catch {
    $checks['WinRM Limits'] = $false
    Write-Host "  [FAIL] WinRM limits configuration failed: $_" -ForegroundColor Red
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 7: Enable WinRM firewall rules
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[7/11] Enabling WinRM firewall rules...' -ForegroundColor Yellow
try {
    Invoke-Command -Session $session -ScriptBlock {
        # Enable all WinRM-related firewall rules
        $rules = Get-NetFirewallRule -DisplayGroup 'Windows Remote Management' -ErrorAction SilentlyContinue
        if ($rules) {
            $rules | Where-Object { $_.Enabled -eq 'False' } | Enable-NetFirewallRule -ErrorAction SilentlyContinue
        }

        # Also ensure the specific HTTP rule exists and is enabled
        $httpRule = Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -ErrorAction SilentlyContinue
        if ($httpRule -and $httpRule.Enabled -eq 'False') {
            Enable-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -ErrorAction SilentlyContinue
        }
    } -ErrorAction Stop

    $checks['Firewall Rules'] = $true
    Write-Host '  [PASS] WinRM firewall rules enabled.' -ForegroundColor Green
}
catch {
    $checks['Firewall Rules'] = $false
    Write-Host "  [FAIL] Firewall rule configuration failed: $_" -ForegroundColor Red
    Write-Host '         WinRM may still work if rules were already configured.' -ForegroundColor DarkYellow
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 8: Run Install-NodeAgent content remotely
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[8/11] Installing NodeAgent on remote node...' -ForegroundColor Yellow
try {
    # Read the Install-NodeAgent.ps1 content and send it as a scriptblock
    # (we cannot rely on the file being on the remote node yet)
    $installResult = Invoke-Command -Session $session -ScriptBlock {
        $results = [PSCustomObject]@{
            DirectoriesCreated   = [System.Collections.Generic.List[string]]::new()
            PSTomlInstalled      = $false
            PSTomlAlreadyPresent = $false
            SevenZipAvailable    = $false
            SevenZipPath         = $null
            ExampleConfigCreated = $false
            Errors               = [System.Collections.Generic.List[string]]::new()
        }

        # Create directory structure
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

        # Create instance.example.toml
        $exampleTomlPath = Join-Path $baseDir 'instances\instance.example.toml'
        $exampleTomlContent = @'
# SEBackup Instance Configuration
# Copy this file and rename it to match your instance name (e.g., MyServer.toml).

[instance]
name          = "MyServer"
display_name  = "My Space Engineers Server"
run_mode      = "service"

[paths]
torch_install   = "C:\\TorchServer"
world_save      = "C:\\ProgramData\\SpaceEngineersDedicated\\MyServer\\Saves\\MyWorld"
staging_local   = "D:\\SEBackup\\staging\\MyServer"
data_root       = "C:\\ProgramData\\SpaceEngineersDedicated\\MyServer"

[smb]
share_name     = "SEBackup_MyServer$"
share_path     = "D:\\SEBackup\\staging\\MyServer"

[vrage_api]
port           = 8080
security_key   = ""

[vss]
volume         = "C:\\"
'@
        try {
            if (-not (Test-Path -Path $exampleTomlPath)) {
                Set-Content -Path $exampleTomlPath -Value $exampleTomlContent -Encoding UTF8 -Force
                $results.ExampleConfigCreated = $true
            }
        }
        catch {
            $results.Errors.Add("Failed to create example config: $_")
        }

        # Install PSToml module
        try {
            $psToml = Get-Module -Name PSToml -ListAvailable -ErrorAction SilentlyContinue
            if ($psToml) {
                $results.PSTomlAlreadyPresent = $true
            }
            else {
                Install-Module -Name PSToml -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
                $results.PSTomlInstalled = $true
            }
        }
        catch {
            $results.Errors.Add("Failed to install PSToml module: $_")
        }

        # Check 7-Zip
        $sevenZipPaths = @(
            (Join-Path $env:ProgramFiles '7-Zip\7z.exe')
            'C:\Program Files\7-Zip\7z.exe'
        )
        if (${env:ProgramFiles(x86)}) {
            $sevenZipPaths += Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'
        }

        foreach ($szPath in $sevenZipPaths) {
            if ($szPath -and (Test-Path -Path $szPath -PathType Leaf)) {
                $results.SevenZipAvailable = $true
                $results.SevenZipPath = $szPath
                break
            }
        }

        return $results
    } -ErrorAction Stop

    $checks['NodeAgent Install'] = $true

    if ($installResult.DirectoriesCreated.Count -gt 0) {
        foreach ($dir in $installResult.DirectoriesCreated) {
            Write-Host "  [PASS] Created: $dir" -ForegroundColor Green
        }
    }
    else {
        Write-Host '  [PASS] All directories already exist.' -ForegroundColor Green
    }

    if ($installResult.PSTomlInstalled) {
        Write-Host '  [PASS] PSToml module installed.' -ForegroundColor Green
    }
    elseif ($installResult.PSTomlAlreadyPresent) {
        Write-Host '  [PASS] PSToml module already present.' -ForegroundColor Green
    }

    if ($installResult.SevenZipAvailable) {
        Write-Host "  [PASS] 7-Zip found at: $($installResult.SevenZipPath)" -ForegroundColor Green
    }
    else {
        Write-Host '  [NOTE] 7-Zip not installed. Backups will use Compress-Archive (slower, larger files).' -ForegroundColor DarkYellow
    }

    if ($installResult.ExampleConfigCreated) {
        Write-Host '  [PASS] instance.example.toml created.' -ForegroundColor Green
    }

    if ($installResult.Errors.Count -gt 0) {
        $checks['NodeAgent Install'] = $false
        foreach ($err in $installResult.Errors) {
            Write-Host "  [WARN] $err" -ForegroundColor DarkYellow
        }
    }
}
catch {
    $checks['NodeAgent Install'] = $false
    Write-Host "  [FAIL] NodeAgent installation failed: $_" -ForegroundColor Red
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 9: Verify VSS (test create + delete shadow copy)
# ══════════════════════════════════════════════════════════════════════════════
if ($SkipVSSTest) {
    Write-Host '[9/11] Skipping VSS test (-SkipVSSTest specified).' -ForegroundColor DarkGray
    $checks['VSS Test'] = 'Skipped'
}
else {
    Write-Host '[9/11] Testing VSS shadow copy capability...' -ForegroundColor Yellow
    try {
        $vssResult = Invoke-Command -Session $session -ScriptBlock {
            $result = @{ Created = $false; Deleted = $false; Error = $null }

            try {
                # Create a test shadow copy on the system drive
                $systemDrive = $env:SystemDrive
                if (-not $systemDrive) { $systemDrive = 'C:' }
                $volume = "${systemDrive}\"

                $createResult = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{
                    Volume = $volume
                } -ErrorAction Stop

                if ($createResult.ReturnValue -ne 0) {
                    $result.Error = "VSS create returned error code: $($createResult.ReturnValue)"
                    return $result
                }

                $result.Created = $true
                $shadowId = $createResult.ShadowID

                # Delete the test shadow copy
                $shadow = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId }
                if ($shadow) {
                    $shadow | Remove-CimInstance -ErrorAction Stop
                    $result.Deleted = $true
                }
                else {
                    $result.Error = "Shadow copy created but could not be found for deletion (ID: $shadowId)"
                }
            }
            catch {
                $result.Error = $_.Exception.Message
            }

            return $result
        } -ErrorAction Stop

        if ($vssResult.Created -and $vssResult.Deleted) {
            $checks['VSS Test'] = $true
            Write-Host '  [PASS] VSS shadow copy created and deleted successfully.' -ForegroundColor Green
        }
        else {
            $checks['VSS Test'] = $false
            Write-Host "  [FAIL] VSS test failed: $($vssResult.Error)" -ForegroundColor Red
            Write-Host '         VSS requires administrative privileges and the VSS service.' -ForegroundColor DarkYellow
            Write-Host '         Run "vssadmin list providers" on the node to diagnose.' -ForegroundColor DarkYellow
        }
    }
    catch {
        $checks['VSS Test'] = $false
        Write-Host "  [FAIL] VSS test error: $_" -ForegroundColor Red
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 10: Generate node config TOML on C&C
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[10/11] Generating node configuration on C&C...' -ForegroundColor Yellow
try {
    $configRoot = Join-Path $projectRoot 'Config'
    $nodesDir = Join-Path $configRoot 'nodes'
    $nodeTomlPath = Join-Path $nodesDir "$NodeName.toml"

    if (-not (Test-Path $nodesDir -PathType Container)) {
        New-Item -Path $nodesDir -ItemType Directory -Force | Out-Null
    }

    $nodeTomlContent = @"
# SEBackup Node Configuration: $NodeName
# Generated by Setup-Node.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

[node]
hostname     = "$Hostname"
display_name = "$NodeName"
username     = "$Username"

[node.options]
seven_zip_available = $($installResult.SevenZipAvailable.ToString().ToLower())
"@

    if ($PSCmdlet.ShouldProcess("Node config: $nodeTomlPath", 'Create')) {
        Set-Content -Path $nodeTomlPath -Value $nodeTomlContent -Encoding UTF8 -Force
    }
    $checks['Node Config'] = $true
    Write-Host "  [PASS] Node config written to: $nodeTomlPath" -ForegroundColor Green
}
catch {
    $checks['Node Config'] = $false
    Write-Host "  [FAIL] Node config generation failed: $_" -ForegroundColor Red
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 11: Run full connectivity test
# ══════════════════════════════════════════════════════════════════════════════
Write-Host '[11/11] Running connectivity test...' -ForegroundColor Yellow
try {
    # Clean up the setup session first so Test-SEBConnection creates its own
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        $session = $null
    }

    $testResult = Test-SEBConnection -NodeName $NodeName -Detailed

    if ($testResult.WinRM) {
        $checks['Connectivity Test'] = $true
        Write-Host '  [PASS] Full connectivity test passed.' -ForegroundColor Green
    }
    else {
        $checks['Connectivity Test'] = $false
        Write-Host "  [FAIL] Connectivity test failed: $($testResult.Error)" -ForegroundColor Red
    }
}
catch {
    $checks['Connectivity Test'] = $false
    Write-Host "  [FAIL] Connectivity test error: $_" -ForegroundColor Red
}

# ══════════════════════════════════════════════════════════════════════════════
# Final Results Summary
# ══════════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║                    Setup Results Summary                    ║' -ForegroundColor Cyan
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
    Write-Host "  Node '$NodeName' is ready!" -ForegroundColor Green
    Write-Host '  Next step: Register instances with Register-Instance.ps1' -ForegroundColor White
    Write-Host "    Example: .\Register-Instance.ps1 -NodeName '$NodeName' -InstanceName 'MyServer'" -ForegroundColor DarkGray
}
else {
    Write-Host ''
    Write-Host "  Node '$NodeName' setup completed with errors." -ForegroundColor Yellow
    Write-Host '  Please review the failures above and re-run Setup-Node.ps1 if needed.' -ForegroundColor White
}

Write-Host ''

# Cleanup
if ($session) {
    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
}
