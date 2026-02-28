# SEBackup Root Module
# Space Engineers Torch Server Backup & Restore System
#
# This root module imports all sub-modules that make up the SEBackup system.
# Each sub-module follows the one-function-per-file pattern with Public/ and
# Private/ subdirectories.

$ModuleRoot = $PSScriptRoot

$Modules = @(
    'Logger', 'ConfigManager', 'CredentialManager', 'RemoteManager',
    'VRageAPI', 'VSSManager', 'ManifestManager', 'CompressionManager',
    'IntegrityManager', 'LoadMonitor', 'NetworkThrottle', 'NotificationManager',
    'MetricsCollector', 'BackupEngine', 'RestoreEngine', 'SchedulerManager'
)

foreach ($mod in $Modules) {
    $modPath = Join-Path $ModuleRoot "Modules\$mod\$mod.psm1"
    if (Test-Path $modPath) {
        Import-Module $modPath -Force -DisableNameChecking
    } else {
        Write-Warning "SEBackup: Module not found: $mod ($modPath)"
    }
}
