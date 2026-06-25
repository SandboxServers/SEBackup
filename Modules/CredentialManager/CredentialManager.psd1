@{
    # Module manifest for CredentialManager module - SEBackup Credential Storage

    # Script module associated with this manifest
    RootModule        = 'CredentialManager.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = '71eb88a6-1370-40e2-b8b0-b573c8814bbc'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'DPAPI-encrypted credential storage module for the SEBackup Space Engineers Torch Server Backup & Restore System. Provides secure save, retrieve, test, and remove operations for per-node PSCredential objects.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Functions to export from this module
    FunctionsToExport = @(
        'Save-SEBCredential'
        'Get-SEBCredential'
        'Remove-SEBCredential'
        'Test-SEBCredential'
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
            Tags       = @('Credentials', 'SEBackup', 'SpaceEngineers', 'Torch', 'DPAPI')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup CredentialManager module.'
        }
    }
}
