function Get-SEBScheduleStatus {
    <#
    .SYNOPSIS
        Returns the current status of the SEBackup scheduled task.

    .DESCRIPTION
        Queries Windows Task Scheduler for the specified SEBackup task and
        returns a structured object containing its current state, next and last
        run times, last execution result, and configured trigger interval.

        If the task does not exist, the returned object will have Exists set to
        $false and all other properties will be $null.

    .PARAMETER TaskName
        The name of the scheduled task to query in Windows Task Scheduler.
        Defaults to "SEBackup-Scheduled".

    .OUTPUTS
        PSCustomObject
        An object with the following properties:
        - TaskName        [string]    : The name of the task queried.
        - Exists          [bool]      : Whether the task exists in Task Scheduler.
        - State           [string]    : Current state (Ready, Running, Disabled, or $null).
        - NextRunTime     [datetime]  : The next scheduled run time, or $null.
        - LastRunTime     [datetime]  : The last time the task ran, or $null.
        - LastResult      [int]       : The exit code from the last run, or $null.
        - TriggerInterval [timespan]  : The configured repetition interval, or $null.

    .EXAMPLE
        Get-SEBScheduleStatus

        TaskName        : SEBackup-Scheduled
        Exists          : True
        State           : Ready
        NextRunTime     : 2/28/2026 2:00:00 AM
        LastRunTime     : 2/27/2026 8:00:00 PM
        LastResult      : 0
        TriggerInterval : 06:00:00

    .EXAMPLE
        Get-SEBScheduleStatus -TaskName "MyBackupTask"
        # Queries a custom-named task

    .EXAMPLE
        $status = Get-SEBScheduleStatus
        if ($status.Exists -and $status.State -eq 'Ready') {
            Write-Host "Next backup at: $($status.NextRunTime)"
        }

    .NOTES
        Does not require administrator privileges to query task status.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$TaskName = 'SEBackup-Scheduled'
    )

    process {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

        if (-not $task) {
            Write-Verbose "Scheduled task '$TaskName' was not found in Task Scheduler."
            return [PSCustomObject]@{
                TaskName        = $TaskName
                Exists          = $false
                State           = $null
                NextRunTime     = $null
                LastRunTime     = $null
                LastResult      = $null
                TriggerInterval = $null
            }
        }

        # Get task info including last/next run times
        $taskInfo = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue

        # Extract the repetition interval from the first trigger
        $triggerInterval = $null
        if ($task.Triggers -and $task.Triggers.Count -gt 0) {
            $repetition = $task.Triggers[0].Repetition
            if ($repetition -and $repetition.Interval) {
                # The interval is stored as an ISO 8601 duration string (e.g., "PT6H")
                try {
                    $triggerInterval = [System.Xml.XmlConvert]::ToTimeSpan($repetition.Interval)
                }
                catch {
                    Write-Verbose "Could not parse trigger repetition interval '$($repetition.Interval)': $_"
                }
            }
        }

        # Map the task state to a friendly string
        $stateString = switch ($task.State) {
            0 { 'Unknown' }
            1 { 'Disabled' }
            2 { 'Queued' }
            3 { 'Ready' }
            4 { 'Running' }
            default { $task.State.ToString() }
        }

        $result = [PSCustomObject]@{
            TaskName        = $TaskName
            Exists          = $true
            State           = $stateString
            NextRunTime     = $taskInfo.NextRunTime
            LastRunTime     = $taskInfo.LastRunTime
            LastResult      = $taskInfo.LastTaskResult
            TriggerInterval = $triggerInterval
        }

        Write-Verbose "Task '$TaskName': State=$stateString, NextRun=$($taskInfo.NextRunTime), LastRun=$($taskInfo.LastRunTime), LastResult=$($taskInfo.LastTaskResult)"

        return $result
    }
}
