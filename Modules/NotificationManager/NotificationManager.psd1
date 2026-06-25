@{
    # Module manifest for NotificationManager module - SEBackup Notifications

    # Script module associated with this manifest
    RootModule        = 'NotificationManager.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = '5b926fdc-8332-4b8f-bef1-1f0c2c0ffe6e'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'Discord webhook notification module for the SEBackup Space Engineers Torch Server Backup & Restore System. Sends color-coded embed notifications for backup success, failure, warning, and restore events.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Functions to export from this module
    FunctionsToExport = @(
        'Send-SEBNotification'
        'Send-SEBBackupNotification'
        'Send-SEBRestoreNotification'
        'Test-SEBNotificationConfig'
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
            Tags       = @('Notification', 'Discord', 'Webhook', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup NotificationManager module.'
        }
    }
}
