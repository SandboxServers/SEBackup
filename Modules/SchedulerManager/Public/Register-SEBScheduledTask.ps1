function Register-SEBScheduledTask {
    <#
    .SYNOPSIS
        Registers a Windows Task Scheduler task for automated SEBackup runs.

    .DESCRIPTION
        Creates a Windows Task Scheduler task that runs the SEBackup backup
        script (Invoke-Backup.ps1 -All) on a repeating interval. The task is
        configured based on the [schedule] section of the global configuration
        file, using interval_hours for the repetition interval and start_time
        for the initial trigger time.

        The task runs under the current user's identity with highest privileges
        and is configured to run whether the user is logged on or not.

        Task settings include:
        - Allow start on demand
        - Execution time limit of 4 hours
        - Runs on battery power (do not start if on batteries = false)
        - Does not stop on battery switch

    .PARAMETER TaskName
        The name to register the scheduled task under in Windows Task Scheduler.
        Defaults to "SEBackup-Scheduled".

    .PARAMETER GlobalConfig
        An optional hashtable containing the parsed global configuration. If not
        provided, the function reads the configuration from the standard
        Config/global.toml file relative to the project root.

    .OUTPUTS
        Microsoft.Management.Infrastructure.CimInstance#Root/Microsoft/Windows/TaskScheduler/MSFT_ScheduledTask
        The registered scheduled task object.

    .EXAMPLE
        Register-SEBScheduledTask
        # Registers a task named "SEBackup-Scheduled" using settings from global.toml

    .EXAMPLE
        Register-SEBScheduledTask -TaskName "MyBackupTask"
        # Registers a task with a custom name

    .EXAMPLE
        $config = Get-SEBGlobalConfig
        Register-SEBScheduledTask -GlobalConfig $config
        # Registers a task using an already-loaded configuration

    .NOTES
        Requires administrator privileges to register tasks that run with
        highest privileges and run whether logged on or not.
        Requires the ScheduledTasks PowerShell module (built into Windows).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([Microsoft.Management.Infrastructure.CimInstance])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$TaskName = 'SEBackup-Scheduled',

        [Parameter()]
        [hashtable]$GlobalConfig
    )

    begin {
        $projectRoot = Get-SEBProjectRoot
    }

    process {
        # Load configuration if not provided
        if (-not $GlobalConfig) {
            $configPath = Join-Path -Path $projectRoot -ChildPath 'Config\global.toml'
            if (-not (Test-Path -Path $configPath)) {
                throw "Global configuration file not found at '$configPath'. Run configuration setup first."
            }

            try {
                $rawToml = Get-Content -Path $configPath -Raw -ErrorAction Stop
                $GlobalConfig = ConvertFrom-Toml -InputObject $rawToml
            }
            catch {
                throw "Failed to parse global configuration at '$configPath': $_"
            }
        }

        # Extract schedule settings with defaults
        $schedule = $GlobalConfig['schedule']
        if (-not $schedule) {
            throw "Global configuration is missing the [schedule] section."
        }

        $intervalHours = if ($schedule.ContainsKey('interval_hours')) { $schedule['interval_hours'] } else { 6 }
        $startTime     = if ($schedule.ContainsKey('start_time')) { $schedule['start_time'] } else { '02:00' }

        # Parse the start time
        try {
            $triggerTime = [datetime]::ParseExact($startTime, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            throw "Invalid start_time '$startTime' in configuration. Expected format: HH:mm (24-hour)."
        }

        # Build the trigger: daily at start_time with repetition every interval_hours
        $triggerParams = @{
            Once               = $true
            At                 = $triggerTime
            RepetitionInterval = (New-TimeSpan -Hours $intervalHours)
        }
        $trigger = New-ScheduledTaskTrigger @triggerParams

        # Build the action: run pwsh.exe with the backup script
        $scriptPath = Join-Path -Path $projectRoot -ChildPath 'Scripts\Invoke-Backup.ps1'
        $action = New-ScheduledTaskAction -Execute 'pwsh.exe' `
            -Argument "-NoProfile -File `"$scriptPath`" -All" `
            -WorkingDirectory $projectRoot

        # Build the principal: current user, highest privileges, run whether logged on or not.
        # S4U logon loads no user profile and has "no access to encrypted files" (per Microsoft),
        # which historically broke CurrentUser-DPAPI credentials under the task. As of issue #27,
        # Save-SEBCredential stores node credentials with LocalMachine-scope DPAPI (machine-bound,
        # not user-bound) plus a restrictive ACL, so an S4U task on THIS SAME C&C host can decrypt
        # them unattended. No stored task password or gMSA is required for credential decryption.
        $principal = New-ScheduledTaskPrincipal `
            -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
            -LogonType S4U `
            -RunLevel Highest

        Write-Verbose ("Scheduled task '$TaskName' uses S4U logon. Node credentials saved via " +
            "Save-SEBCredential use LocalMachine-DPAPI (issue #27) and decrypt under this task on " +
            "the same host. If credentials were saved on a DIFFERENT machine, re-save them on this " +
            "host with Save-SEBCredential (or Update-SEBCredential) so they are bound to this machine.")

        # An S4U task loads no user profile, so a node still holding ONLY a legacy
        # CurrentUser-DPAPI .cred.xml cannot be decrypted under it -- that node's
        # backup will fail until it is re-saved in the machine-bound protected format.
        # This is the exact pre-#27 state the store migrates, so surface it as a real
        # WARNING (not Verbose) at registration time rather than letting it fail later.
        $legacyCreds = Get-ChildItem -Path (Join-Path -Path $projectRoot -ChildPath 'Credentials') -Filter '*.cred.xml' -ErrorAction SilentlyContinue
        if ($legacyCreds) {
            Write-Warning ("$($legacyCreds.Count) node credential(s) are still in the legacy '.cred.xml' format and will " +
                "NOT decrypt under this unattended S4U task. Re-save each on THIS host before relying on the task: " +
                "Save-SEBCredential -NodeName '<node>' (or Update-SEBCredential). Affected: " +
                ($legacyCreds | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.BaseName) } | Sort-Object -Unique) -join ', ')
        }
        Write-Warning ("The task account ('$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)') must be a local " +
            "Administrator (or otherwise covered by the credential file ACL: SYSTEM + Administrators + the saving account) to " +
            "read the protected '.cred' files at run time.")

        # Build task settings
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Hours 4)

        # Check for existing task
        $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Warning "A scheduled task named '$TaskName' already exists. It will be overwritten."
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }

        # Register the task
        if ($PSCmdlet.ShouldProcess("Task Scheduler", "Register task '$TaskName' (every $intervalHours hours starting at $startTime)")) {
            $task = Register-ScheduledTask `
                -TaskName $TaskName `
                -Trigger $trigger `
                -Action $action `
                -Principal $principal `
                -Settings $settings `
                -Description "SEBackup automated backup task. Runs every $intervalHours hour(s) starting at $startTime. Manages Space Engineers Torch server backups."

            Write-Verbose "Scheduled task '$TaskName' registered successfully."
            Write-Verbose "  Interval : Every $intervalHours hour(s)"
            Write-Verbose "  Start    : $startTime"
            Write-Verbose "  Script   : $scriptPath"
            Write-Verbose "  Principal: $($principal.UserId) (Highest privileges, run whether logged on or not)"

            return $task
        }
    }
}
