@{
    # Module manifest for RemoteManager module - SEBackup Remote Session Management

    # Script module associated with this manifest
    RootModule        = 'RemoteManager.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = 'c5f9a2b4-8e63-4f1c-d7a5-3b4c0e9f2a1d'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'Remote session management module for the SEBackup Space Engineers Torch Server Backup & Restore System. Provides PSSession lifecycle management, WinRM connectivity testing, remote command execution with retry logic, and SMB share operations.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules   = @(
        @{ ModuleName = 'CredentialManager'; ModuleVersion = '1.0.0' }
    )

    # Functions to export from this module
    FunctionsToExport = @(
        'New-SEBSession'
        'Remove-SEBSession'
        'Test-SEBSessionExists'
        'Test-SEBConnection'
        'Invoke-SEBRemoteCommand'
        'Get-SEBSharePath'
        'Test-SEBShare'
        'Mount-SEBShare'
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
            Tags       = @('Remote', 'PSSession', 'WinRM', 'SMB', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup RemoteManager module.'
        }
    }
}
