@{
    # Module manifest for SchedulerManager module - SEBackup Task Scheduling

    # Script module associated with this manifest
    RootModule        = 'SchedulerManager.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = 'eef4a14f-c7f9-46ea-9fef-5b6d1c0901c6'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'Windows Task Scheduler management module for the SEBackup Space Engineers Torch Server Backup & Restore System. Provides registration, removal, status querying, and live updating of scheduled backup tasks.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Modules that must be imported before this module
    RequiredModules   = @()

    # Functions to export from this module
    FunctionsToExport = @(
        'Register-SEBScheduledTask'
        'Unregister-SEBScheduledTask'
        'Get-SEBScheduleStatus'
        'Update-SEBSchedule'
    )

    # Cmdlets to export from this module
    CmdletsToExport   = @()

    # Variables to export from this module
    VariablesToExport  = @()

    # Aliases to export from this module
    AliasesToExport    = @()

    # Private data to pass to the module specified in RootModule
    PrivateData       = @{
        PSData = @{
            # Tags applied to this module for discoverability
            Tags       = @('Scheduler', 'TaskScheduler', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup SchedulerManager module.'
        }
    }
}
