@{
    # Module manifest for ConfigManager module - SEBackup Configuration System

    # Script module associated with this manifest
    RootModule        = 'ConfigManager.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = '9ae3569f-ef99-46c9-b057-a96abd8c46a5'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'TOML-based configuration management module for the SEBackup Space Engineers Torch Server Backup & Restore System. Handles global config, per-node configs, remote instance configs, config merging, and validation.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Modules that must be imported before this module
    RequiredModules   = @('PSToml')

    # Functions to export from this module
    FunctionsToExport = @(
        'Get-SEBGlobalConfig'
        'Get-SEBNodeConfig'
        'Get-SEBInstanceConfig'
        'Get-SEBAllInstanceConfigs'
        'Test-SEBConfig'
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
            Tags       = @('Configuration', 'TOML', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup ConfigManager module.'
        }
    }
}
