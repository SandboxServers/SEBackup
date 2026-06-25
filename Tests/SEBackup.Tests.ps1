#Requires -Module Pester
<#
.SYNOPSIS
    Root-level Pester tests for the SEBackup module.

.DESCRIPTION
    Tests module import, function existence, and core logic that does not
    require remote connections or Windows-specific services.

    Data-driven cases use Pester 5's -ForEach so the per-item value is bound into
    the run-phase scope as $_. The previous `foreach ($x) { It "...$x" {...$x...} }`
    pattern registered the It blocks at discovery but left $x $null at run time
    (discovery and run are separate scopes), so every generated test asserted
    against a null path/name and failed.

.EXAMPLE
    Invoke-Pester -Path Tests/SEBackup.Tests.ps1 -Output Detailed
#>

BeforeAll {
    # Resolve project root (one level up from Tests/). Available to run-phase It bodies.
    $ProjectRoot = Split-Path -Parent $PSScriptRoot

    # Import individual sub-modules directly for testing.
    # We import sub-modules rather than the root module to avoid
    # dependency issues on non-Windows platforms or missing modules.
    $ModulesPath = Join-Path $ProjectRoot 'Modules'
}

Describe 'SEBackup Root Module' {
    Context 'Module file structure' {
        It 'SEBackup.psm1 exists' {
            $psm1Path = Join-Path $ProjectRoot 'SEBackup.psm1'
            Test-Path $psm1Path | Should -BeTrue
        }

        It 'SEBackup.psd1 exists' {
            $psd1Path = Join-Path $ProjectRoot 'SEBackup.psd1'
            Test-Path $psd1Path | Should -BeTrue
        }

        It 'SEBackup.psd1 is a valid module manifest' {
            $psd1Path = Join-Path $ProjectRoot 'SEBackup.psd1'
            $manifest = Test-ModuleManifest -Path $psd1Path -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            $manifest | Should -Not -BeNullOrEmpty
            $manifest.Name | Should -Be 'SEBackup'
        }

        It 'SEBackup.psd1 specifies PowerShell 7.0' {
            $psd1Path = Join-Path $ProjectRoot 'SEBackup.psd1'
            $manifest = Test-ModuleManifest -Path $psd1Path -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            $manifest.PowerShellVersion | Should -Be '7.0'
        }
    }

    Context 'All expected sub-module directories exist' {
        It 'Module directory exists: <_>' -ForEach @(
            'Logger', 'ConfigManager', 'CredentialManager', 'RemoteManager',
            'VRageAPI', 'VSSManager', 'ManifestManager', 'CompressionManager',
            'IntegrityManager', 'LoadMonitor', 'NetworkThrottle', 'NotificationManager',
            'MetricsCollector', 'BackupEngine', 'RestoreEngine', 'SchedulerManager'
        ) {
            $modDir = Join-Path $ModulesPath $_
            Test-Path $modDir -PathType Container | Should -BeTrue
        }
    }

    Context 'All expected sub-module psm1 files exist' {
        It 'Module file exists: <_>.psm1' -ForEach @(
            'Logger', 'ConfigManager', 'CredentialManager', 'RemoteManager',
            'VRageAPI', 'VSSManager', 'ManifestManager', 'CompressionManager',
            'IntegrityManager', 'LoadMonitor', 'NetworkThrottle', 'NotificationManager',
            'BackupEngine', 'SchedulerManager'
        ) {
            $modPath = Join-Path $ModulesPath "$_\$_.psm1"
            Test-Path $modPath -PathType Leaf | Should -BeTrue
        }
    }
}

Describe 'Logger Module' {
    BeforeAll {
        $loggerPath = Join-Path $ModulesPath 'Logger\Logger.psm1'
        if (Test-Path $loggerPath) {
            Import-Module $loggerPath -Force -DisableNameChecking
        }
    }

    Context 'Exported functions exist' {
        It 'Function exists: <_>' -ForEach @(
            'Write-SEBLog', 'Get-SEBLogPath', 'Get-SEBLogEntries',
            'Start-SEBLogContext', 'Stop-SEBLogContext'
        ) {
            Get-Command -Name $_ -Module Logger -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'Get-SEBLogPath returns a valid path' {
        It 'Returns a string ending in .log' {
            $path = Get-SEBLogPath
            $path | Should -Not -BeNullOrEmpty
            $path | Should -Match '\.log$'
        }

        It 'Includes today''s date in the filename' {
            $path = Get-SEBLogPath
            $today = (Get-Date).ToString('yyyy-MM-dd')
            $path | Should -Match $today
        }

        It 'Returns just the directory with -DirectoryOnly' {
            $dir = Get-SEBLogPath -DirectoryOnly
            $dir | Should -Not -Match '\.log$'
        }
    }

    Context 'Write-SEBLog writes to a file' {
        BeforeAll {
            # Use a temporary directory for test logging
            $testLogDir = Join-Path ([System.IO.Path]::GetTempPath()) "SEBackupTest_$(Get-Random)"
            New-Item -Path $testLogDir -ItemType Directory -Force | Out-Null

            # Override the log root in the module scope
            & (Get-Module Logger) { $script:SEBLogRoot = $args[0] } $testLogDir
        }

        AfterAll {
            # Clean up
            if (Test-Path $testLogDir) {
                Remove-Item $testLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Creates a log file and writes to it' {
            Write-SEBLog -Message "Test log entry from Pester" -Level INFO -NoConsole
            $logPath = Get-SEBLogPath
            Test-Path $logPath | Should -BeTrue
        }

        It 'Log file contains the message' {
            Write-SEBLog -Message "UniqueTestMarker12345" -Level WARN -NoConsole
            $logPath = Get-SEBLogPath
            $content = Get-Content $logPath -Raw
            $content | Should -Match 'UniqueTestMarker12345'
        }

        It 'Log entry includes the level' {
            Write-SEBLog -Message "LevelCheckMessage" -Level ERROR -NoConsole
            $logPath = Get-SEBLogPath
            $content = Get-Content $logPath -Raw
            $content | Should -Match '\[ERROR\]'
        }

        It 'Accepts context parameter' {
            Write-SEBLog -Message "ContextMessage" -Level INFO -Context "TestCtx" -NoConsole
            $logPath = Get-SEBLogPath
            $content = Get-Content $logPath -Raw
            $content | Should -Match '\[TestCtx\]'
        }
    }
}

Describe 'ConfigManager Module' {
    # -Skip on the Contexts below is evaluated at DISCOVERY, so the availability flag
    # must be computed in BeforeDiscovery (a BeforeAll value would still be $null at
    # discovery and the contexts would always skip).
    BeforeDiscovery {
        $psTomlAvailable = $null -ne (Get-Module -Name PSToml -ListAvailable -ErrorAction SilentlyContinue)
    }

    Context 'Module functions exist' -Skip:(-not $psTomlAvailable) {
        BeforeAll {
            $configMgrPath = Join-Path $ModulesPath 'ConfigManager\ConfigManager.psm1'
            if (Test-Path $configMgrPath) {
                Import-Module $configMgrPath -Force -DisableNameChecking
            }
        }

        It 'Function exists: <_>' -ForEach @(
            'Get-SEBGlobalConfig', 'Get-SEBNodeConfig', 'Get-SEBInstanceConfig',
            'Get-SEBAllInstanceConfigs', 'Test-SEBConfig'
        ) {
            Get-Command -Name $_ -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'Global config loading' -Skip:(-not $psTomlAvailable) {
        It 'Get-SEBGlobalConfig returns a hashtable with expected sections' {
            $config = Get-SEBGlobalConfig -Force
            $config | Should -Not -BeNullOrEmpty
            $config | Should -BeOfType [hashtable]
            $config.Keys | Should -Contain 'storage'
            $config.Keys | Should -Contain 'schedule'
            $config.Keys | Should -Contain 'compression'
            $config.Keys | Should -Contain 'network'
            $config.Keys | Should -Contain 'notifications'
        }

        It 'Storage section has expected keys' {
            $config = Get-SEBGlobalConfig -Force
            $config.storage.Keys | Should -Contain 'cc_backup_root'
        }

        It 'Schedule section has expected keys' {
            $config = Get-SEBGlobalConfig -Force
            $config.schedule.Keys | Should -Contain 'enabled'
            $config.schedule.Keys | Should -Contain 'interval_hours'
        }
    }
}

Describe 'ManifestManager Module' {
    BeforeAll {
        $manifestMgrPath = Join-Path $ModulesPath 'ManifestManager\ManifestManager.psm1'
        if (Test-Path $manifestMgrPath) {
            Import-Module $manifestMgrPath -Force -DisableNameChecking
        }
    }

    Context 'Exported functions exist' {
        It 'Function exists: <_>' -ForEach @(
            'New-SEBManifest', 'Compare-SEBManifest', 'Get-SEBManifestChain',
            'Read-SEBManifest', 'Write-SEBManifest', 'Get-SEBLatestManifest'
        ) {
            Get-Command -Name $_ -Module ManifestManager -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'Compare-SEBManifest logic' {
        It 'Detects added files' {
            $previous = @{
                files = @{
                    'file1.txt' = @{ sha256 = 'aaa' }
                }
            }
            $current = @{
                files = @{
                    'file1.txt' = @{ sha256 = 'aaa' }
                    'file2.txt' = @{ sha256 = 'bbb' }
                }
            }

            $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous
            $diff.AddedCount | Should -Be 1
            $diff.Added | Should -Contain 'file2.txt'
            $diff.ModifiedCount | Should -Be 0
            $diff.DeletedCount | Should -Be 0
            $diff.UnchangedCount | Should -Be 1
        }

        It 'Detects modified files' {
            $previous = @{
                files = @{
                    'file1.txt' = @{ sha256 = 'aaa' }
                }
            }
            $current = @{
                files = @{
                    'file1.txt' = @{ sha256 = 'bbb' }
                }
            }

            $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous
            $diff.ModifiedCount | Should -Be 1
            $diff.Modified | Should -Contain 'file1.txt'
            $diff.AddedCount | Should -Be 0
            $diff.DeletedCount | Should -Be 0
        }

        It 'Detects deleted files' {
            $previous = @{
                files = @{
                    'file1.txt' = @{ sha256 = 'aaa' }
                    'file2.txt' = @{ sha256 = 'bbb' }
                }
            }
            $current = @{
                files = @{
                    'file1.txt' = @{ sha256 = 'aaa' }
                }
            }

            $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous
            $diff.DeletedCount | Should -Be 1
            $diff.Deleted | Should -Contain 'file2.txt'
            $diff.AddedCount | Should -Be 0
            $diff.UnchangedCount | Should -Be 1
        }

        It 'Detects unchanged files' {
            $previous = @{
                files = @{
                    'file1.txt' = @{ sha256 = 'aaa' }
                    'file2.txt' = @{ sha256 = 'bbb' }
                }
            }
            $current = @{
                files = @{
                    'file1.txt' = @{ sha256 = 'aaa' }
                    'file2.txt' = @{ sha256 = 'bbb' }
                }
            }

            $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous
            $diff.UnchangedCount | Should -Be 2
            $diff.TotalChanges | Should -Be 0
        }

        It 'Handles empty previous manifest (all files are new)' {
            $previous = @{ files = @{} }
            $current = @{
                files = @{
                    'file1.txt' = @{ sha256 = 'aaa' }
                    'file2.txt' = @{ sha256 = 'bbb' }
                    'file3.txt' = @{ sha256 = 'ccc' }
                }
            }

            $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous
            $diff.AddedCount | Should -Be 3
            $diff.TotalChanges | Should -Be 3
        }

        It 'Handles empty current manifest (all files deleted)' {
            $previous = @{
                files = @{
                    'file1.txt' = @{ sha256 = 'aaa' }
                    'file2.txt' = @{ sha256 = 'bbb' }
                }
            }
            $current = @{ files = @{} }

            $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous
            $diff.DeletedCount | Should -Be 2
            $diff.TotalChanges | Should -Be 2
        }

        It 'Handles mixed changes (add + modify + delete + unchanged)' {
            $previous = @{
                files = @{
                    'unchanged.txt' = @{ sha256 = 'aaa' }
                    'modified.txt'  = @{ sha256 = 'bbb' }
                    'deleted.txt'   = @{ sha256 = 'ccc' }
                }
            }
            $current = @{
                files = @{
                    'unchanged.txt' = @{ sha256 = 'aaa' }
                    'modified.txt'  = @{ sha256 = 'ddd' }
                    'added.txt'     = @{ sha256 = 'eee' }
                }
            }

            $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous
            $diff.AddedCount | Should -Be 1
            $diff.ModifiedCount | Should -Be 1
            $diff.DeletedCount | Should -Be 1
            $diff.UnchangedCount | Should -Be 1
            $diff.TotalChanges | Should -Be 3
        }

        It 'Handles manifests without a files key' {
            $previous = @{}
            $current = @{
                files = @{
                    'file1.txt' = @{ sha256 = 'aaa' }
                }
            }

            $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous
            $diff.AddedCount | Should -Be 1
        }
    }
}

Describe 'VRageAPI Module' {
    BeforeAll {
        $vrageApiPath = Join-Path $ModulesPath 'VRageAPI\VRageAPI.psm1'
        if (Test-Path $vrageApiPath) {
            Import-Module $vrageApiPath -Force -DisableNameChecking
        }
    }

    Context 'Exported functions exist' {
        It 'Function exists: <_>' -ForEach @(
            'Invoke-SEBVRageRequest', 'Save-SEBVRageWorld',
            'Test-SEBVRageAPI', 'Get-SEBServerInfo'
        ) {
            Get-Command -Name $_ -Module VRageAPI -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'Auth header generation (internal function via module scope)' {
        It 'Generates valid auth headers with required keys' {
            # Access the private function through the module scope
            $headers = & (Get-Module VRageAPI) {
                New-SEBVRageAuthHeaders -SecurityKey 'YWJjZGVmZ2g=' -RequestUri '/vrageremote/v1/server'
            }

            $headers | Should -Not -BeNullOrEmpty
            $headers | Should -BeOfType [hashtable]
            $headers.Keys | Should -Contain 'Date'
            $headers.Keys | Should -Contain 'Authorization'
            $headers.Keys | Should -Contain 'Nonce'
        }

        It 'Date header is in RFC1123 format' {
            $headers = & (Get-Module VRageAPI) {
                New-SEBVRageAuthHeaders -SecurityKey 'YWJjZGVmZ2g=' -RequestUri '/vrageremote/v1/server'
            }

            # RFC1123 format: "Thu, 27 Feb 2026 12:00:00 GMT"
            $headers.Date | Should -Match '^\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT$'
        }

        It 'Authorization header contains nonce and base64 signature separated by colon' {
            $headers = & (Get-Module VRageAPI) {
                New-SEBVRageAuthHeaders -SecurityKey 'YWJjZGVmZ2g=' -RequestUri '/vrageremote/v1/server'
            }

            $headers.Authorization | Should -Match '^[a-f0-9]+:.+$'
        }

        It 'Nonce is a 32-character hex string' {
            $headers = & (Get-Module VRageAPI) {
                New-SEBVRageAuthHeaders -SecurityKey 'YWJjZGVmZ2g=' -RequestUri '/vrageremote/v1/server'
            }

            $headers.Nonce | Should -Match '^[a-f0-9]{32}$'
        }

        It 'Generates different nonces for different calls' {
            $headers1 = & (Get-Module VRageAPI) {
                New-SEBVRageAuthHeaders -SecurityKey 'YWJjZGVmZ2g=' -RequestUri '/vrageremote/v1/server'
            }
            $headers2 = & (Get-Module VRageAPI) {
                New-SEBVRageAuthHeaders -SecurityKey 'YWJjZGVmZ2g=' -RequestUri '/vrageremote/v1/server'
            }

            $headers1.Nonce | Should -Not -Be $headers2.Nonce
        }

        It 'Nonce in Authorization header matches the Nonce key' {
            $headers = & (Get-Module VRageAPI) {
                New-SEBVRageAuthHeaders -SecurityKey 'YWJjZGVmZ2g=' -RequestUri '/vrageremote/v1/server'
            }

            $authNonce = ($headers.Authorization -split ':')[0]
            $authNonce | Should -Be $headers.Nonce
        }
    }
}

Describe 'CompressionManager Module' {
    BeforeAll {
        $compressionPath = Join-Path $ModulesPath 'CompressionManager\CompressionManager.psm1'
        if (Test-Path $compressionPath) {
            Import-Module $compressionPath -Force -DisableNameChecking
        }
    }

    Context 'Exported functions exist' {
        It 'Function exists: <_>' -ForEach @(
            'Compress-SEBArchive', 'Expand-SEBArchive', 'Test-SEBArchive',
            'Get-SEBArchiveContents', 'Get-SEBCompressionEngine'
        ) {
            Get-Command -Name $_ -Module CompressionManager -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'IntegrityManager Module' {
    BeforeAll {
        $integrityPath = Join-Path $ModulesPath 'IntegrityManager\IntegrityManager.psm1'
        if (Test-Path $integrityPath) {
            Import-Module $integrityPath -Force -DisableNameChecking
        }
    }

    Context 'Exported functions exist' {
        It 'Function exists: <_>' -ForEach @(
            'Test-SEBArchiveIntegrity', 'Test-SEBManifestIntegrity',
            'Test-SEBChainIntegrity', 'Get-SEBIntegrityReport',
            'Write-SEBIntegrityReport'
        ) {
            Get-Command -Name $_ -Module IntegrityManager -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'RemoteManager Module' {
    BeforeAll {
        $remotePath = Join-Path $ModulesPath 'RemoteManager\RemoteManager.psm1'
        if (Test-Path $remotePath) {
            # RemoteManager requires CredentialManager
            $credPath = Join-Path $ModulesPath 'CredentialManager\CredentialManager.psm1'
            if (Test-Path $credPath) {
                Import-Module $credPath -Force -DisableNameChecking
            }
            Import-Module $remotePath -Force -DisableNameChecking
        }
    }

    Context 'Exported functions exist' {
        It 'Function exists: <_>' -ForEach @(
            'New-SEBSession', 'Remove-SEBSession', 'Test-SEBConnection',
            'Invoke-SEBRemoteCommand', 'Get-SEBSharePath', 'Test-SEBShare',
            'Mount-SEBShare'
        ) {
            Get-Command -Name $_ -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'CredentialManager Module' {
    BeforeAll {
        $credPath = Join-Path $ModulesPath 'CredentialManager\CredentialManager.psm1'
        if (Test-Path $credPath) {
            Import-Module $credPath -Force -DisableNameChecking
        }
    }

    Context 'Exported functions exist' {
        It 'Function exists: <_>' -ForEach @(
            'Save-SEBCredential', 'Get-SEBCredential',
            'Remove-SEBCredential', 'Test-SEBCredential'
        ) {
            Get-Command -Name $_ -Module CredentialManager -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'VSSManager Module' {
    BeforeAll {
        $vssPath = Join-Path $ModulesPath 'VSSManager\VSSManager.psm1'
        if (Test-Path $vssPath) {
            Import-Module $vssPath -Force -DisableNameChecking
        }
    }

    Context 'Exported functions exist' {
        It 'Function exists: <_>' -ForEach @(
            'New-SEBShadowCopy', 'Remove-SEBShadowCopy',
            'Mount-SEBShadowCopy', 'Dismount-SEBShadowCopy',
            'Invoke-SEBWithShadowCopy', 'Clear-SEBOrphanShadowCopies'
        ) {
            Get-Command -Name $_ -Module VSSManager -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'NetworkThrottle Module' {
    BeforeAll {
        $throttlePath = Join-Path $ModulesPath 'NetworkThrottle\NetworkThrottle.psm1'
        if (Test-Path $throttlePath) {
            Import-Module $throttlePath -Force -DisableNameChecking
        }
    }

    Context 'Exported functions exist' {
        It 'Function exists: <_>' -ForEach @(
            'Copy-SEBThrottled', 'Start-SEBBitsTransfer',
            'Get-SEBTransferStatus', 'Stop-SEBTransfer'
        ) {
            Get-Command -Name $_ -Module NetworkThrottle -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'BackupEngine Module' {
    BeforeAll {
        $backupPath = Join-Path $ModulesPath 'BackupEngine\BackupEngine.psm1'
        if (Test-Path $backupPath) {
            Import-Module $backupPath -Force -DisableNameChecking
        }
    }

    Context 'Exported functions exist' {
        It 'Function exists: <_>' -ForEach @(
            'Invoke-SEBBackup', 'Invoke-SEBBackupAll',
            'Get-SEBBackupHistory', 'Remove-SEBExpiredBackups'
        ) {
            Get-Command -Name $_ -Module BackupEngine -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'SchedulerManager Module' {
    BeforeAll {
        $schedulerPath = Join-Path $ModulesPath 'SchedulerManager\SchedulerManager.psm1'
        if (Test-Path $schedulerPath) {
            Import-Module $schedulerPath -Force -DisableNameChecking
        }
    }

    Context 'Exported functions exist' {
        It 'Function exists: <_>' -ForEach @(
            'Register-SEBScheduledTask', 'Unregister-SEBScheduledTask',
            'Get-SEBScheduleStatus', 'Update-SEBSchedule'
        ) {
            Get-Command -Name $_ -Module SchedulerManager -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }
}
