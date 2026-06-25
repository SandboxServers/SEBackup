@{
    # Module manifest for RestoreEngine module - SEBackup Restore Reconstruction

    # Script module associated with this manifest
    RootModule        = 'RestoreEngine.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = '1b714cc8-b188-42a3-bd99-d61cd2e5bc61'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'Point-in-time restore reconstruction module for the SEBackup Space Engineers Torch Server Backup & Restore System. Reconstructs world state from full + incremental backup chains, handles safety backups, and provides atomic deployment with undo capability.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Functions to export from this module
    FunctionsToExport = @(
        'Invoke-SEBRestore'
        'Get-SEBRestorePoints'
        'Test-SEBRestoreChain'
        'Undo-SEBRestore'
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
            Tags       = @('Restore', 'Recovery', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup RestoreEngine module.'
        }
    }
}
