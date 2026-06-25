#Requires -Version 7.0
<#
.SYNOPSIS
    CLI entry point for the SEBackup restore operation.

.DESCRIPTION
    Restores a Space Engineers Torch server world save from a backup archive.
    Supports listing available restore points, selecting a specific restore
    point, and performing the restore with safety backup and confirmation.

    This script handles the interactive workflow and delegates to the
    RestoreEngine module for the actual restore operation.

.PARAMETER NodeName
    The name of the node where the instance to restore is located.

.PARAMETER InstanceName
    The name of the instance to restore.

.PARAMETER RestorePoint
    The identifier of a specific restore point to use (e.g., a backup manifest
    filename or timestamp). If not provided, the script lists available restore
    points and prompts for selection.

.PARAMETER ListPoints
    When specified, displays available restore points in a formatted table
    and exits without performing a restore.

.PARAMETER SkipSafetyBackup
    When specified, skips the pre-restore safety backup. By default, a safety
    backup is taken before any restore to allow recovery if something goes wrong.

.PARAMETER Force
    Suppresses the confirmation prompt before performing the restore.

.EXAMPLE
    .\Invoke-Restore.ps1 -NodeName "GameServer01" -InstanceName "PvPArena" -ListPoints
    # Lists all available restore points for the PvPArena instance.

.EXAMPLE
    .\Invoke-Restore.ps1 -NodeName "GameServer01" -InstanceName "PvPArena"
    # Shows restore points, prompts for selection, then restores.

.EXAMPLE
    .\Invoke-Restore.ps1 -NodeName "GameServer01" -InstanceName "PvPArena" -RestorePoint "2025-01-15_020000_full"
    # Restores from a specific restore point.

.EXAMPLE
    .\Invoke-Restore.ps1 -NodeName "GameServer01" -InstanceName "Survival" -Force -SkipSafetyBackup
    # Restores without confirmation or safety backup (use with caution).

.OUTPUTS
    None. Progress and results are displayed interactively.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$NodeName,

    [Parameter(Mandatory, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$InstanceName,

    [Parameter()]
    [string]$RestorePoint,

    [Parameter()]
    [switch]$ListPoints,

    [Parameter()]
    [switch]$SkipSafetyBackup,

    [Parameter()]
    [switch]$Force
)

# ── Import SEBackup modules ──────────────────────────────────────────────────
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$modulesRoot = Join-Path $projectRoot 'Modules'

$moduleNames = @(
    'Logger'
    'ConfigManager'
    'CredentialManager'
    'RemoteManager'
    'VRageAPI'
    'VSSManager'
    'ManifestManager'
    'IntegrityManager'
    'CompressionManager'
    'LoadMonitor'
    'NetworkThrottle'
    'NotificationManager'
    'MetricsCollector'
    'BackupEngine'
    'RestoreEngine'
)

foreach ($mod in $moduleNames) {
    $modPath = Join-Path $modulesRoot "$mod\$mod.psm1"
    if (Test-Path $modPath) {
        Import-Module $modPath -Force -ErrorAction SilentlyContinue
    }
}

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║                   SEBackup - Restore                        ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Node     : $NodeName" -ForegroundColor White
Write-Host "  Instance : $InstanceName" -ForegroundColor White
Write-Host ''

# ── Load configuration ───────────────────────────────────────────────────────
Write-Host 'Loading configuration...' -ForegroundColor Yellow

$nodeConfig = $null
$globalConfig = $null

try {
    $nodeConfig = Get-SEBNodeConfig -NodeName $NodeName
    if (-not $nodeConfig) {
        throw "Node config not found for '$NodeName'."
    }
    $globalConfig = Get-SEBGlobalConfig
}
catch {
    Write-Host "  ERROR: $_" -ForegroundColor Red
    Write-Host '  Verify the node is configured with Setup-Node.ps1.' -ForegroundColor DarkYellow
    return
}

$hostname = $nodeConfig.node.hostname
# Resolve the backup root the same way the RestoreEngine does. The backup engine writes to
# {backupRoot}\{InstanceName}\... (NO per-node level), so discovery must use the same root and
# defer the layout walk to Get-SEBRestorePoints.
$backupRoot = $globalConfig.storage.cc_backup_root

# ── Discover available restore points ────────────────────────────────────────
Write-Host 'Discovering available restore points...' -ForegroundColor Yellow
Write-Host ''

$restorePoints = [System.Collections.Generic.List[object]]::new()

try {
    # Use the RestoreEngine's authoritative discovery. It walks the real on-disk layout
    # ({backupRoot}\{InstanceName}\manifests\*.json with matching archives under full\ /
    # incremental\), validates each backup chain, and already excludes '_BAD' artifacts (a backup
    # renamed '_BAD' failed integrity and must never be offered as a restore point). The previous
    # bespoke walk searched {backupRoot}\{NodeName}\{InstanceName}\*.manifest.json -- an extra
    # NodeName level AND the wrong extension -- so it found zero points against real backups.
    if (-not (Get-Command -Name 'Get-SEBRestorePoints' -ErrorAction SilentlyContinue)) {
        throw 'RestoreEngine (Get-SEBRestorePoints) is not available; cannot discover restore points.'
    }

    $enginePoints = Get-SEBRestorePoints -InstanceName $InstanceName -BackupRoot $backupRoot

    $index = 0
    foreach ($ep in $enginePoints) {
        $index++

        # Format the timestamp (manifests store ISO 8601 UTC). Fall back to the raw value if it
        # does not parse so a point is never silently dropped from the list.
        $dateDisplay = "$($ep.Timestamp)"
        $parsedDate = [datetime]::MinValue
        if ([datetime]::TryParse([string]$ep.Timestamp, [ref]$parsedDate)) {
            $dateDisplay = $parsedDate.ToString('yyyy-MM-dd HH:mm:ss')
        }

        $restorePoints.Add([PSCustomObject]@{
            Index        = $index
            # The exact manifest filename (incl. extension). Invoke-SEBRestore ->
            # Test-SEBRestoreChain resolves -RestorePoint as a filename in the manifests dir
            # without appending an extension, so the call site must pass this leaf name.
            ManifestName = (Split-Path -Path $ep.ManifestFile -Leaf)
            PointId      = ((Split-Path -Path $ep.ManifestFile -Leaf) -replace '\.json$', '')
            Date         = $dateDisplay
            Type         = $ep.Type
            SizeMB       = [math]::Round([double]$ep.SizeBytes / 1MB, 2)
            ChainValid   = $ep.ChainValid
            ManifestPath = $ep.ManifestFile
        })
    }
}
catch {
    Write-Host "  ERROR discovering restore points: $_" -ForegroundColor Red
}

if ($restorePoints.Count -eq 0) {
    Write-Host '  No restore points found.' -ForegroundColor Red
    Write-Host "  Backup directory: $(Join-Path $backupRoot $InstanceName)" -ForegroundColor DarkGray
    Write-Host ''
    return
}

# ── Display restore points ───────────────────────────────────────────────────
Write-Host "  Found $($restorePoints.Count) restore point(s):" -ForegroundColor White
Write-Host ''

$formatTable = @(
    @{ Label = '#';      Width = 4;  Property = 'Index' }
    @{ Label = 'Date';   Width = 20; Property = 'Date' }
    @{ Label = 'Type';   Width = 14; Property = 'Type' }
    @{ Label = 'Size MB'; Width = 10; Property = 'SizeMB' }
    @{ Label = 'Chain OK'; Width = 9; Property = 'ChainValid' }
    @{ Label = 'Restore Point ID'; Width = 40; Property = 'PointId' }
)

# Header
$header = '  '
$separator = '  '
foreach ($col in $formatTable) {
    $header += $col.Label.PadRight($col.Width) + '  '
    $separator += ('-' * $col.Width) + '  '
}
Write-Host $header -ForegroundColor Cyan
Write-Host $separator -ForegroundColor DarkGray

# Rows
foreach ($rp in $restorePoints) {
    $row = '  '
    foreach ($col in $formatTable) {
        $val = $rp.($col.Property)
        $row += "$val".PadRight($col.Width) + '  '
    }
    Write-Host $row -ForegroundColor White
}

Write-Host ''

# ── If -ListPoints, exit here ─────────────────────────────────────────────────
if ($ListPoints) {
    return
}

# ── Select restore point ─────────────────────────────────────────────────────
$selectedPoint = $null

if ($RestorePoint) {
    # Match by PointId
    $selectedPoint = $restorePoints | Where-Object { $_.PointId -eq $RestorePoint } | Select-Object -First 1
    if (-not $selectedPoint) {
        # Try partial match
        $selectedPoint = $restorePoints | Where-Object { $_.PointId -like "*$RestorePoint*" } | Select-Object -First 1
    }
    if (-not $selectedPoint) {
        Write-Host "  ERROR: Restore point '$RestorePoint' not found." -ForegroundColor Red
        return
    }
    Write-Host "  Selected: $($selectedPoint.PointId) ($($selectedPoint.Date))" -ForegroundColor Green
}
else {
    # Prompt for selection
    do {
        $selection = Read-Host '  Select a restore point (enter number, or q to quit)'
        if ($selection -eq 'q' -or $selection -eq 'Q') {
            Write-Host '  Restore cancelled.' -ForegroundColor DarkYellow
            return
        }
        $selectionInt = 0
        $valid = [int]::TryParse($selection, [ref]$selectionInt)
    } while (-not $valid -or $selectionInt -lt 1 -or $selectionInt -gt $restorePoints.Count)

    $selectedPoint = $restorePoints | Where-Object { $_.Index -eq $selectionInt } | Select-Object -First 1
    Write-Host "  Selected: $($selectedPoint.PointId) ($($selectedPoint.Date))" -ForegroundColor Green
}

Write-Host ''

# ── Confirmation ──────────────────────────────────────────────────────────────
if (-not $Force) {
    Write-Host '  WARNING: This will overwrite the current world save!' -ForegroundColor Red
    Write-Host "  Restore point : $($selectedPoint.PointId)" -ForegroundColor White
    Write-Host "  Date          : $($selectedPoint.Date)" -ForegroundColor White
    Write-Host "  Type          : $($selectedPoint.Type)" -ForegroundColor White
    Write-Host ''

    if (-not $PSCmdlet.ShouldProcess("Restore $InstanceName on $NodeName from $($selectedPoint.PointId)", 'Restore world save')) {
        Write-Host '  Restore cancelled.' -ForegroundColor DarkYellow
        return
    }

    $confirm = Read-Host '  Type "RESTORE" to confirm'
    if ($confirm -ne 'RESTORE') {
        Write-Host '  Restore cancelled.' -ForegroundColor DarkYellow
        return
    }
}

# ── Initialize logging ───────────────────────────────────────────────────────
$logContext = $null
if (Get-Command -Name 'Start-SEBLogContext' -ErrorAction SilentlyContinue) {
    try {
        $logContext = Start-SEBLogContext -Context 'Restore'
    }
    catch {
        Write-Verbose "Could not start log context: $_"
    }
}

$startTime = Get-Date
$restoreSuccess = $false

try {
    # ── Step 1: Safety backup ─────────────────────────────────────────────
    if (-not $SkipSafetyBackup) {
        Write-Host '[1/4] Creating safety backup of current world...' -ForegroundColor Yellow

        # The safety backup is the ONLY recovery point if the restore goes wrong, so a failure
        # here must abort the restore (the user can opt out explicitly with -SkipSafetyBackup).
        if (-not (Get-Command -Name 'Invoke-SEBBackup' -ErrorAction SilentlyContinue)) {
            throw "BackupEngine (Invoke-SEBBackup) is not available, so no safety backup can be taken. Aborting restore. Re-run with -SkipSafetyBackup to bypass this safeguard intentionally."
        }

        try {
            $safetyResult = Invoke-SEBBackup `
                -NodeName $NodeName `
                -InstanceName $InstanceName `
                -ForceFull `
                -SkipLoadCheck `
                -SkipNotify
        }
        catch {
            throw "Safety backup threw an error: $_. Aborting restore to preserve the current world. Re-run with -SkipSafetyBackup to bypass."
        }

        if ($safetyResult -and $safetyResult.Success) {
            Write-Host '  [PASS] Safety backup created.' -ForegroundColor Green
        }
        else {
            $safetyError = if ($safetyResult) { $safetyResult.ErrorMessage } else { 'no result returned' }
            throw "Safety backup failed ($safetyError). Aborting restore so the current world is not left without a recovery point. Re-run with -SkipSafetyBackup to bypass this safeguard."
        }
    }
    else {
        Write-Host '[1/4] Skipping safety backup (-SkipSafetyBackup specified).' -ForegroundColor DarkGray
    }

    # ── Step 2: Connect to node ───────────────────────────────────────────
    Write-Host '[2/4] Connecting to node...' -ForegroundColor Yellow
    $session = $null
    try {
        $session = New-SEBSession -NodeName $NodeName -NodeConfig $nodeConfig.node
        Write-Host "  [PASS] Connected to $hostname." -ForegroundColor Green
    }
    catch {
        throw "Cannot connect to node '$NodeName': $_"
    }

    # ── Step 3: Perform restore ───────────────────────────────────────────
    Write-Host '[3/4] Restoring world save...' -ForegroundColor Yellow
    Write-Host "  Source: $($selectedPoint.ManifestPath)" -ForegroundColor DarkGray

    if (Get-Command -Name 'Invoke-SEBRestore' -ErrorAction SilentlyContinue) {
        # Pass the full manifest filename (incl. extension). Test-SEBRestoreChain resolves
        # -RestorePoint as a filename in the manifests dir without appending an extension, so the
        # extension-stripped PointId would point at a non-existent file and fail chain validation.
        $restoreResult = Invoke-SEBRestore `
            -NodeName $NodeName `
            -InstanceName $InstanceName `
            -RestorePoint $selectedPoint.ManifestName

        if ($restoreResult -and $restoreResult.Success) {
            $restoreSuccess = $true
            Write-Host '  [PASS] World save restored successfully.' -ForegroundColor Green
        }
        else {
            $errorMsg = if ($restoreResult -and $restoreResult.Error) { $restoreResult.Error } else { 'Unknown error' }
            throw "Restore operation failed: $errorMsg"
        }
    }
    else {
        Write-Host '  [ERROR] RestoreEngine module is not loaded.' -ForegroundColor Red
        Write-Host '          Invoke-SEBRestore function is not available.' -ForegroundColor DarkYellow
        throw 'RestoreEngine module not available.'
    }

    # ── Step 4: Verify restore ────────────────────────────────────────────
    Write-Host '[4/4] Verifying restore...' -ForegroundColor Yellow
    try {
        $instanceConfig = Get-SEBInstanceConfig -Session $session -InstanceName $InstanceName
        $worldPath = $instanceConfig.paths.world_save

        $verifyResult = Invoke-Command -Session $session -ScriptBlock {
            param($WorldPath)

            $sandboxFile = Join-Path $WorldPath 'Sandbox.sbc'
            $lastSaveFile = Join-Path $WorldPath 'Sandbox_config.sbc'

            return @{
                WorldExists     = (Test-Path $WorldPath -PathType Container)
                SandboxExists   = (Test-Path $sandboxFile)
                LastModified    = if (Test-Path $WorldPath) { (Get-Item $WorldPath).LastWriteTime } else { $null }
            }
        } -ArgumentList $worldPath -ErrorAction Stop

        if ($verifyResult.WorldExists -and $verifyResult.SandboxExists) {
            Write-Host "  [PASS] World save verified (Last modified: $($verifyResult.LastModified))." -ForegroundColor Green
        }
        elseif ($verifyResult.WorldExists) {
            Write-Host '  [WARN] World directory exists but Sandbox.sbc not found.' -ForegroundColor DarkYellow
        }
        else {
            Write-Host '  [WARN] Could not verify restored world.' -ForegroundColor DarkYellow
        }
    }
    catch {
        Write-Host "  [WARN] Verification check failed: $_" -ForegroundColor DarkYellow
    }
}
catch {
    Write-Host ''
    Write-Host "  RESTORE FAILED: $_" -ForegroundColor Red
}
finally {
    # Clean up session
    Remove-SEBSession -NodeName $NodeName -ErrorAction SilentlyContinue

    if ($logContext -and (Get-Command -Name 'Stop-SEBLogContext' -ErrorAction SilentlyContinue)) {
        try { Stop-SEBLogContext } catch {}
    }
}

# ── Results ───────────────────────────────────────────────────────────────────
$endTime = Get-Date
$duration = $endTime - $startTime

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║                    Restore Results                          ║' -ForegroundColor Cyan
Write-Host '╠══════════════════════════════════════════════════════════════╣' -ForegroundColor Cyan

if ($restoreSuccess) {
    Write-Host '║  Status  : SUCCESS                                         ║' -ForegroundColor Green
}
else {
    Write-Host '║  Status  : FAILED                                          ║' -ForegroundColor Red
}

Write-Host "║  Node    : $($NodeName.PadRight(48))║" -ForegroundColor White
Write-Host "║  Instance: $($InstanceName.PadRight(48))║" -ForegroundColor White
Write-Host "║  Point   : $($selectedPoint.PointId.PadRight(48))║" -ForegroundColor White
Write-Host "║  Duration: $($duration.ToString('hh\:mm\:ss').PadRight(48))║" -ForegroundColor White
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan

if ($restoreSuccess) {
    Write-Host ''
    Write-Host '  Restore complete. Start the Torch server to use the restored world.' -ForegroundColor Green
}

Write-Host ''
