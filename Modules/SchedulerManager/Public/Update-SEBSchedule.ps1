function Update-SEBSchedule {
    <#
    .SYNOPSIS
        Updates settings on an existing SEBackup scheduled task without
        recreating it.

    .DESCRIPTION
        Modifies one or more properties of an existing SEBackup scheduled task
        in Windows Task Scheduler. Supported updates include the repetition
        interval, the trigger start time, and the enabled/disabled state.

        Only the parameters you specify are changed; all other task settings
        remain untouched. If no optional parameters are provided, the function
        returns the current task unchanged.

    .PARAMETER TaskName
        The name of the scheduled task to update in Windows Task Scheduler.
        Defaults to "SEBackup-Scheduled".

    .PARAMETER IntervalHours
        The new repetition interval in hours. Must be a positive integer.
        Updates the trigger's repetition interval without changing the start
        time or other task settings.

    .PARAMETER StartTime
        The new trigger start time in 24-hour format (HH:mm). Updates when the
        repeating trigger cycle begins each day.

    .PARAMETER Enabled
        Set to $true to enable the task or $false to disable it. When disabled,
        the task remains in Task Scheduler but will not run on its schedule.

    .OUTPUTS
        Microsoft.Management.Infrastructure.CimInstance#Root/Microsoft/Windows/TaskScheduler/MSFT_ScheduledTask
        The updated scheduled task object.

    .EXAMPLE
        Update-SEBSchedule -IntervalHours 4
        # Changes the backup interval to every 4 hours

    .EXAMPLE
        Update-SEBSchedule -StartTime "03:30"
        # Changes the trigger start time to 3:30 AM

    .EXAMPLE
        Update-SEBSchedule -Enabled $false
        # Disables the scheduled task without removing it

    .EXAMPLE
        Update-SEBSchedule -IntervalHours 8 -StartTime "01:00" -Enabled $true
        # Updates multiple settings at once

    .EXAMPLE
        Update-SEBSchedule -TaskName "MyBackupTask" -IntervalHours 12
        # Updates a custom-named task

    .NOTES
        Requires administrator privileges to modify tasks registered with
        highest privileges.
        The task must already exist in Task Scheduler. Use
        Register-SEBScheduledTask to create a new task.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([Microsoft.Management.Infrastructure.CimInstance])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$TaskName = 'SEBackup-Scheduled',

        [Parameter()]
        [ValidateRange(1, 168)]
        [int]$IntervalHours,

        [Parameter()]
        [ValidatePattern('^\d{2}:\d{2}$')]
        [string]$StartTime,

        [Parameter()]
        [bool]$Enabled
    )

    process {
        # Verify the task exists
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) {
            throw "Scheduled task '$TaskName' does not exist. Use Register-SEBScheduledTask to create it first."
        }

        $changesMade = @()

        # Update the trigger if IntervalHours or StartTime is specified
        if ($PSBoundParameters.ContainsKey('IntervalHours') -or $PSBoundParameters.ContainsKey('StartTime')) {
            # Determine the new start time
            $newStartTime = $null
            if ($PSBoundParameters.ContainsKey('StartTime')) {
                try {
                    $newStartTime = [datetime]::ParseExact($StartTime, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
                }
                catch {
                    throw "Invalid StartTime '$StartTime'. Expected format: HH:mm (24-hour)."
                }
            }
            else {
                # Preserve the existing start time from the current trigger
                if ($task.Triggers -and $task.Triggers.Count -gt 0) {
                    $existingStart = $task.Triggers[0].StartBoundary
                    if ($existingStart) {
                        try {
                            $newStartTime = [datetime]::Parse($existingStart)
                        }
                        catch {
                            Write-Warning "Could not parse existing trigger start time '$existingStart'. Using current time."
                            $newStartTime = Get-Date
                        }
                    }
                }
                if (-not $newStartTime) {
                    $newStartTime = Get-Date
                }
            }

            # Determine the new interval
            $newInterval = $null
            if ($PSBoundParameters.ContainsKey('IntervalHours')) {
                $newInterval = New-TimeSpan -Hours $IntervalHours
            }
            else {
                # Preserve the existing interval
                if ($task.Triggers -and $task.Triggers.Count -gt 0 -and $task.Triggers[0].Repetition.Interval) {
                    try {
                        $newInterval = [System.Xml.XmlConvert]::ToTimeSpan($task.Triggers[0].Repetition.Interval)
                    }
                    catch {
                        Write-Warning "Could not parse existing repetition interval. Defaulting to 6 hours."
                        $newInterval = New-TimeSpan -Hours 6
                    }
                }
                else {
                    $newInterval = New-TimeSpan -Hours 6
                }
            }

            # Build the new trigger
            $triggerParams = @{
                Once               = $true
                At                 = $newStartTime
                RepetitionInterval = $newInterval
            }
            $newTrigger = New-ScheduledTaskTrigger @triggerParams

            if ($PSBoundParameters.ContainsKey('IntervalHours')) {
                $changesMade += "Interval -> every $IntervalHours hour(s)"
            }
            if ($PSBoundParameters.ContainsKey('StartTime')) {
                $changesMade += "StartTime -> $StartTime"
            }

            if ($PSCmdlet.ShouldProcess("Task '$TaskName'", "Update trigger")) {
                Set-ScheduledTask -TaskName $TaskName -Trigger $newTrigger -ErrorAction Stop | Out-Null
            }
        }

        # Update the enabled/disabled state
        if ($PSBoundParameters.ContainsKey('Enabled')) {
            if ($Enabled) {
                if ($PSCmdlet.ShouldProcess("Task '$TaskName'", "Enable task")) {
                    Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
                    $changesMade += "State -> Enabled"
                }
            }
            else {
                if ($PSCmdlet.ShouldProcess("Task '$TaskName'", "Disable task")) {
                    Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
                    $changesMade += "State -> Disabled"
                }
            }
        }

        if ($changesMade.Count -eq 0) {
            Write-Verbose "No changes specified for task '$TaskName'. Task is unchanged."
        }
        else {
            foreach ($change in $changesMade) {
                Write-Verbose "Updated task '$TaskName': $change"
            }
        }

        # Return the updated task object
        $updatedTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        return $updatedTask
    }
}
