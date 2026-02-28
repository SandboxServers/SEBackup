@{
    # Module manifest for CompressionManager module - SEBackup Compression System

    # Script module associated with this manifest
    RootModule        = 'CompressionManager.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = 'c5d8e3f2-1a67-4c9b-d2e7-9f5a8b3c6d1e'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = '7-Zip and .NET compression abstraction module for the SEBackup Space Engineers Torch Server Backup & Restore System. Handles archive creation, extraction, integrity testing, and content listing.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Modules that must be imported before this module
    RequiredModules   = @()

    # Functions to export from this module
    FunctionsToExport = @(
        'Compress-SEBArchive'
        'Expand-SEBArchive'
        'Test-SEBArchive'
        'Get-SEBArchiveContents'
        'Get-SEBCompressionEngine'
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
            Tags       = @('Compression', '7Zip', 'Archive', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup CompressionManager module.'
        }
    }
}
