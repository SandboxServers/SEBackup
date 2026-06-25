@{
    # Module manifest for the SEBackup root module
    # Space Engineers Torch Server Backup & Restore System

    # Script module associated with this manifest
    RootModule        = 'SEBackup.psm1'

    # Version number of this module
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = 'fe59461d-e4f9-4bcd-922f-6bdd83852daf'

    # Author of this module
    Author            = 'SandboxServers'

    # Company or vendor of this module
    CompanyName       = 'SandboxServers'

    # Copyright statement for this module
    Copyright         = '(c) 2026 SandboxServers. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'Space Engineers Torch Server Backup & Restore System. Provides zero-downtime VSS-based backups with incremental chains, multi-node command-and-control orchestration, three-tier storage, Discord notifications, load-aware scheduling, and bandwidth throttling.'

    # Minimum version of PowerShell required by this module
    PowerShellVersion = '7.0'

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules   = @('PSToml')

    # Functions to export from this module - comprehensive list from all sub-modules
    FunctionsToExport = @(
        # Logger
        'Write-SEBLog'
        'Get-SEBLogPath'
        'Get-SEBLogEntries'
        'Start-SEBLogContext'
        'Stop-SEBLogContext'
        'Test-SEBSafeName'

        # ConfigManager
        'Get-SEBGlobalConfig'
        'Get-SEBNodeConfig'
        'Get-SEBInstanceConfig'
        'Get-SEBAllInstanceConfigs'
        'Test-SEBConfig'

        # CredentialManager
        'Save-SEBCredential'
        'Get-SEBCredential'
        'Remove-SEBCredential'
        'Test-SEBCredential'

        # RemoteManager
        'New-SEBSession'
        'Remove-SEBSession'
        'Test-SEBSessionExists'
        'Test-SEBConnection'
        'Invoke-SEBRemoteCommand'
        'Get-SEBSharePath'
        'Test-SEBShare'
        'Mount-SEBShare'

        # VRageAPI
        'Invoke-SEBVRageRequest'
        'Save-SEBVRageWorld'
        'Test-SEBVRageAPI'
        'Get-SEBServerInfo'

        # VSSManager
        'New-SEBShadowCopy'
        'Remove-SEBShadowCopy'
        'Mount-SEBShadowCopy'
        'Dismount-SEBShadowCopy'
        'Invoke-SEBWithShadowCopy'
        'Clear-SEBOrphanShadowCopies'

        # ManifestManager
        'New-SEBManifest'
        'Compare-SEBManifest'
        'Get-SEBManifestChain'
        'Read-SEBManifest'
        'Write-SEBManifest'
        'Get-SEBLatestManifest'

        # CompressionManager
        'Compress-SEBArchive'
        'Expand-SEBArchive'
        'Test-SEBArchive'
        'Get-SEBArchiveContents'
        'Get-SEBCompressionEngine'

        # IntegrityManager
        'Test-SEBArchiveIntegrity'
        'Test-SEBManifestIntegrity'
        'Test-SEBChainIntegrity'
        'Get-SEBIntegrityReport'
        'Write-SEBIntegrityReport'

        # LoadMonitor
        'Test-SEBNodeLoad'
        'Wait-SEBNodeLoad'
        'Get-SEBNodeMetrics'

        # NetworkThrottle
        'Copy-SEBThrottled'
        'Start-SEBBitsTransfer'
        'Get-SEBTransferStatus'
        'Stop-SEBTransfer'

        # NotificationManager
        'Send-SEBNotification'
        'Send-SEBBackupNotification'
        'Send-SEBRestoreNotification'
        'Test-SEBNotificationConfig'

        # MetricsCollector
        'Add-SEBMetric'
        'Get-SEBMetrics'
        'Get-SEBDiskSpace'
        'Get-SEBHealthSummary'
        'Clear-SEBOldMetrics'

        # BackupEngine
        'Invoke-SEBBackup'
        'Invoke-SEBBackupAll'
        'Get-SEBBackupHistory'
        'Remove-SEBExpiredBackups'
        'New-SEBLockFile'
        'Remove-SEBLockFile'

        # RestoreEngine
        'Invoke-SEBRestore'
        'Get-SEBRestorePoints'
        'Test-SEBRestoreChain'
        'Undo-SEBRestore'

        # SchedulerManager
        'Register-SEBScheduledTask'
        'Unregister-SEBScheduledTask'
        'Get-SEBScheduleStatus'
        'Update-SEBSchedule'
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
            # Tags applied to this module for discoverability in the PowerShell Gallery
            Tags       = @(
                'SpaceEngineers', 'Torch', 'Backup', 'Restore', 'VSS',
                'GameServer', 'Automation', 'WinRM', 'Discord', 'TOML'
            )

            # URI for the project site
            ProjectUri = 'https://github.com/SandboxServers/SEBackup'

            # URI for the license
            LicenseUri = 'https://github.com/SandboxServers/SEBackup/blob/main/LICENSE'

            # Release notes for this module
            ReleaseNotes = 'Initial release of the SEBackup Space Engineers Torch Server Backup & Restore System.'
        }
    }
}
