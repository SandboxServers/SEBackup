@{
    # Module manifest for Logger module - SEBackup Logging System

    # Script module associated with this manifest
    RootModule        = 'Logger.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = 'd9a5ac07-7e8a-4d8d-9334-08c7fce68c98'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'Structured, thread-safe logging module for the SEBackup Space Engineers Torch Server Backup & Restore System. Provides daily rotating log files, color-coded console output, contextual log prefixes, and log entry parsing.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Functions to export from this module
    FunctionsToExport = @(
        'Write-SEBLog'
        'Get-SEBLogPath'
        'Get-SEBLogEntries'
        'Start-SEBLogContext'
        'Stop-SEBLogContext'
        'Test-SEBSafeName'
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
            Tags       = @('Logging', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup Logger module.'
        }
    }
}
