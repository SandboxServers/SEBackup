@{
    # Module manifest for VRageAPI module - SEBackup VRage Remote API Client

    # Script module associated with this manifest
    RootModule        = 'VRageAPI.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = 'c5f9a2d4-8e63-4f1c-b7a5-3d4c0e1f2a9b'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'VRage Remote API client module for the SEBackup Space Engineers Torch Server Backup & Restore System. Provides HMAC-SHA1 authenticated API calls for triggering world saves, querying server status, and testing API connectivity.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Functions to export from this module
    FunctionsToExport = @(
        'Invoke-SEBVRageRequest'
        'Save-SEBVRageWorld'
        'Test-SEBVRageAPI'
        'Get-SEBServerInfo'
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
            Tags       = @('VRage', 'API', 'SEBackup', 'SpaceEngineers', 'Torch', 'HMAC')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup VRageAPI module.'
        }
    }
}
