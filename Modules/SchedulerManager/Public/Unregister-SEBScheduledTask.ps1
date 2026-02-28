function Unregister-SEBScheduledTask {
    <#
    .SYNOPSIS
        Removes the SEBackup scheduled task from Windows Task Scheduler.

    .DESCRIPTION
        Unregisters (deletes) the specified SEBackup scheduled task from Windows
        Task Scheduler. By default, the user is prompted for confirmation before
        the task is removed. Use the -Force switch to suppress the confirmation
        prompt.

        If the specified task does not exist, a warning is issued and no error
        is thrown.

    .PARAMETER TaskName
        The name of the scheduled task to remove from Windows Task Scheduler.
        Defaults to "SEBackup-Scheduled".

    .PARAMETER Force
        Suppresses the confirmation prompt and removes the task immediately.

    .OUTPUTS
        None

    .EXAMPLE
        Unregister-SEBScheduledTask
        # Prompts for confirmation, then removes the "SEBackup-Scheduled" task

    .EXAMPLE
        Unregister-SEBScheduledTask -Force
        # Removes the "SEBackup-Scheduled" task without prompting

    .EXAMPLE
        Unregister-SEBScheduledTask -TaskName "MyBackupTask" -Force
        # Removes a custom-named task without prompting

    .NOTES
        Requires administrator privileges to unregister tasks that were
        registered with highest privileges.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$TaskName = 'SEBackup-Scheduled',

        [Parameter()]
        [switch]$Force
    )

    process {
        # Check if the task exists
        $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $existingTask) {
            Write-Warning "Scheduled task '$TaskName' does not exist. Nothing to remove."
            return
        }

        # Prompt for confirmation unless Force is specified
        if (-not $Force) {
            $confirmation = Read-Host -Prompt "Are you sure you want to remove the scheduled task '$TaskName'? (y/N)"
            if ($confirmation -notin @('y', 'yes', 'Y', 'Yes', 'YES')) {
                Write-Verbose "Removal of task '$TaskName' cancelled by user."
                return
            }
        }

        if ($PSCmdlet.ShouldProcess("Task Scheduler", "Unregister task '$TaskName'")) {
            try {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
                Write-Verbose "Scheduled task '$TaskName' has been removed successfully."
            }
            catch {
                throw "Failed to remove scheduled task '$TaskName': $_"
            }
        }
    }
}
