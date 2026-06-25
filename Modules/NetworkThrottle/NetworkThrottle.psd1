@{
    # Module manifest for NetworkThrottle module - SEBackup Network Throttling

    # Script module associated with this manifest
    RootModule        = 'NetworkThrottle.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = '4e26fdd4-26ff-492b-ae7f-822db5c8d063'

    # Author of this module
    Author            = 'SEBackup Project'

    # Company or vendor of this module
    CompanyName       = 'SEBackup'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SEBackup Project. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'Network throttling module for the SEBackup Space Engineers Torch Server Backup & Restore System. Provides bandwidth-limited file transfers via BITS, robocopy /IPG, or Copy-Item fallback.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Functions to export from this module
    FunctionsToExport = @(
        'Copy-SEBThrottled'
        'Start-SEBBitsTransfer'
        'Get-SEBTransferStatus'
        'Stop-SEBTransfer'
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
            Tags       = @('Network', 'Throttle', 'BITS', 'Robocopy', 'SEBackup', 'SpaceEngineers', 'Torch')

            # License URI for this module
            LicenseUri = ''

            # Project URI for this module
            ProjectUri = ''

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup NetworkThrottle module.'
        }
    }
}
