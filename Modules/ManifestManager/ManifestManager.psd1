@{
    # Module manifest for ManifestManager module - SEBackup Manifest System

    # Script module associated with this manifest
    RootModule        = 'ManifestManager.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = '7a9175ee-77e0-44ef-a703-698e0436bd22'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'SHA256 manifest generation, diff comparison, and incremental backup chain management for the SEBackup Space Engineers Torch Server Backup & Restore System.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Modules that must be imported before this module
    RequiredModules   = @()

    # Functions to export from this module
    FunctionsToExport = @(
        'New-SEBManifest'
        'Compare-SEBManifest'
        'Get-SEBManifestChain'
        'Read-SEBManifest'
        'Write-SEBManifest'
        'Get-SEBLatestManifest'
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
            Tags       = @('Manifest', 'SHA256', 'Incremental', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup ManifestManager module.'
        }
    }
}
