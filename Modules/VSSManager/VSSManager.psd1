@{
    # Module manifest for VSSManager module - SEBackup VSS Shadow Copy Management

    # Script module associated with this manifest
    RootModule        = 'VSSManager.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = 'd6a0b3e5-9f74-4a2d-c8b6-4e5d1f2a3b0c'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'VSS shadow copy lifecycle management module for the SEBackup Space Engineers Torch Server Backup & Restore System. Provides creation, mounting, dismounting, and cleanup of Volume Shadow Copy snapshots on remote Windows nodes for consistent file-level backups.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Functions to export from this module
    FunctionsToExport = @(
        'New-SEBShadowCopy'
        'Remove-SEBShadowCopy'
        'Mount-SEBShadowCopy'
        'Dismount-SEBShadowCopy'
        'Invoke-SEBWithShadowCopy'
        'Clear-SEBOrphanShadowCopies'
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
            Tags       = @('VSS', 'ShadowCopy', 'Snapshot', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup VSSManager module.'
        }
    }
}
