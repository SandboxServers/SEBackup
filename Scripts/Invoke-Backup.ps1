#Requires -Version 7.0
<#
.SYNOPSIS
    CLI entry point for the SEBackup backup operation.

.DESCRIPTION
    Initiates backup operations for Space Engineers Torch server instances
    managed by the SEBackup system. Supports backing up a single instance,
    all instances on a node, or all instances across all configured nodes.

    This script imports the SEBackup modules and delegates to the appropriate
    backup engine functions:
    - Single instance: Invoke-SEBBackup
    - All instances on a node: iterates instances and calls Invoke-SEBBackup
    - All nodes/instances: Invoke-SEBBackupAll

    Displays progress and results interactively.

.PARAMETER NodeName
    The name of the node to back up. Required unless -All is specified.

.PARAMETER InstanceName
    The name of a specific instance to back up. If omitted and NodeName is
    provided, all instances on that node are backed up.

.PARAMETER All
    When specified, backs up all instances across all configured nodes.
    Mutually exclusive with NodeName/InstanceName.

.PARAMETER ForceFull
    Forces a full backup even if an incremental backup would normally be
    performed based on the schedule.

.PARAMETER SkipLoadCheck
    Skips the pre-backup load awareness check. Use this to force a backup
    even when the server is under heavy load.

.PARAMETER SkipNotify
    Skips sending notifications after backup completion, even if notifications
    are enabled in global.toml.

.EXAMPLE
    .\Invoke-Backup.ps1 -NodeName "GameServer01" -InstanceName "PvPArena"
    # Backs up a single instance on a specific node.

.EXAMPLE
    .\Invoke-Backup.ps1 -NodeName "GameServer01"
    # Backs up all instances on GameServer01.

.EXAMPLE
    .\Invoke-Backup.ps1 -All
    # Backs up all instances across all configured nodes.

.EXAMPLE
    .\Invoke-Backup.ps1 -All -ForceFull
    # Forces a full backup of everything.

.EXAMPLE
    .\Invoke-Backup.ps1 -NodeName "GameServer01" -InstanceName "Survival" -SkipLoadCheck -SkipNotify
    # Backs up a single instance, ignoring load and notifications.

.OUTPUTS
    None. Progress and results are displayed interactively.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$NodeName,

    [Parameter(Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$InstanceName,

    [Parameter()]
    [switch]$All,

    [Parameter()]
    [switch]$ForceFull,

    [Parameter()]
    [switch]$SkipLoadCheck,

    [Parameter()]
    [switch]$SkipNotify
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
)

foreach ($mod in $moduleNames) {
    $modPath = Join-Path $modulesRoot "$mod\$mod.psm1"
    if (Test-Path $modPath) {
        Import-Module $modPath -Force -ErrorAction SilentlyContinue
    }
}

# ── Validate parameters ──────────────────────────────────────────────────────
if (-not $All -and -not $NodeName) {
    Write-Host ''
    Write-Host 'ERROR: Specify -NodeName (and optionally -InstanceName) or -All.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Usage:' -ForegroundColor White
    Write-Host '  .\Invoke-Backup.ps1 -NodeName "Server01" -InstanceName "PvPArena"' -ForegroundColor DarkGray
    Write-Host '  .\Invoke-Backup.ps1 -NodeName "Server01"                          # All instances on node' -ForegroundColor DarkGray
    Write-Host '  .\Invoke-Backup.ps1 -All                                          # Everything' -ForegroundColor DarkGray
    Write-Host ''
    return
}

if ($All -and ($NodeName -or $InstanceName)) {
    Write-Host ''
    Write-Host 'ERROR: -All cannot be combined with -NodeName or -InstanceName.' -ForegroundColor Red
    Write-Host ''
    return
}

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║                    SEBackup - Backup                        ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''

$startTime = Get-Date
$backupType = if ($ForceFull) { 'Full (forced)' } else { 'Auto (incremental or full)' }

if ($All) {
    Write-Host "  Target : All nodes and instances" -ForegroundColor White
}
elseif ($InstanceName) {
    Write-Host "  Node   : $NodeName" -ForegroundColor White
    Write-Host "  Instance: $InstanceName" -ForegroundColor White
}
else {
    Write-Host "  Node   : $NodeName (all instances)" -ForegroundColor White
}

Write-Host "  Type   : $backupType" -ForegroundColor White
Write-Host "  Started: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White
Write-Host ''

# ── Initialize logging context ───────────────────────────────────────────────
$logContext = $null
if (Get-Command -Name 'Start-SEBLogContext' -ErrorAction SilentlyContinue) {
    try {
        $logContext = Start-SEBLogContext -Operation 'Backup'
    }
    catch {
        Write-Verbose "Could not start log context: $_"
    }
}

# ── Execute backup ───────────────────────────────────────────────────────────
$results = [System.Collections.Generic.List[object]]::new()
$overallSuccess = $true

try {
    if ($All) {
        # ── Back up all nodes/instances ───────────────────────────────────
        Write-Host 'Backing up all nodes and instances...' -ForegroundColor Yellow
        Write-Host ''

        if (Get-Command -Name 'Invoke-SEBBackupAll' -ErrorAction SilentlyContinue) {
            $allResults = Invoke-SEBBackupAll `
                -ForceFull:$ForceFull `
                -SkipLoadCheck:$SkipLoadCheck `
                -SkipNotify:$SkipNotify

            if ($allResults) {
                foreach ($r in $allResults) { $results.Add($r) }
            }
        }
        else {
            # Fallback: iterate all nodes and instances manually
            $allNodes = Get-SEBNodeConfig -All
            if (-not $allNodes -or $allNodes.Count -eq 0) {
                Write-Host '  No nodes configured. Run Setup-Node.ps1 first.' -ForegroundColor Red
                $overallSuccess = $false
            }
            else {
                foreach ($node in $allNodes) {
                    $nodeName = $node._NodeName
                    Write-Host "  Processing node: $nodeName" -ForegroundColor Cyan

                    try {
                        $nodeSession = New-SEBSession -NodeName $nodeName -NodeConfig $node.node
                        $instances = Get-SEBAllInstanceConfigs -Session $nodeSession

                        if (-not $instances -or $instances.Count -eq 0) {
                            Write-Host "    No instances found on $nodeName" -ForegroundColor DarkYellow
                            continue
                        }

                        foreach ($inst in $instances) {
                            $instName = $inst._InstanceName
                            Write-Host "    Backing up: $instName..." -ForegroundColor White -NoNewline

                            try {
                                if (Get-Command -Name 'Invoke-SEBBackup' -ErrorAction SilentlyContinue) {
                                    $backupResult = Invoke-SEBBackup `
                                        -NodeName $nodeName `
                                        -InstanceName $instName `
                                        -ForceFull:$ForceFull `
                                        -SkipLoadCheck:$SkipLoadCheck `
                                        -SkipNotify:$SkipNotify
                                    $results.Add($backupResult)
                                    Write-Host ' Done' -ForegroundColor Green
                                }
                                else {
                                    Write-Host ' [BackupEngine not loaded]' -ForegroundColor Red
                                    $overallSuccess = $false
                                }
                            }
                            catch {
                                Write-Host " FAILED: $_" -ForegroundColor Red
                                $overallSuccess = $false
                                $results.Add([PSCustomObject]@{
                                    NodeName     = $nodeName
                                    InstanceName = $instName
                                    Success      = $false
                                    Error        = $_.Exception.Message
                                })
                            }
                        }
                    }
                    catch {
                        Write-Host "    ERROR: Cannot connect to $nodeName - $_" -ForegroundColor Red
                        $overallSuccess = $false
                    }
                    finally {
                        Remove-SEBSession -NodeName $nodeName -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
    elseif ($InstanceName) {
        # ── Back up single instance ───────────────────────────────────────
        Write-Host "Backing up $NodeName/$InstanceName..." -ForegroundColor Yellow

        if (Get-Command -Name 'Invoke-SEBBackup' -ErrorAction SilentlyContinue) {
            $backupResult = Invoke-SEBBackup `
                -NodeName $NodeName `
                -InstanceName $InstanceName `
                -ForceFull:$ForceFull `
                -SkipLoadCheck:$SkipLoadCheck `
                -SkipNotify:$SkipNotify

            $results.Add($backupResult)
        }
        else {
            Write-Host 'ERROR: BackupEngine module is not loaded or Invoke-SEBBackup is not available.' -ForegroundColor Red
            $overallSuccess = $false
        }
    }
    else {
        # ── Back up all instances on a node ───────────────────────────────
        Write-Host "Backing up all instances on node $NodeName..." -ForegroundColor Yellow
        Write-Host ''

        try {
            $nodeConfig = Get-SEBNodeConfig -NodeName $NodeName
            $nodeSession = New-SEBSession -NodeName $NodeName -NodeConfig $nodeConfig.node
            $instances = Get-SEBAllInstanceConfigs -Session $nodeSession

            if (-not $instances -or $instances.Count -eq 0) {
                Write-Host "  No instances found on $NodeName." -ForegroundColor DarkYellow
                Write-Host '  Register instances with Register-Instance.ps1.' -ForegroundColor DarkGray
            }
            else {
                foreach ($inst in $instances) {
                    $instName = $inst._InstanceName
                    Write-Host "  Backing up: $instName..." -ForegroundColor White -NoNewline

                    try {
                        if (Get-Command -Name 'Invoke-SEBBackup' -ErrorAction SilentlyContinue) {
                            $backupResult = Invoke-SEBBackup `
                                -NodeName $NodeName `
                                -InstanceName $instName `
                                -ForceFull:$ForceFull `
                                -SkipLoadCheck:$SkipLoadCheck `
                                -SkipNotify:$SkipNotify
                            $results.Add($backupResult)
                            Write-Host ' Done' -ForegroundColor Green
                        }
                        else {
                            Write-Host ' [BackupEngine not loaded]' -ForegroundColor Red
                            $overallSuccess = $false
                        }
                    }
                    catch {
                        Write-Host " FAILED: $_" -ForegroundColor Red
                        $overallSuccess = $false
                        $results.Add([PSCustomObject]@{
                            NodeName     = $NodeName
                            InstanceName = $instName
                            Success      = $false
                            Error        = $_.Exception.Message
                        })
                    }
                }
            }
        }
        catch {
            Write-Host "ERROR: Could not connect to node $NodeName - $_" -ForegroundColor Red
            $overallSuccess = $false
        }
        finally {
            Remove-SEBSession -NodeName $NodeName -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-Host ''
    Write-Host "CRITICAL ERROR: $_" -ForegroundColor Red
    $overallSuccess = $false
}
finally {
    if ($logContext -and (Get-Command -Name 'Stop-SEBLogContext' -ErrorAction SilentlyContinue)) {
        try { Stop-SEBLogContext } catch {}
    }
}

# ── Results Summary ───────────────────────────────────────────────────────────
$endTime = Get-Date
$duration = $endTime - $startTime

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║                     Backup Results                          ║' -ForegroundColor Cyan
Write-Host '╠══════════════════════════════════════════════════════════════╣' -ForegroundColor Cyan

if ($results.Count -gt 0) {
    $successes = @($results | Where-Object { $_.Success -eq $true })
    $failures  = @($results | Where-Object { $_.Success -eq $false })

    foreach ($r in $results) {
        $rNode = if ($r.NodeName) { $r.NodeName } else { 'Unknown' }
        $rInst = if ($r.InstanceName) { $r.InstanceName } else { 'Unknown' }
        $label = "${rNode}/${rInst}".PadRight(35)

        if ($r.Success) {
            Write-Host "║  [PASS]  $label                  ║" -ForegroundColor Green
        }
        else {
            Write-Host "║  [FAIL]  $label                  ║" -ForegroundColor Red
        }
    }

    Write-Host '╠══════════════════════════════════════════════════════════════╣' -ForegroundColor Cyan
    Write-Host "║  Succeeded: $($successes.Count)   Failed: $($failures.Count)   Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor White
}
else {
    if ($overallSuccess) {
        Write-Host '║  No backup operations were performed.                       ║' -ForegroundColor DarkYellow
    }
    else {
        Write-Host '║  Backup operation encountered errors.                       ║' -ForegroundColor Red
    }
}

Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''
