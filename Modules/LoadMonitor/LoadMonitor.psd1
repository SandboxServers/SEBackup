@{
    # Module manifest for LoadMonitor module - SEBackup Node Load Monitoring

    # Script module associated with this manifest
    RootModule        = 'LoadMonitor.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = 'c1e83042-e02b-419e-bcd3-769078a54913'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'Node load monitoring module for the SEBackup Space Engineers Torch Server Backup & Restore System. Provides CPU, memory, and player-count load checks against configurable thresholds with defer/skip logic for backup scheduling.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Modules that must be imported before this module
    RequiredModules   = @()

    # Functions to export from this module
    FunctionsToExport = @(
        'Test-SEBNodeLoad'
        'Wait-SEBNodeLoad'
        'Get-SEBNodeMetrics'
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
            Tags       = @('LoadMonitoring', 'CPU', 'Memory', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup LoadMonitor module.'
        }
    }
}
