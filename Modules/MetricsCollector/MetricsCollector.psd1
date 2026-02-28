@{
    # Module manifest for MetricsCollector module - SEBackup Metrics & Health

    # Script module associated with this manifest
    RootModule        = 'MetricsCollector.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = 'd6ea04f3-9c75-4b8d-b034-5f7c8d9ea112'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'Metrics collection and health monitoring module for the SEBackup Space Engineers Torch Server Backup & Restore System. Tracks backup trends, disk space usage, and computes health summaries for GUI display.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Functions to export from this module
    FunctionsToExport = @(
        'Add-SEBMetric'
        'Get-SEBMetrics'
        'Get-SEBDiskSpace'
        'Get-SEBHealthSummary'
        'Clear-SEBOldMetrics'
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
            Tags       = @('Metrics', 'Health', 'DiskSpace', 'Trends', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup MetricsCollector module.'
        }
    }
}
