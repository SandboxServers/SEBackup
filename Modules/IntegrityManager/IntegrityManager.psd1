@{
    # Module manifest for IntegrityManager module - SEBackup Archive Integrity Verification

    # Script module associated with this manifest
    RootModule        = 'IntegrityManager.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = '7c9aedff-c135-4610-8315-d7e02b58ccf6'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'Archive integrity verification module for the SEBackup Space Engineers Torch Server Backup & Restore System. Provides three-level verification: quick archive CRC/hash checks, manifest cross-checks, and full chain reconstruction validation.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Modules that must be imported before this module
    RequiredModules   = @()

    # Functions to export from this module
    FunctionsToExport = @(
        'Test-SEBArchiveIntegrity'
        'Test-SEBManifestIntegrity'
        'Test-SEBChainIntegrity'
        'Get-SEBIntegrityReport'
        'Write-SEBIntegrityReport'
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
            Tags       = @('Integrity', 'Verification', 'Archive', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup IntegrityManager module.'
        }
    }
}
