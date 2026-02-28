#Requires -Version 7.0
<#
.SYNOPSIS
    Registers, updates, removes, or checks the status of SEBackup scheduled tasks.

.DESCRIPTION
    Manages Windows Task Scheduler jobs for automated SEBackup backup operations.
    The scheduled task runs Invoke-Backup.ps1 -All at the interval specified in
    global.toml (schedule.interval_hours, schedule.start_time).

    Supported actions:
    - Register : Creates a new scheduled task
    - Update   : Updates an existing scheduled task with current settings
    - Remove   : Removes the scheduled task
    - Status   : Shows the current scheduled task configuration

    The task runs under the current user account with highest privileges to ensure
    access to WinRM, VSS, and credential files.

.PARAMETER Action
    The action to perform: Register, Update, Remove, or Status.

.PARAMETER TaskName
    The name for the scheduled task. Defaults to "SEBackup-Scheduled".

.EXAMPLE
    .\Register-Schedule.ps1 -Action Register
    # Creates the scheduled task using global.toml settings.

.EXAMPLE
    .\Register-Schedule.ps1 -Action Status
    # Shows the current task status and next run time.

.EXAMPLE
    .\Register-Schedule.ps1 -Action Update
    # Updates the task with current global.toml schedule settings.

.EXAMPLE
    .\Register-Schedule.ps1 -Action Remove -TaskName "SEBackup-Scheduled"
    # Removes the scheduled task.

.OUTPUTS
    None. Results are displayed interactively via Write-Host.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Register', 'Update', 'Remove', 'Status')]
    [string]$Action,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'SEBackup-Scheduled'
)

# ── Import SEBackup modules ──────────────────────────────────────────────────
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$modulesRoot = Join-Path $projectRoot 'Modules'

$requiredModules = @('ConfigManager', 'Logger')
foreach ($mod in $requiredModules) {
    $modPath = Join-Path $modulesRoot "$mod\$mod.psm1"
    if (Test-Path $modPath) {
        Import-Module $modPath -Force -ErrorAction Stop
    }
}

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║               SEBackup - Schedule Manager                   ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''

# ── Load schedule settings from global.toml ───────────────────────────────────
$globalConfig = $null
try {
    $globalConfig = Get-SEBGlobalConfig
}
catch {
    Write-Host "  ERROR: Could not load global config: $_" -ForegroundColor Red
    return
}

$scheduleConfig = $globalConfig.schedule
$intervalHours = $scheduleConfig.interval_hours
$startTime = $scheduleConfig.start_time
$scheduleEnabled = $scheduleConfig.enabled

$invokeBackupPath = Join-Path $PSScriptRoot 'Invoke-Backup.ps1'

# ── Resolve PowerShell 7 path ────────────────────────────────────────────────
$pwshPath = (Get-Process -Id $PID).Path
if (-not $pwshPath -or -not (Test-Path $pwshPath)) {
    $pwshPath = 'pwsh.exe'
}

switch ($Action) {
    'Register' {
        Write-Host "  Action   : Register scheduled task" -ForegroundColor White
        Write-Host "  Task Name: $TaskName" -ForegroundColor White
        Write-Host "  Interval : Every $intervalHours hour(s)" -ForegroundColor White
        Write-Host "  Start    : $startTime" -ForegroundColor White
        Write-Host "  Script   : $invokeBackupPath" -ForegroundColor White
        Write-Host ''

        # Check if task already exists
        $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Host "  ERROR: Task '$TaskName' already exists." -ForegroundColor Red
            Write-Host '  Use -Action Update to modify, or -Action Remove to delete it first.' -ForegroundColor DarkYellow
            return
        }

        if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
            try {
                # Build the action: run Invoke-Backup.ps1 -All using pwsh
                $taskAction = New-ScheduledTaskAction `
                    -Execute $pwshPath `
                    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$invokeBackupPath`" -All" `
                    -WorkingDirectory $PSScriptRoot

                # Build the trigger: repeating at interval_hours starting from start_time
                $triggerTime = [datetime]::ParseExact($startTime, 'HH:mm', $null)
                $trigger = New-ScheduledTaskTrigger `
                    -Daily `
                    -At $triggerTime

                # For sub-daily intervals, add repetition
                if ($intervalHours -lt 24) {
                    $repetitionInterval = New-TimeSpan -Hours $intervalHours
                    $repetitionDuration = New-TimeSpan -Days 1
                    $trigger.Repetition = New-ScheduledTaskTrigger -Once -At $triggerTime `
                        -RepetitionInterval $repetitionInterval `
                        -RepetitionDuration $repetitionDuration |
                        Select-Object -ExpandProperty Repetition
                }

                # Build settings
                $settings = New-ScheduledTaskSettingsSet `
                    -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable `
                    -RunOnlyIfNetworkAvailable `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
                    -MultipleInstances IgnoreNew

                # Build principal: current user, highest privileges
                $principal = New-ScheduledTaskPrincipal `
                    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
                    -LogonType S4U `
                    -RunLevel Highest

                # Register the task
                Register-ScheduledTask `
                    -TaskName $TaskName `
                    -Action $taskAction `
                    -Trigger $trigger `
                    -Settings $settings `
                    -Principal $principal `
                    -Description "SEBackup automated backup - runs every $intervalHours hour(s) starting at $startTime" `
                    -ErrorAction Stop | Out-Null

                Write-Host "  [PASS] Scheduled task '$TaskName' registered successfully." -ForegroundColor Green
                Write-Host ''
                Write-Host '  The task will run backups automatically.' -ForegroundColor White
                Write-Host '  Use -Action Status to verify.' -ForegroundColor DarkGray
            }
            catch {
                Write-Host "  [FAIL] Task registration failed: $_" -ForegroundColor Red
                Write-Host '         You may need to run this as Administrator.' -ForegroundColor DarkYellow
            }
        }
    }

    'Update' {
        Write-Host "  Action   : Update scheduled task" -ForegroundColor White
        Write-Host "  Task Name: $TaskName" -ForegroundColor White
        Write-Host "  Interval : Every $intervalHours hour(s)" -ForegroundColor White
        Write-Host "  Start    : $startTime" -ForegroundColor White
        Write-Host ''

        $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $existingTask) {
            Write-Host "  ERROR: Task '$TaskName' does not exist." -ForegroundColor Red
            Write-Host '  Use -Action Register to create it first.' -ForegroundColor DarkYellow
            return
        }

        if ($PSCmdlet.ShouldProcess($TaskName, 'Update scheduled task')) {
            try {
                # Update action
                $taskAction = New-ScheduledTaskAction `
                    -Execute $pwshPath `
                    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$invokeBackupPath`" -All" `
                    -WorkingDirectory $PSScriptRoot

                # Update trigger
                $triggerTime = [datetime]::ParseExact($startTime, 'HH:mm', $null)
                $trigger = New-ScheduledTaskTrigger `
                    -Daily `
                    -At $triggerTime

                if ($intervalHours -lt 24) {
                    $repetitionInterval = New-TimeSpan -Hours $intervalHours
                    $repetitionDuration = New-TimeSpan -Days 1
                    $trigger.Repetition = New-ScheduledTaskTrigger -Once -At $triggerTime `
                        -RepetitionInterval $repetitionInterval `
                        -RepetitionDuration $repetitionDuration |
                        Select-Object -ExpandProperty Repetition
                }

                Set-ScheduledTask `
                    -TaskName $TaskName `
                    -Action $taskAction `
                    -Trigger $trigger `
                    -ErrorAction Stop | Out-Null

                Write-Host "  [PASS] Scheduled task '$TaskName' updated." -ForegroundColor Green
            }
            catch {
                Write-Host "  [FAIL] Task update failed: $_" -ForegroundColor Red
            }
        }
    }

    'Remove' {
        Write-Host "  Action   : Remove scheduled task" -ForegroundColor White
        Write-Host "  Task Name: $TaskName" -ForegroundColor White
        Write-Host ''

        $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $existingTask) {
            Write-Host "  Task '$TaskName' does not exist. Nothing to remove." -ForegroundColor DarkYellow
            return
        }

        if ($PSCmdlet.ShouldProcess($TaskName, 'Remove scheduled task')) {
            try {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
                Write-Host "  [PASS] Scheduled task '$TaskName' removed." -ForegroundColor Green
            }
            catch {
                Write-Host "  [FAIL] Task removal failed: $_" -ForegroundColor Red
            }
        }
    }

    'Status' {
        Write-Host "  Task Name: $TaskName" -ForegroundColor White
        Write-Host ''

        $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $existingTask) {
            Write-Host "  Task '$TaskName' is not registered." -ForegroundColor DarkYellow
            Write-Host '  Use -Action Register to create it.' -ForegroundColor DarkGray
            Write-Host ''

            Write-Host '  Current global.toml schedule settings:' -ForegroundColor White
            Write-Host "    Enabled        : $scheduleEnabled" -ForegroundColor DarkGray
            Write-Host "    Interval (hrs) : $intervalHours" -ForegroundColor DarkGray
            Write-Host "    Start time     : $startTime" -ForegroundColor DarkGray
            return
        }

        $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue

        Write-Host '  Task Configuration:' -ForegroundColor Cyan
        Write-Host "    State          : $($existingTask.State)" -ForegroundColor White
        Write-Host "    Description    : $($existingTask.Description)" -ForegroundColor White

        if ($existingTask.Actions -and $existingTask.Actions.Count -gt 0) {
            Write-Host "    Execute        : $($existingTask.Actions[0].Execute)" -ForegroundColor White
            Write-Host "    Arguments      : $($existingTask.Actions[0].Arguments)" -ForegroundColor White
        }

        if ($existingTask.Triggers -and $existingTask.Triggers.Count -gt 0) {
            $trig = $existingTask.Triggers[0]
            Write-Host "    Trigger        : $($trig.CimClass.CimClassName)" -ForegroundColor White
            if ($trig.StartBoundary) {
                Write-Host "    Start Boundary : $($trig.StartBoundary)" -ForegroundColor White
            }
        }

        if ($taskInfo) {
            Write-Host ''
            Write-Host '  Execution History:' -ForegroundColor Cyan
            Write-Host "    Last Run Time  : $($taskInfo.LastRunTime)" -ForegroundColor White
            Write-Host "    Last Result    : $($taskInfo.LastTaskResult)" -ForegroundColor White
            Write-Host "    Next Run Time  : $($taskInfo.NextRunTime)" -ForegroundColor White
            Write-Host "    Missed Runs    : $($taskInfo.NumberOfMissedRuns)" -ForegroundColor White
        }

        Write-Host ''
        Write-Host '  Global.toml schedule settings:' -ForegroundColor Cyan
        Write-Host "    Enabled        : $scheduleEnabled" -ForegroundColor White
        Write-Host "    Interval (hrs) : $intervalHours" -ForegroundColor White
        Write-Host "    Start time     : $startTime" -ForegroundColor White
    }
}

Write-Host ''
