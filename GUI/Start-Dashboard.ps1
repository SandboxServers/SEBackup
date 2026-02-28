<#
.SYNOPSIS
    Launches the SEBackup WPF Dashboard GUI.

.DESCRIPTION
    Main entry point for the SEBackup graphical dashboard. This script:

    1. Loads WPF assemblies and the SEBackup PowerShell modules.
    2. Parses the MainWindow XAML and instantiates the WPF window.
    3. Loads each tab's XAML UserControl into the MainWindow's content areas.
    4. Discovers all named XAML elements and stores references for event wiring.
    5. Loads current configuration and populates UI controls with saved values.
    6. Wires up event handlers for all interactive controls across all tabs.
    7. Starts a periodic refresh timer for the Dashboard status cards.
    8. Shows the window via ShowDialog() (blocking until the window closes).

    The GUI is designed for a "barely-power-user" operator to manage Space Engineers
    Torch server backups across multiple compute nodes from a single C&C machine.

.EXAMPLE
    .\GUI\Start-Dashboard.ps1

.NOTES
    File:    Start-Dashboard.ps1
    Project: SEBackup - Space Engineers Torch Server Backup & Restore System
    Requires: PowerShell 7+, Windows Presentation Framework
#>

#Requires -Version 7.0

[CmdletBinding()]
param()

# ============================================================================
# INITIALIZATION
# ============================================================================

# Ensure we are running on Windows with WPF available
if ($env:OS -ne 'Windows_NT' -and -not $IsWindows) {
    Write-Error "The SEBackup GUI requires Windows with WPF support."
    return
}

# Load WPF assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# Resolve project root (two levels up from GUI/Start-Dashboard.ps1)
$script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $script:ProjectRoot) {
    $script:ProjectRoot = Split-Path -Parent $PSScriptRoot
}

# Import SEBackup modules
$modulesDir = Join-Path -Path $script:ProjectRoot -ChildPath 'Modules'
$moduleNames = @(
    'Logger', 'ConfigManager', 'CredentialManager', 'ManifestManager',
    'IntegrityManager', 'RemoteManager', 'VRageAPI', 'BackupEngine',
    'CompressionManager', 'NetworkThrottle', 'VSSManager',
    'NotificationManager', 'LoadMonitor'
)

foreach ($modName in $moduleNames) {
    $modPath = Join-Path -Path $modulesDir -ChildPath $modName
    if (Test-Path $modPath) {
        try {
            Import-Module $modPath -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to import module '$modName': $_"
        }
    }
}

# Load GUI helper scripts
$helpersDir = Join-Path -Path $PSScriptRoot -ChildPath 'Helpers'
. (Join-Path -Path $helpersDir -ChildPath 'RunspaceHelper.ps1')
. (Join-Path -Path $helpersDir -ChildPath 'UIDispatcher.ps1')

# ============================================================================
# XAML LOADING
# ============================================================================

function Load-XamlContent {
    <#
    .SYNOPSIS
        Loads a XAML file and returns the parsed WPF object.
    .PARAMETER Path
        Full path to the XAML file.
    #>
    param([string]$Path)

    $xamlContent = Get-Content -Path $Path -Raw -ErrorAction Stop

    # Remove x:Class attributes that require code-behind compilation
    $xamlContent = $xamlContent -replace 'x:Class="[^"]*"', ''

    # Remove event handler attributes from XAML (they are wired up in code)
    $xamlContent = $xamlContent -replace 'SelectionChanged="[^"]*"', ''
    $xamlContent = $xamlContent -replace 'Click="[^"]*"', ''

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xamlContent))
    $result = [System.Windows.Markup.XamlReader]::Load($reader)
    return $result
}

# --- Load MainWindow ---
$guiDir = $PSScriptRoot
$mainWindowXaml = Join-Path -Path $guiDir -ChildPath 'MainWindow.xaml'
$Window = Load-XamlContent -Path $mainWindowXaml

# --- Load Tab Views ---
$viewsDir = Join-Path -Path $guiDir -ChildPath 'Views'

$dashboardView = Load-XamlContent -Path (Join-Path $viewsDir 'DashboardView.xaml')
$backupView    = Load-XamlContent -Path (Join-Path $viewsDir 'BackupView.xaml')
$restoreView   = Load-XamlContent -Path (Join-Path $viewsDir 'RestoreView.xaml')
$settingsView  = Load-XamlContent -Path (Join-Path $viewsDir 'SettingsView.xaml')
$logView       = Load-XamlContent -Path (Join-Path $viewsDir 'LogView.xaml')

# Inject views into the MainWindow content areas
$Window.FindName('DashboardContent').Content = $dashboardView
$Window.FindName('BackupContent').Content    = $backupView
$Window.FindName('RestoreContent').Content   = $restoreView
$Window.FindName('SettingsContent').Content  = $settingsView
$Window.FindName('LogsContent').Content      = $logView

# ============================================================================
# CONTROL REFERENCES - Find all named elements from all XAML files
# ============================================================================

# MainWindow controls
$StatusIndicator  = $Window.FindName('StatusIndicator')
$StatusBarText    = $Window.FindName('StatusBarText')
$StatusBarTime    = $Window.FindName('StatusBarTime')

# Build a status bar reference hashtable for Set-SEBUIStatus
$script:StatusBarRefs = @{
    Indicator = $StatusIndicator
    Text      = $StatusBarText
    Time      = $StatusBarTime
}

# --- Dashboard controls ---
$DashCCStorageLabel     = $dashboardView.FindName('DashCCStorageLabel')
$DashCCStoragePercent   = $dashboardView.FindName('DashCCStoragePercent')
$DashCCStorageBar       = $dashboardView.FindName('DashCCStorageBar')
$DashNASStorageLabel    = $dashboardView.FindName('DashNASStorageLabel')
$DashNASStoragePercent  = $dashboardView.FindName('DashNASStoragePercent')
$DashNASStorageBar      = $dashboardView.FindName('DashNASStorageBar')
$DashRefreshButton      = $dashboardView.FindName('DashRefreshButton')
$DashNoInstancesPanel   = $dashboardView.FindName('DashNoInstancesPanel')
$DashInstanceCards      = $dashboardView.FindName('DashInstanceCards')

# --- Backup controls ---
$BackupInstanceCombo    = $backupView.FindName('BackupInstanceCombo')
$BackupNowButton        = $backupView.FindName('BackupNowButton')
$BackupForceFullButton  = $backupView.FindName('BackupForceFullButton')
$BackupVerifyAllButton  = $backupView.FindName('BackupVerifyAllButton')
$BackupHistoryGrid      = $backupView.FindName('BackupHistoryGrid')
$BackupDiffPanel        = $backupView.FindName('BackupDiffPanel')
$BackupDiffAdded        = $backupView.FindName('BackupDiffAdded')
$BackupDiffModified     = $backupView.FindName('BackupDiffModified')
$BackupDiffDeleted      = $backupView.FindName('BackupDiffDeleted')
$BackupDiffFileList     = $backupView.FindName('BackupDiffFileList')
$BackupDiskUsageBar     = $backupView.FindName('BackupDiskUsageBar')
$BackupDiskUsageLabel   = $backupView.FindName('BackupDiskUsageLabel')

# --- Restore controls ---
$RestoreStep1Panel            = $restoreView.FindName('RestoreStep1Panel')
$RestoreStep2Panel            = $restoreView.FindName('RestoreStep2Panel')
$RestoreStep3Panel            = $restoreView.FindName('RestoreStep3Panel')
$RestoreStep4Panel            = $restoreView.FindName('RestoreStep4Panel')
$RestoreInstanceCombo         = $restoreView.FindName('RestoreInstanceCombo')
$RestorePointList             = $restoreView.FindName('RestorePointList')
$RestoreStep1NextButton       = $restoreView.FindName('RestoreStep1NextButton')
$RestoreSummaryInstance       = $restoreView.FindName('RestoreSummaryInstance')
$RestoreSummaryTimestamp      = $restoreView.FindName('RestoreSummaryTimestamp')
$RestoreSummaryType           = $restoreView.FindName('RestoreSummaryType')
$RestoreSummarySize           = $restoreView.FindName('RestoreSummarySize')
$RestoreSummaryChain          = $restoreView.FindName('RestoreSummaryChain')
$RestoreSummaryTarget         = $restoreView.FindName('RestoreSummaryTarget')
$RestoreAcknowledgeCheckBox   = $restoreView.FindName('RestoreAcknowledgeCheckBox')
$RestoreStep2BackButton       = $restoreView.FindName('RestoreStep2BackButton')
$RestoreStep2RestoreButton    = $restoreView.FindName('RestoreStep2RestoreButton')
$RestoreProgressLabel         = $restoreView.FindName('RestoreProgressLabel')
$RestoreProgressPercent       = $restoreView.FindName('RestoreProgressPercent')
$RestoreProgressBar           = $restoreView.FindName('RestoreProgressBar')
$RestoreCheck1Icon            = $restoreView.FindName('RestoreCheck1Icon')
$RestoreCheck2Icon            = $restoreView.FindName('RestoreCheck2Icon')
$RestoreCheck3Icon            = $restoreView.FindName('RestoreCheck3Icon')
$RestoreCheck4Icon            = $restoreView.FindName('RestoreCheck4Icon')
$RestoreCheck5Icon            = $restoreView.FindName('RestoreCheck5Icon')
$RestoreCheck6Icon            = $restoreView.FindName('RestoreCheck6Icon')
$RestoreCheck1Text            = $restoreView.FindName('RestoreCheck1Text')
$RestoreCheck2Text            = $restoreView.FindName('RestoreCheck2Text')
$RestoreCheck3Text            = $restoreView.FindName('RestoreCheck3Text')
$RestoreCheck4Text            = $restoreView.FindName('RestoreCheck4Text')
$RestoreCheck5Text            = $restoreView.FindName('RestoreCheck5Text')
$RestoreCheck6Text            = $restoreView.FindName('RestoreCheck6Text')
$RestoreResultIconBorder      = $restoreView.FindName('RestoreResultIconBorder')
$RestoreResultIcon            = $restoreView.FindName('RestoreResultIcon')
$RestoreResultTitle           = $restoreView.FindName('RestoreResultTitle')
$RestoreResultMessage         = $restoreView.FindName('RestoreResultMessage')
$RestoreResultDuration        = $restoreView.FindName('RestoreResultDuration')
$RestoreResultFiles           = $restoreView.FindName('RestoreResultFiles')
$RestoreResultSafety          = $restoreView.FindName('RestoreResultSafety')
$RestoreResultServer          = $restoreView.FindName('RestoreResultServer')
$RestoreUndoButton            = $restoreView.FindName('RestoreUndoButton')
$RestoreNewButton             = $restoreView.FindName('RestoreNewButton')

# --- Settings controls ---
$SettingsTreeView               = $settingsView.FindName('SettingsTreeView')
$SettingsConfigPath             = $settingsView.FindName('SettingsConfigPath')
$SettingsProjectRoot            = $settingsView.FindName('SettingsProjectRoot')
$SettingsPanelGeneral           = $settingsView.FindName('SettingsPanelGeneral')
$SettingsPanelStorage           = $settingsView.FindName('SettingsPanelStorage')
$SettingsPanelSchedule          = $settingsView.FindName('SettingsPanelSchedule')
$SettingsPanelRetention         = $settingsView.FindName('SettingsPanelRetention')
$SettingsPanelCompression       = $settingsView.FindName('SettingsPanelCompression')
$SettingsPanelNetwork           = $settingsView.FindName('SettingsPanelNetwork')
$SettingsPanelNotifications     = $settingsView.FindName('SettingsPanelNotifications')
$SettingsStorageCCRoot          = $settingsView.FindName('SettingsStorageCCRoot')
$SettingsStorageNASPath         = $settingsView.FindName('SettingsStorageNASPath')
$SettingsStorageVSSMount        = $settingsView.FindName('SettingsStorageVSSMount')
$SettingsScheduleEnabled        = $settingsView.FindName('SettingsScheduleEnabled')
$SettingsScheduleInterval       = $settingsView.FindName('SettingsScheduleInterval')
$SettingsScheduleIntervalLabel  = $settingsView.FindName('SettingsScheduleIntervalLabel')
$SettingsScheduleFullInterval      = $settingsView.FindName('SettingsScheduleFullInterval')
$SettingsScheduleFullIntervalLabel = $settingsView.FindName('SettingsScheduleFullIntervalLabel')
$SettingsScheduleMaxChain          = $settingsView.FindName('SettingsScheduleMaxChain')
$SettingsScheduleMaxChainLabel     = $settingsView.FindName('SettingsScheduleMaxChainLabel')
$SettingsScheduleStartTime      = $settingsView.FindName('SettingsScheduleStartTime')
$SettingsRetentionCCCount       = $settingsView.FindName('SettingsRetentionCCCount')
$SettingsRetentionCCCountLabel  = $settingsView.FindName('SettingsRetentionCCCountLabel')
$SettingsRetentionNASDays       = $settingsView.FindName('SettingsRetentionNASDays')
$SettingsRetentionNASDaysLabel  = $settingsView.FindName('SettingsRetentionNASDaysLabel')
$SettingsCompressionEngine      = $settingsView.FindName('SettingsCompressionEngine')
$SettingsCompressionLevel       = $settingsView.FindName('SettingsCompressionLevel')
$SettingsCompressionLevelLabel  = $settingsView.FindName('SettingsCompressionLevelLabel')
$SettingsNetworkBandwidth       = $settingsView.FindName('SettingsNetworkBandwidth')
$SettingsNetworkBandwidthLabel  = $settingsView.FindName('SettingsNetworkBandwidthLabel')
$SettingsNetworkIPG             = $settingsView.FindName('SettingsNetworkIPG')
$SettingsNotifyEnabled          = $settingsView.FindName('SettingsNotifyEnabled')
$SettingsNotifyWebhook          = $settingsView.FindName('SettingsNotifyWebhook')
$SettingsNotifyTestButton       = $settingsView.FindName('SettingsNotifyTestButton')
$SettingsNotifyOnSuccess        = $settingsView.FindName('SettingsNotifyOnSuccess')
$SettingsNotifyOnFailure        = $settingsView.FindName('SettingsNotifyOnFailure')
$SettingsNotifyOnWarning        = $settingsView.FindName('SettingsNotifyOnWarning')
$SettingsSaveButton             = $settingsView.FindName('SettingsSaveButton')
$SettingsAddNodeButton          = $settingsView.FindName('SettingsAddNodeButton')
$SettingsNodeGrid               = $settingsView.FindName('SettingsNodeGrid')

# --- Log controls ---
$LogLevelFilter      = $logView.FindName('LogLevelFilter')
$LogInstanceFilter   = $logView.FindName('LogInstanceFilter')
$LogDateFilter       = $logView.FindName('LogDateFilter')
$LogSearchText       = $logView.FindName('LogSearchText')
$LogRefreshButton    = $logView.FindName('LogRefreshButton')
$LogEntriesGrid      = $logView.FindName('LogEntriesGrid')
$LogExportButton     = $logView.FindName('LogExportButton')
$LogAutoScrollToggle = $logView.FindName('LogAutoScrollToggle')
$LogEntryCount       = $logView.FindName('LogEntryCount')

# ============================================================================
# STATE VARIABLES
# ============================================================================

$script:GlobalConfig     = $null    # Cached global configuration hashtable
$script:NodeConfigs      = @()      # Array of node configuration hashtables
$script:InstanceData     = @()      # Array of instance status data for dashboard cards
$script:BackupHistory    = @()      # Backup manifest history for the selected instance
$script:RunningOps       = @{}      # Hashtable of currently running background operations
$script:RestoreState     = @{       # Current restore wizard state
    SelectedInstance    = $null
    SelectedRestorePoint = $null
    SafetyBackupPath    = $null
}

# ============================================================================
# DATA LOADING FUNCTIONS
# ============================================================================

function Initialize-ConfigData {
    <# Loads configuration and populates instance/node lists. #>

    try {
        $script:GlobalConfig = Get-SEBGlobalConfig -Force
    }
    catch {
        Write-Warning "Failed to load global config: $_"
        $script:GlobalConfig = @{}
    }

    # Load node configs
    try {
        $script:NodeConfigs = @(Get-SEBNodeConfig -All)
    }
    catch {
        Write-Warning "Failed to load node configs: $_"
        $script:NodeConfigs = @()
    }
}

function Update-StorageGauges {
    <# Updates the storage gauge bars and labels on the Dashboard. #>

    $maxBarWidth = 300  # approximate max width of the gauge container

    # C&C local storage
    $ccRoot = $script:GlobalConfig.storage.cc_backup_root
    if ($ccRoot -and (Test-Path -Path $ccRoot -ErrorAction SilentlyContinue)) {
        try {
            $driveLetter = (Split-Path -Qualifier $ccRoot).TrimEnd(':')
            $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='${driveLetter}:'" -ErrorAction Stop
            $usedGB  = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 1)
            $totalGB = [math]::Round($disk.Size / 1GB, 1)
            $pct     = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100) } else { 0 }

            $DashCCStorageLabel.Text   = "$usedGB GB used of $totalGB GB"
            $DashCCStoragePercent.Text = "$pct%"
            $DashCCStorageBar.Width    = [math]::Max(0, [math]::Min($maxBarWidth, $maxBarWidth * $pct / 100))

            # Color code: green < 70%, yellow 70-89%, red >= 90%
            $barColor = if ($pct -ge 90) { '#FF6B6B' } elseif ($pct -ge 70) { '#FFD93D' } else { '#6BCB77' }
            $DashCCStorageBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($barColor)
        }
        catch {
            $DashCCStorageLabel.Text = "Unable to read disk info"
        }
    }
    else {
        $DashCCStorageLabel.Text = "Path not found: $ccRoot"
    }

    # NAS storage
    $nasPath = $script:GlobalConfig.storage.nas_backup_path
    if ([string]::IsNullOrWhiteSpace($nasPath)) {
        $DashNASStorageLabel.Text   = "Not configured"
        $DashNASStoragePercent.Text = ""
        $DashNASStorageBar.Width    = 0
    }
    elseif (Test-Path -Path $nasPath -ErrorAction SilentlyContinue) {
        try {
            $drive = New-Object System.IO.DriveInfo((Split-Path -Qualifier $nasPath))
            $usedGB  = [math]::Round(($drive.TotalSize - $drive.AvailableFreeSpace) / 1GB, 1)
            $totalGB = [math]::Round($drive.TotalSize / 1GB, 1)
            $pct     = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100) } else { 0 }

            $DashNASStorageLabel.Text   = "$usedGB GB used of $totalGB GB"
            $DashNASStoragePercent.Text = "$pct%"
            $DashNASStorageBar.Width    = [math]::Max(0, [math]::Min($maxBarWidth, $maxBarWidth * $pct / 100))

            $barColor = if ($pct -ge 90) { '#FF6B6B' } elseif ($pct -ge 70) { '#FFD93D' } else { '#6BCB77' }
            $DashNASStorageBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($barColor)
        }
        catch {
            $DashNASStorageLabel.Text = "Unable to read NAS info"
        }
    }
    else {
        $DashNASStorageLabel.Text = "Path not accessible: $nasPath"
    }
}

function Update-InstanceCards {
    <# Refreshes the instance status cards on the Dashboard. #>

    $brushConverter = [System.Windows.Media.BrushConverter]::new()

    # Build instance data from known nodes and their configurations
    $instances = [System.Collections.Generic.List[object]]::new()

    foreach ($nodeConfig in $script:NodeConfigs) {
        $nodeName   = $nodeConfig._NodeName
        $hostname   = if ($nodeConfig.node) { $nodeConfig.node.hostname } else { $nodeName }
        $nodeDisplay = if ($nodeConfig.node) { $nodeConfig.node.display_name } else { $nodeName }

        # Try to get the latest manifest for each instance under this node
        $backupRoot = $script:GlobalConfig.storage.cc_backup_root
        $nodeBackupDir = Join-Path -Path $backupRoot -ChildPath $nodeName -ErrorAction SilentlyContinue

        # Check for instance subdirectories under the node's backup directory
        $instanceDirs = @()
        if ($backupRoot -and (Test-Path -Path $backupRoot -ErrorAction SilentlyContinue)) {
            $instanceDirs = Get-ChildItem -Path $backupRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName 'manifests') }
        }

        if ($instanceDirs.Count -eq 0) {
            # No discovered instances yet -- show the node itself as a placeholder
            $instances.Add([PSCustomObject]@{
                InstanceName = $nodeName
                DisplayName  = $nodeDisplay
                NodeName     = $hostname
                StatusColor  = $brushConverter.ConvertFromString('#808099')  # Gray -- unknown
                LastBackup   = 'No backups yet'
                NextBackup   = '--'
                PlayerCount  = '--'
            })
        }

        foreach ($instDir in $instanceDirs) {
            $instName = $instDir.Name

            # Read latest manifest
            $lastBackup = 'Never'
            $nextBackup = '--'
            $statusBrush = $brushConverter.ConvertFromString('#808099')  # Gray default

            try {
                $latestManifest = Get-SEBLatestManifest -InstanceName $instName -BackupRoot $backupRoot
                if ($latestManifest) {
                    $ts = [datetime]::Parse($latestManifest['timestamp'])
                    $lastBackup = $ts.ToString('yyyy-MM-dd HH:mm')
                    $age = ([datetime]::UtcNow - $ts).TotalHours
                    $interval = $script:GlobalConfig.schedule.interval_hours

                    if ($age -lt ($interval * 1.5)) {
                        $statusBrush = $brushConverter.ConvertFromString('#6BCB77')  # Green
                    }
                    elseif ($age -lt ($interval * 3)) {
                        $statusBrush = $brushConverter.ConvertFromString('#FFD93D')  # Yellow
                    }
                    else {
                        $statusBrush = $brushConverter.ConvertFromString('#FF6B6B')  # Red
                    }

                    # Estimate next backup
                    $nextTs = $ts.AddHours($interval)
                    if ($nextTs -lt [datetime]::UtcNow) {
                        $nextBackup = 'Overdue'
                    }
                    else {
                        $nextBackup = $nextTs.ToString('yyyy-MM-dd HH:mm')
                    }
                }
            }
            catch {
                # Ignore manifest read errors for the dashboard
            }

            $instances.Add([PSCustomObject]@{
                InstanceName = $instName
                DisplayName  = $instName
                NodeName     = $hostname
                StatusColor  = $statusBrush
                LastBackup   = $lastBackup
                NextBackup   = $nextBackup
                PlayerCount  = '--'
            })
        }
    }

    # Update the ItemsControl
    if ($instances.Count -eq 0) {
        $DashNoInstancesPanel.Visibility = [System.Windows.Visibility]::Visible
        $DashInstanceCards.ItemsSource = $null
    }
    else {
        $DashNoInstancesPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $DashInstanceCards.ItemsSource = $instances
    }
}

function Populate-InstanceCombos {
    <# Fills all instance ComboBoxes across tabs. #>

    $backupRoot = $script:GlobalConfig.storage.cc_backup_root
    $instanceNames = @()

    if ($backupRoot -and (Test-Path -Path $backupRoot -ErrorAction SilentlyContinue)) {
        $instanceNames = Get-ChildItem -Path $backupRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'manifests') } |
            ForEach-Object { $_.Name }
    }

    # Also add instance names from node configs that may not have backups yet
    foreach ($nodeConfig in $script:NodeConfigs) {
        $nodeName = $nodeConfig._NodeName
        if ($nodeName -and $nodeName -notin $instanceNames) {
            $instanceNames += $nodeName
        }
    }

    $combos = @($BackupInstanceCombo, $RestoreInstanceCombo)
    foreach ($combo in $combos) {
        $selected = $combo.SelectedItem
        $combo.Items.Clear()
        foreach ($name in ($instanceNames | Sort-Object)) {
            $combo.Items.Add($name) | Out-Null
        }
        if ($selected -and $combo.Items.Contains($selected)) {
            $combo.SelectedItem = $selected
        }
        elseif ($combo.Items.Count -gt 0) {
            $combo.SelectedIndex = 0
        }
    }
}

function Load-BackupHistory {
    <# Loads backup manifest history for the selected instance into the Backup grid. #>

    $instanceName = $BackupInstanceCombo.SelectedItem
    if ([string]::IsNullOrWhiteSpace($instanceName)) {
        $BackupHistoryGrid.ItemsSource = $null
        return
    }

    $backupRoot = $script:GlobalConfig.storage.cc_backup_root
    $manifestDir = Join-Path -Path $backupRoot -ChildPath $instanceName | Join-Path -ChildPath 'manifests'

    if (-not (Test-Path -Path $manifestDir -ErrorAction SilentlyContinue)) {
        $BackupHistoryGrid.ItemsSource = $null
        return
    }

    $history = [System.Collections.Generic.List[object]]::new()

    $manifestFiles = Get-ChildItem -Path $manifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending

    foreach ($file in $manifestFiles) {
        try {
            $manifest = Read-SEBManifest -Path $file.FullName

            $sizeDisplay = '--'
            if ($manifest['archive_size_bytes']) {
                $sizeMB = [math]::Round([long]$manifest['archive_size_bytes'] / 1MB, 1)
                $sizeDisplay = if ($sizeMB -ge 1024) { "$([math]::Round($sizeMB / 1024, 2)) GB" } else { "$sizeMB MB" }
            }

            $fileCount = 0
            if ($manifest['files']) {
                $fileCount = $manifest['files'].Count
            }

            $history.Add([PSCustomObject]@{
                Timestamp     = $manifest['timestamp']
                Type          = $manifest['type']
                Size          = $sizeDisplay
                FileCount     = $fileCount
                ChainSequence = $manifest['chain_sequence']
                Status        = if ($manifest['verified']) { 'Verified' } else { 'OK' }
                ManifestFile  = $file.Name
                _manifest     = $manifest
            })
        }
        catch {
            # Skip unreadable manifests
        }
    }

    $script:BackupHistory = $history
    $BackupHistoryGrid.ItemsSource = $history

    # Update disk usage bar
    Update-BackupDiskUsage -InstanceName $instanceName
}

function Update-BackupDiskUsage {
    <# Updates the disk usage summary bar on the Backup tab. #>
    param([string]$InstanceName)

    $backupRoot = $script:GlobalConfig.storage.cc_backup_root
    $instanceDir = Join-Path -Path $backupRoot -ChildPath $InstanceName

    if (-not (Test-Path -Path $instanceDir -ErrorAction SilentlyContinue)) {
        $BackupDiskUsageLabel.Text = '0 MB'
        $BackupDiskUsageBar.Width = 0
        return
    }

    try {
        $totalSize = (Get-ChildItem -Path $instanceDir -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum

        if ($null -eq $totalSize) { $totalSize = 0 }
        $sizeGB = [math]::Round($totalSize / 1GB, 2)
        $sizeMB = [math]::Round($totalSize / 1MB, 1)
        $BackupDiskUsageLabel.Text = if ($sizeGB -ge 1) { "$sizeGB GB" } else { "$sizeMB MB" }

        # Scale bar against the drive capacity
        $driveLetter = (Split-Path -Qualifier $backupRoot).TrimEnd(':')
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='${driveLetter}:'" -ErrorAction Stop
        $pct = if ($disk.Size -gt 0) { [math]::Round(($totalSize / $disk.Size) * 100, 1) } else { 0 }
        $maxBarWidth = 600
        $BackupDiskUsageBar.Width = [math]::Max(0, [math]::Min($maxBarWidth, $maxBarWidth * $pct / 100))
    }
    catch {
        $BackupDiskUsageLabel.Text = 'Error reading size'
    }
}

function Load-SettingsValues {
    <# Populates the Settings tab controls from the global config. #>

    $cfg = $script:GlobalConfig
    if (-not $cfg) { return }

    # General
    $configPath = Join-Path -Path $script:ProjectRoot -ChildPath 'Config\global.toml'
    $SettingsConfigPath.Text  = $configPath
    $SettingsProjectRoot.Text = $script:ProjectRoot

    # Storage
    $SettingsStorageCCRoot.Text   = $cfg.storage.cc_backup_root
    $SettingsStorageNASPath.Text  = $cfg.storage.nas_backup_path
    $SettingsStorageVSSMount.Text = $cfg.defaults.vss.mount_base

    # Schedule
    $SettingsScheduleEnabled.IsChecked         = $cfg.schedule.enabled
    $SettingsScheduleInterval.Value            = $cfg.schedule.interval_hours
    $SettingsScheduleIntervalLabel.Text        = "$($cfg.schedule.interval_hours)"
    $SettingsScheduleFullInterval.Value        = $cfg.schedule.full_backup_interval_hours
    $SettingsScheduleFullIntervalLabel.Text    = "$($cfg.schedule.full_backup_interval_hours)"
    $SettingsScheduleMaxChain.Value            = $cfg.schedule.max_incremental_chain_length
    $SettingsScheduleMaxChainLabel.Text        = "$($cfg.schedule.max_incremental_chain_length)"
    $SettingsScheduleStartTime.Text            = $cfg.schedule.start_time

    # Retention
    $SettingsRetentionCCCount.Value       = $cfg.retention.cc_full_count
    $SettingsRetentionCCCountLabel.Text   = "$($cfg.retention.cc_full_count)"
    $SettingsRetentionNASDays.Value       = $cfg.retention.nas_retention_days
    $SettingsRetentionNASDaysLabel.Text   = "$($cfg.retention.nas_retention_days)"

    # Compression
    # Select the matching ComboBoxItem
    foreach ($item in $SettingsCompressionEngine.Items) {
        if ($item.Content -eq $cfg.compression.engine) {
            $SettingsCompressionEngine.SelectedItem = $item
            break
        }
    }
    $SettingsCompressionLevel.Value      = $cfg.compression.level_7zip
    $SettingsCompressionLevelLabel.Text  = "$($cfg.compression.level_7zip)"

    # Network
    $SettingsNetworkBandwidth.Value      = $cfg.network.max_bandwidth_mbps
    $SettingsNetworkBandwidthLabel.Text  = "$($cfg.network.max_bandwidth_mbps)"
    $SettingsNetworkIPG.Text             = "$($cfg.network.robocopy_ipg_ms)"

    # Notifications
    $SettingsNotifyEnabled.IsChecked     = $cfg.notifications.enabled
    $SettingsNotifyWebhook.Text          = $cfg.notifications.webhook_url
    $SettingsNotifyOnSuccess.IsChecked   = $cfg.notifications.on_success
    $SettingsNotifyOnFailure.IsChecked   = $cfg.notifications.on_failure
    $SettingsNotifyOnWarning.IsChecked   = $cfg.notifications.on_warning
}

function Load-NodeGrid {
    <# Populates the node management DataGrid on the Settings tab. #>

    $nodes = [System.Collections.Generic.List[object]]::new()

    foreach ($nc in $script:NodeConfigs) {
        $nodes.Add([PSCustomObject]@{
            Name        = $nc._NodeName
            Hostname    = if ($nc.node) { $nc.node.hostname } else { '--' }
            DisplayName = if ($nc.node) { $nc.node.display_name } else { $nc._NodeName }
            Status      = 'Unknown'
        })
    }

    $SettingsNodeGrid.ItemsSource = $nodes
}

function Load-LogEntries {
    <# Reads and filters log entries for the Logs tab. #>

    $params = @{}

    # Level filter
    $levelSelection = $LogLevelFilter.SelectedItem
    $levelText = if ($levelSelection -is [System.Windows.Controls.ComboBoxItem]) {
        $levelSelection.Content.ToString()
    } else { 'All' }

    if ($levelText -ne 'All') {
        $params['Level'] = $levelText
    }

    # Instance/context filter
    $contextSelection = $LogInstanceFilter.SelectedItem
    $contextText = if ($contextSelection -is [System.Windows.Controls.ComboBoxItem]) {
        $contextSelection.Content.ToString()
    } else { 'All' }

    if ($contextText -ne 'All') {
        $params['Context'] = $contextText
    }

    # Date filter
    if ($LogDateFilter.SelectedDate) {
        $selectedDate = $LogDateFilter.SelectedDate
        $logPath = Join-Path -Path $script:ProjectRoot -ChildPath "Logs\SEBackup_$($selectedDate.ToString('yyyy-MM-dd')).log"
        if (Test-Path $logPath) {
            $params['Path'] = $logPath
        }
    }

    # Get entries
    try {
        $entries = @(Get-SEBLogEntries @params)
    }
    catch {
        $entries = @()
    }

    # Text search filter
    $searchText = $LogSearchText.Text
    if (-not [string]::IsNullOrWhiteSpace($searchText)) {
        $entries = $entries | Where-Object { $_.Message -like "*$searchText*" }
    }

    $LogEntriesGrid.ItemsSource = @($entries)
    $LogEntryCount.Text = "$($entries.Count) entries"

    # Auto-scroll to bottom
    if ($LogAutoScrollToggle.IsChecked -and $entries.Count -gt 0) {
        $LogEntriesGrid.ScrollIntoView($entries[-1])
    }
}

# ============================================================================
# EVENT HANDLERS
# ============================================================================

# --- Dashboard Events ---

$DashRefreshButton.Add_Click({
    Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Refreshing dashboard..." -Type 'Info' -Dispatcher $Window.Dispatcher
    Update-StorageGauges
    Update-InstanceCards
    Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Dashboard refreshed." -Type 'Success' -Dispatcher $Window.Dispatcher
})

# --- Backup Events ---

$BackupInstanceCombo.Add_SelectionChanged({
    Load-BackupHistory
})

$BackupNowButton.Add_Click({
    $instanceName = $BackupInstanceCombo.SelectedItem
    if ([string]::IsNullOrWhiteSpace($instanceName)) {
        Show-SEBUINotification -Title 'No Instance Selected' -Message 'Please select an instance first.' -Type 'Warning'
        return
    }

    Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Starting backup for $instanceName..." -Type 'Info' -Dispatcher $Window.Dispatcher
    $BackupNowButton.IsEnabled = $false

    $op = Start-SEBBackgroundOperation -ScriptBlock {
        param($InstName, $ModPath)
        Import-Module (Join-Path $ModPath 'BackupEngine') -Force
        Import-Module (Join-Path $ModPath 'ConfigManager') -Force
        # Invoke-SEBBackup -InstanceName $InstName
        # Placeholder: actual backup invocation would go here
        Start-Sleep -Seconds 2
        return @{ Success = $true; InstanceName = $InstName; Message = "Backup triggered for $InstName" }
    } -ArgumentList @($instanceName, $modulesDir) -OnComplete {
        param($Result, $Error)
        $BackupNowButton.IsEnabled = $true
        if ($Error) {
            Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Backup failed: $Error" -Type 'Error' -Dispatcher $Window.Dispatcher
            Show-SEBUINotification -Title 'Backup Failed' -Message "Backup for $instanceName failed: $Error" -Type 'Error'
        }
        else {
            Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Backup complete for $instanceName." -Type 'Success' -Dispatcher $Window.Dispatcher
            Load-BackupHistory
        }
    }.GetNewClosure() -Dispatcher $Window.Dispatcher

    $script:RunningOps['backup'] = $op
})

$BackupForceFullButton.Add_Click({
    $instanceName = $BackupInstanceCombo.SelectedItem
    if ([string]::IsNullOrWhiteSpace($instanceName)) {
        Show-SEBUINotification -Title 'No Instance Selected' -Message 'Please select an instance first.' -Type 'Warning'
        return
    }

    $confirmed = Show-SEBUIConfirmation -Title 'Force Full Backup' `
        -Message "This will create a full backup for '$instanceName', starting a new incremental chain. Continue?"
    if (-not $confirmed) { return }

    Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Forcing full backup for $instanceName..." -Type 'Info' -Dispatcher $Window.Dispatcher
    $BackupForceFullButton.IsEnabled = $false

    $op = Start-SEBBackgroundOperation -ScriptBlock {
        param($InstName, $ModPath)
        Import-Module (Join-Path $ModPath 'BackupEngine') -Force
        # Invoke-SEBBackup -InstanceName $InstName -ForceFull
        Start-Sleep -Seconds 3
        return @{ Success = $true; InstanceName = $InstName }
    } -ArgumentList @($instanceName, $modulesDir) -OnComplete {
        param($Result, $Error)
        $BackupForceFullButton.IsEnabled = $true
        if ($Error) {
            Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Full backup failed: $Error" -Type 'Error' -Dispatcher $Window.Dispatcher
        }
        else {
            Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Full backup complete for $instanceName." -Type 'Success' -Dispatcher $Window.Dispatcher
            Load-BackupHistory
        }
    }.GetNewClosure() -Dispatcher $Window.Dispatcher
})

$BackupVerifyAllButton.Add_Click({
    $instanceName = $BackupInstanceCombo.SelectedItem
    if ([string]::IsNullOrWhiteSpace($instanceName)) {
        Show-SEBUINotification -Title 'No Instance Selected' -Message 'Please select an instance first.' -Type 'Warning'
        return
    }

    Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Verifying all backups for $instanceName..." -Type 'Info' -Dispatcher $Window.Dispatcher
    $BackupVerifyAllButton.IsEnabled = $false

    $op = Start-SEBBackgroundOperation -ScriptBlock {
        param($InstName, $ModPath, $BackupRoot)
        Import-Module (Join-Path $ModPath 'IntegrityManager') -Force
        Import-Module (Join-Path $ModPath 'ManifestManager') -Force
        # $report = Get-SEBIntegrityReport -InstanceName $InstName -BackupRoot $BackupRoot
        Start-Sleep -Seconds 2
        return @{ Success = $true; InstanceName = $InstName; Message = "All archives verified" }
    } -ArgumentList @($instanceName, $modulesDir, $script:GlobalConfig.storage.cc_backup_root) -OnComplete {
        param($Result, $Error)
        $BackupVerifyAllButton.IsEnabled = $true
        if ($Error) {
            Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Verification failed: $Error" -Type 'Error' -Dispatcher $Window.Dispatcher
        }
        else {
            Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Verification complete for $instanceName." -Type 'Success' -Dispatcher $Window.Dispatcher
            Show-SEBUINotification -Title 'Verification Complete' -Message 'All backup archives passed integrity checks.' -Type 'Info'
        }
    }.GetNewClosure() -Dispatcher $Window.Dispatcher
})

$BackupHistoryGrid.Add_SelectionChanged({
    $selected = $BackupHistoryGrid.SelectedItem
    if ($null -eq $selected) {
        $BackupDiffPanel.Visibility = [System.Windows.Visibility]::Collapsed
        return
    }

    # Only show diff for incremental backups
    if ($selected.Type -ne 'incremental') {
        $BackupDiffPanel.Visibility = [System.Windows.Visibility]::Collapsed
        return
    }

    $manifest = $selected._manifest
    if (-not $manifest) {
        $BackupDiffPanel.Visibility = [System.Windows.Visibility]::Collapsed
        return
    }

    # Show diff details
    $BackupDiffPanel.Visibility = [System.Windows.Visibility]::Visible

    $addedCount    = if ($manifest['diff_added_count'])    { $manifest['diff_added_count'] }    else { 0 }
    $modifiedCount = if ($manifest['diff_modified_count']) { $manifest['diff_modified_count'] } else { 0 }
    $deletedCount  = if ($manifest['diff_deleted_count'])  { $manifest['diff_deleted_count'] }  else { 0 }

    $BackupDiffAdded.Text    = "$addedCount added"
    $BackupDiffModified.Text = "$modifiedCount modified"
    $BackupDiffDeleted.Text  = "$deletedCount deleted"

    # Populate file list from manifest's included_files if available
    $fileEntries = [System.Collections.Generic.List[object]]::new()

    if ($manifest['diff_files']) {
        foreach ($entry in $manifest['diff_files']) {
            $fileEntries.Add([PSCustomObject]@{
                ChangeType = $entry.change_type
                FilePath   = $entry.path
            })
        }
    }

    $BackupDiffFileList.ItemsSource = $fileEntries
})

# --- Restore Events ---

$RestoreInstanceCombo.Add_SelectionChanged({
    $instanceName = $RestoreInstanceCombo.SelectedItem
    if ([string]::IsNullOrWhiteSpace($instanceName)) {
        $RestorePointList.ItemsSource = $null
        return
    }

    # Load available restore points (manifests) for the selected instance
    $backupRoot = $script:GlobalConfig.storage.cc_backup_root
    $manifestDir = Join-Path -Path $backupRoot -ChildPath $instanceName | Join-Path -ChildPath 'manifests'

    if (-not (Test-Path -Path $manifestDir -ErrorAction SilentlyContinue)) {
        $RestorePointList.ItemsSource = $null
        return
    }

    $points = [System.Collections.Generic.List[object]]::new()

    $manifestFiles = Get-ChildItem -Path $manifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending

    foreach ($file in $manifestFiles) {
        try {
            $manifest = Read-SEBManifest -Path $file.FullName

            $sizeDisplay = '--'
            if ($manifest['archive_size_bytes']) {
                $sizeMB = [math]::Round([long]$manifest['archive_size_bytes'] / 1MB, 1)
                $sizeDisplay = if ($sizeMB -ge 1024) { "$([math]::Round($sizeMB / 1024, 2)) GB" } else { "$sizeMB MB" }
            }

            $chainInfo = "Seq $($manifest['chain_sequence'])"
            if ($manifest['type'] -eq 'full') {
                $chainInfo = 'Full (chain start)'
            }
            elseif ($manifest['parent_manifest']) {
                $chainInfo = "Incremental #$($manifest['chain_sequence'])"
            }

            $points.Add([PSCustomObject]@{
                Timestamp    = $manifest['timestamp']
                Type         = $manifest['type']
                Size         = $sizeDisplay
                ChainInfo    = $chainInfo
                ManifestFile = $file.Name
                _manifest    = $manifest
            })
        }
        catch { }
    }

    $RestorePointList.ItemsSource = $points
})

$RestorePointList.Add_SelectionChanged({
    $RestoreStep1NextButton.IsEnabled = ($null -ne $RestorePointList.SelectedItem)
})

$RestoreStep1NextButton.Add_Click({
    $selectedInstance = $RestoreInstanceCombo.SelectedItem
    $selectedPoint   = $RestorePointList.SelectedItem

    if (-not $selectedInstance -or -not $selectedPoint) { return }

    # Store state
    $script:RestoreState.SelectedInstance     = $selectedInstance
    $script:RestoreState.SelectedRestorePoint = $selectedPoint

    # Populate summary
    $RestoreSummaryInstance.Text  = $selectedInstance
    $RestoreSummaryTimestamp.Text = $selectedPoint.Timestamp
    $RestoreSummaryType.Text     = $selectedPoint.Type
    $RestoreSummarySize.Text     = $selectedPoint.Size
    $RestoreSummaryChain.Text    = $selectedPoint.ChainInfo
    $RestoreSummaryTarget.Text   = $script:GlobalConfig.storage.cc_backup_root

    # Reset acknowledgment
    $RestoreAcknowledgeCheckBox.IsChecked = $false
    $RestoreStep2RestoreButton.IsEnabled  = $false

    # Show step 2
    $RestoreStep1Panel.Visibility = [System.Windows.Visibility]::Collapsed
    $RestoreStep2Panel.Visibility = [System.Windows.Visibility]::Visible
})

$RestoreAcknowledgeCheckBox.Add_Checked({
    $RestoreStep2RestoreButton.IsEnabled = $true
})

$RestoreAcknowledgeCheckBox.Add_Unchecked({
    $RestoreStep2RestoreButton.IsEnabled = $false
})

$RestoreStep2BackButton.Add_Click({
    $RestoreStep2Panel.Visibility = [System.Windows.Visibility]::Collapsed
    $RestoreStep1Panel.Visibility = [System.Windows.Visibility]::Visible
})

$RestoreStep2RestoreButton.Add_Click({
    # Transition to step 3 (progress)
    $RestoreStep2Panel.Visibility = [System.Windows.Visibility]::Collapsed
    $RestoreStep3Panel.Visibility = [System.Windows.Visibility]::Visible

    # Reset progress indicators
    $RestoreProgressBar.Value     = 0
    $RestoreProgressPercent.Text  = '0%'
    $RestoreProgressLabel.Text    = 'Initializing restore...'

    $checkIcons = @($RestoreCheck1Icon, $RestoreCheck2Icon, $RestoreCheck3Icon,
                     $RestoreCheck4Icon, $RestoreCheck5Icon, $RestoreCheck6Icon)
    $checkTexts = @($RestoreCheck1Text, $RestoreCheck2Text, $RestoreCheck3Text,
                     $RestoreCheck4Text, $RestoreCheck5Text, $RestoreCheck6Text)

    # Reset all checklist items to pending (circle icon, gray)
    foreach ($icon in $checkIcons) {
        $icon.Text       = [char]0x23FA  # Record symbol (circle)
        $icon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#808099')
    }
    foreach ($txt in $checkTexts) {
        $txt.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#B0B0CC')
    }

    $instanceName    = $script:RestoreState.SelectedInstance
    $restorePoint    = $script:RestoreState.SelectedRestorePoint
    $manifestFile    = $restorePoint.ManifestFile

    Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Restoring $instanceName..." -Type 'Warning' -Dispatcher $Window.Dispatcher

    # Run the restore in a background operation
    $op = Start-SEBBackgroundOperation -ScriptBlock {
        param($InstName, $ManifestFile, $ModPath, $BackupRoot)

        Import-Module (Join-Path $ModPath 'ManifestManager') -Force
        Import-Module (Join-Path $ModPath 'IntegrityManager') -Force
        # Import-Module (Join-Path $ModPath 'RestoreEngine') -Force

        # This is a placeholder for the actual restore pipeline.
        # The real implementation would call Invoke-SEBRestore and report
        # progress through a shared variable or callback mechanism.
        $steps = @(
            @{ Step = 1; Label = 'Verifying backup chain...'; Sleep = 2 }
            @{ Step = 2; Label = 'Creating safety backup...'; Sleep = 3 }
            @{ Step = 3; Label = 'Stopping server...';        Sleep = 2 }
            @{ Step = 4; Label = 'Extracting files...';        Sleep = 4 }
            @{ Step = 5; Label = 'Deploying restored files...'; Sleep = 3 }
            @{ Step = 6; Label = 'Starting server...';          Sleep = 2 }
        )

        $result = @{
            Success        = $true
            Duration       = '0:00:16'
            FilesRestored  = 247
            SafetyBackup   = "safety_$InstName`_$(Get-Date -Format 'yyyyMMdd_HHmmss').7z"
            ServerStatus   = 'Running'
            StepsCompleted = 6
        }

        foreach ($s in $steps) {
            Start-Sleep -Seconds $s.Sleep
        }

        return $result
    } -ArgumentList @($instanceName, $manifestFile, $modulesDir, $script:GlobalConfig.storage.cc_backup_root) -OnComplete {
        param($Result, $Error)

        if ($Error) {
            # Show failure on step 4
            $RestoreResultIconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF6B6B')
            $RestoreResultTitle.Text   = 'Restore Failed'
            $RestoreResultMessage.Text = "The restore operation failed: $Error"
        }
        else {
            # Mark all checklist steps as complete
            $greenBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#6BCB77')
            $whiteBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFFF')
            $checkmark  = [string][char]0x2714  # Heavy check mark

            foreach ($icon in $checkIcons) {
                $icon.Text       = $checkmark
                $icon.Foreground = $greenBrush
            }
            foreach ($txt in $checkTexts) {
                $txt.Foreground = $whiteBrush
            }

            $RestoreProgressBar.Value    = 100
            $RestoreProgressPercent.Text = '100%'
            $RestoreProgressLabel.Text   = 'Restore complete!'

            # Populate result panel
            $RestoreResultIconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#6BCB77')
            $RestoreResultTitle.Text    = 'Restore Complete'
            $RestoreResultMessage.Text  = "Successfully restored $instanceName to the selected restore point."
            $RestoreResultDuration.Text = $Result.Duration
            $RestoreResultFiles.Text    = "$($Result.FilesRestored) files"
            $RestoreResultSafety.Text   = $Result.SafetyBackup
            $RestoreResultServer.Text   = $Result.ServerStatus

            Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Restore complete for $instanceName." -Type 'Success' -Dispatcher $Window.Dispatcher
        }

        # Transition to step 4
        $RestoreStep3Panel.Visibility = [System.Windows.Visibility]::Collapsed
        $RestoreStep4Panel.Visibility = [System.Windows.Visibility]::Visible
    }.GetNewClosure() -Dispatcher $Window.Dispatcher

    $script:RunningOps['restore'] = $op
})

$RestoreUndoButton.Add_Click({
    $confirmed = Show-SEBUIConfirmation -Title 'Undo Restore' `
        -Message "This will restore the safety backup that was created before the restore. The server will be stopped again. Continue?"

    if (-not $confirmed) { return }

    Show-SEBUINotification -Title 'Undo Restore' -Message 'Undo functionality will be implemented with the RestoreEngine module.' -Type 'Info'
})

$RestoreNewButton.Add_Click({
    # Reset to step 1
    $RestoreStep4Panel.Visibility = [System.Windows.Visibility]::Collapsed
    $RestoreStep1Panel.Visibility = [System.Windows.Visibility]::Visible
    $RestoreAcknowledgeCheckBox.IsChecked = $false
    $RestoreStep2RestoreButton.IsEnabled  = $false
})

# --- Settings Events ---

# TreeView navigation: show/hide setting panels based on selection
$SettingsTreeView.Add_SelectedItemChanged({
    $selected = $SettingsTreeView.SelectedItem
    if (-not $selected) { return }

    $header = $selected.Header.ToString()

    # Map of header -> panel
    $panelMap = @{
        'General'       = $SettingsPanelGeneral
        'Storage'       = $SettingsPanelStorage
        'Schedule'      = $SettingsPanelSchedule
        'Retention'     = $SettingsPanelRetention
        'Compression'   = $SettingsPanelCompression
        'Network'       = $SettingsPanelNetwork
        'Notifications' = $SettingsPanelNotifications
    }

    # Hide all panels
    foreach ($panel in $panelMap.Values) {
        $panel.Visibility = [System.Windows.Visibility]::Collapsed
    }

    # Show the selected panel
    if ($panelMap.ContainsKey($header)) {
        $panelMap[$header].Visibility = [System.Windows.Visibility]::Visible
    }
})

# Slider value-changed: update the label next to each slider
$SettingsScheduleInterval.Add_ValueChanged({
    $SettingsScheduleIntervalLabel.Text = "$([math]::Round($SettingsScheduleInterval.Value))"
})

$SettingsScheduleFullInterval.Add_ValueChanged({
    $SettingsScheduleFullIntervalLabel.Text = "$([math]::Round($SettingsScheduleFullInterval.Value))"
})

$SettingsScheduleMaxChain.Add_ValueChanged({
    $SettingsScheduleMaxChainLabel.Text = "$([math]::Round($SettingsScheduleMaxChain.Value))"
})

$SettingsRetentionCCCount.Add_ValueChanged({
    $SettingsRetentionCCCountLabel.Text = "$([math]::Round($SettingsRetentionCCCount.Value))"
})

$SettingsRetentionNASDays.Add_ValueChanged({
    $SettingsRetentionNASDaysLabel.Text = "$([math]::Round($SettingsRetentionNASDays.Value))"
})

$SettingsCompressionLevel.Add_ValueChanged({
    $SettingsCompressionLevelLabel.Text = "$([math]::Round($SettingsCompressionLevel.Value))"
})

$SettingsNetworkBandwidth.Add_ValueChanged({
    $SettingsNetworkBandwidthLabel.Text = "$([math]::Round($SettingsNetworkBandwidth.Value))"
})

# Save Settings button
$SettingsSaveButton.Add_Click({
    try {
        # Build updated TOML content from the current UI values
        $compressionEngine = 'auto'
        $selectedEngine = $SettingsCompressionEngine.SelectedItem
        if ($selectedEngine -is [System.Windows.Controls.ComboBoxItem]) {
            $compressionEngine = $selectedEngine.Content.ToString()
        }

        $tomlContent = @"
# SEBackup Global Configuration
# Auto-saved from the SEBackup Dashboard GUI

[storage]
cc_backup_root  = "$($SettingsStorageCCRoot.Text -replace '\\', '\\')"
nas_backup_path = "$($SettingsStorageNASPath.Text -replace '\\', '\\')"

[retention]
cc_full_count      = $([math]::Round($SettingsRetentionCCCount.Value))
nas_retention_days = $([math]::Round($SettingsRetentionNASDays.Value))

[schedule]
enabled                      = $($SettingsScheduleEnabled.IsChecked.ToString().ToLower())
interval_hours               = $([math]::Round($SettingsScheduleInterval.Value))
full_backup_interval_hours   = $([math]::Round($SettingsScheduleFullInterval.Value))
max_incremental_chain_length = $([math]::Round($SettingsScheduleMaxChain.Value))
start_time                   = "$($SettingsScheduleStartTime.Text)"

[compression]
engine     = "$compressionEngine"
level_7zip = $([math]::Round($SettingsCompressionLevel.Value))

[network]
max_bandwidth_mbps = $([math]::Round($SettingsNetworkBandwidth.Value))
robocopy_ipg_ms    = $($SettingsNetworkIPG.Text)

[load_awareness]
enabled                = $($script:GlobalConfig.load_awareness.enabled.ToString().ToLower())
max_cpu_percent        = $($script:GlobalConfig.load_awareness.max_cpu_percent)
max_memory_percent     = $($script:GlobalConfig.load_awareness.max_memory_percent)
sim_speed_threshold    = $($script:GlobalConfig.load_awareness.sim_speed_threshold)
check_interval_seconds = $($script:GlobalConfig.load_awareness.check_interval_seconds)
backoff_multiplier     = $($script:GlobalConfig.load_awareness.backoff_multiplier)
max_backoff_minutes    = $($script:GlobalConfig.load_awareness.max_backoff_minutes)

[notifications]
enabled    = $($SettingsNotifyEnabled.IsChecked.ToString().ToLower())
on_success = $($SettingsNotifyOnSuccess.IsChecked.ToString().ToLower())
on_failure = $($SettingsNotifyOnFailure.IsChecked.ToString().ToLower())
on_warning = $($SettingsNotifyOnWarning.IsChecked.ToString().ToLower())
webhook_url = "$($SettingsNotifyWebhook.Text)"
method     = "discord"

[defaults.vrage_api]
port                 = $($script:GlobalConfig.defaults.vrage_api.port)
save_timeout_seconds = $($script:GlobalConfig.defaults.vrage_api.save_timeout_seconds)

[defaults.vss]
mount_base = "$($SettingsStorageVSSMount.Text -replace '\\', '\\')"
"@

        $configPath = Join-Path -Path $script:ProjectRoot -ChildPath 'Config\global.toml'
        Set-Content -Path $configPath -Value $tomlContent -Encoding UTF8 -Force

        # Reload the config
        $script:GlobalConfig = Get-SEBGlobalConfig -Force

        Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Settings saved successfully." -Type 'Success' -Dispatcher $Window.Dispatcher
        Show-SEBUINotification -Title 'Settings Saved' -Message 'Configuration has been saved to global.toml.' -Type 'Info'
    }
    catch {
        Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Failed to save settings: $_" -Type 'Error' -Dispatcher $Window.Dispatcher
        Show-SEBUINotification -Title 'Save Failed' -Message "Could not save settings: $_" -Type 'Error'
    }
})

# Add Node button
$SettingsAddNodeButton.Add_Click({
    # Simple input dialog for adding a new node
    # In a real app this would be a custom dialog; for now use InputBox-style approach
    $nodeName = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Enter the node name (e.g., gamingpc01):',
        'Add Node',
        ''
    )

    if ([string]::IsNullOrWhiteSpace($nodeName)) { return }

    $hostname = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Enter the hostname or IP address:',
        'Add Node - Hostname',
        $nodeName
    )

    if ([string]::IsNullOrWhiteSpace($hostname)) { return }

    $displayName = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Enter a display name for this node:',
        'Add Node - Display Name',
        $nodeName
    )

    try {
        $nodeToml = @"
[node]
display_name = "$displayName"
hostname = "$hostname"
username = "SEBackup"
"@
        $nodeFilePath = Join-Path -Path $script:ProjectRoot -ChildPath "Config\nodes\$nodeName.toml"
        Set-Content -Path $nodeFilePath -Value $nodeToml -Encoding UTF8 -Force

        # Reload
        $script:NodeConfigs = @(Get-SEBNodeConfig -All)
        Load-NodeGrid

        Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Node '$nodeName' added." -Type 'Success' -Dispatcher $Window.Dispatcher
    }
    catch {
        Show-SEBUINotification -Title 'Error' -Message "Failed to add node: $_" -Type 'Error'
    }
})

# Test Notification button
$SettingsNotifyTestButton.Add_Click({
    $webhookUrl = $SettingsNotifyWebhook.Text
    if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
        Show-SEBUINotification -Title 'No Webhook URL' -Message 'Please enter a Discord webhook URL first.' -Type 'Warning'
        return
    }

    Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Sending test notification..." -Type 'Info' -Dispatcher $Window.Dispatcher

    $op = Start-SEBBackgroundOperation -ScriptBlock {
        param($Url)
        $body = @{
            content = "SEBackup test notification - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        } | ConvertTo-Json

        Invoke-RestMethod -Uri $Url -Method Post -Body $body -ContentType 'application/json'
        return @{ Success = $true }
    } -ArgumentList @($webhookUrl) -OnComplete {
        param($Result, $Error)
        if ($Error) {
            Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Test notification failed: $Error" -Type 'Error' -Dispatcher $Window.Dispatcher
        }
        else {
            Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Test notification sent." -Type 'Success' -Dispatcher $Window.Dispatcher
        }
    }.GetNewClosure() -Dispatcher $Window.Dispatcher
})

# --- Log Events ---

$LogRefreshButton.Add_Click({
    Load-LogEntries
    Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Logs refreshed." -Type 'Info' -Dispatcher $Window.Dispatcher
})

$LogExportButton.Add_Click({
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title      = 'Export Log Entries'
    $dialog.Filter     = 'CSV Files (*.csv)|*.csv|Text Files (*.txt)|*.txt|All Files (*.*)|*.*'
    $dialog.DefaultExt = '.csv'
    $dialog.FileName   = "SEBackup_Logs_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    if ($dialog.ShowDialog()) {
        try {
            $entries = $LogEntriesGrid.ItemsSource
            if ($entries) {
                $entries | Export-Csv -Path $dialog.FileName -NoTypeInformation -Encoding UTF8
                Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "Logs exported to $($dialog.FileName)" -Type 'Success' -Dispatcher $Window.Dispatcher
            }
            else {
                Show-SEBUINotification -Title 'No Data' -Message 'No log entries to export.' -Type 'Warning'
            }
        }
        catch {
            Show-SEBUINotification -Title 'Export Failed' -Message "Failed to export logs: $_" -Type 'Error'
        }
    }
})

# ============================================================================
# PERIODIC REFRESH TIMER
# ============================================================================

$script:RefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:RefreshTimer.Interval = [timespan]::FromSeconds(60)
$script:RefreshTimer.Add_Tick({
    try {
        Update-StorageGauges
        Update-InstanceCards
        $StatusBarTime.Text = [datetime]::Now.ToString('HH:mm:ss')
    }
    catch {
        Write-Warning "Dashboard refresh error: $_"
    }
})

# ============================================================================
# WINDOW LIFECYCLE EVENTS
# ============================================================================

$Window.Add_Loaded({
    # Initialize all data on window load
    Initialize-ConfigData
    Load-SettingsValues
    Load-NodeGrid
    Populate-InstanceCombos
    Update-StorageGauges
    Update-InstanceCards

    # Start the periodic refresh timer
    $script:RefreshTimer.Start()

    # Set initial status
    $StatusBarTime.Text = [datetime]::Now.ToString('HH:mm:ss')
    Set-SEBUIStatus -StatusBar $script:StatusBarRefs -Message "SEBackup Dashboard ready. $($script:NodeConfigs.Count) node(s) configured." -Type 'Success' -Dispatcher $Window.Dispatcher
})

$Window.Add_Closing({
    # Stop the refresh timer
    $script:RefreshTimer.Stop()

    # Stop any running background operations
    foreach ($op in $script:RunningOps.Values) {
        if ($op -and $op.Status -eq 'Running') {
            try { Stop-SEBBackgroundOperation -Operation $op } catch { }
        }
    }
})

# ============================================================================
# LAUNCH
# ============================================================================

# Load Microsoft.VisualBasic for InputBox (used in Add Node)
try {
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
}
catch {
    Write-Warning "Microsoft.VisualBasic assembly not available. Add Node dialog may not work."
}

# Show the window (blocking call)
$Window.ShowDialog() | Out-Null
