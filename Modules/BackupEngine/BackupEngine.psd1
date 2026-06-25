@{
    # Module manifest for BackupEngine module - SEBackup Backup Orchestration

    # Script module associated with this manifest
    RootModule        = 'BackupEngine.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = 'dffb1d4e-9d44-46b3-9796-bc5a0ece1eca'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'Full and incremental backup orchestration module for the SEBackup Space Engineers Torch Server Backup & Restore System. Coordinates VSS snapshots, manifest generation, archive compression, multi-tier distribution, integrity verification, and retention cleanup.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Functions to export from this module
    FunctionsToExport = @(
        'Invoke-SEBBackup'
        'Invoke-SEBBackupAll'
        'Get-SEBBackupHistory'
        'Remove-SEBExpiredBackups'
        'New-SEBLockFile'
        'Remove-SEBLockFile'
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
            Tags       = @('Backup', 'Orchestration', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup BackupEngine module.'
        }
    }
}
