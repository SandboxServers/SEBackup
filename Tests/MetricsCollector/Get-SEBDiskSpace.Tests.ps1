#Requires -Module Pester

# Issue #19 -- unit coverage for Get-SEBDiskSpace's free-space accounting and the -1 sentinel that
# flags an unconfigured/unreachable tier.
#
# The function reports free/total bytes for three storage tiers (node staging, C&C backup root,
# NAS) and uses -1 to mean "not configured / not available". The ONLY external boundary mocked is
# the remote drive query (Invoke-SEBRemoteCommand -ModuleName MetricsCollector), stubbed to return
# canned drive data so no live node is required. The C&C backup-root tier is read from a real local
# drive (a temp path), so the free/total math is checked against a freshly-read DriveInfo for that
# same drive -- a true in/out assertion with no node.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # An uninitialized PSSession satisfies the [PSSession] cast on -Session; the remote call it
    # would drive is mocked, so it is never used to reach a node.
    $script:fakeSession = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
        [System.Management.Automation.Runspaces.PSSession])

    # A real local path whose drive DriveInfo can read directly (the C&C backup-root tier is local).
    $script:localPath = [System.IO.Path]::GetTempPath()
    $script:localRoot = [System.IO.Path]::GetPathRoot($script:localPath)
}

Describe 'Get-SEBDiskSpace' {

    Context 'C&C backup root (local drive, no node)' {
        It 'returns the actual free/total bytes for the backup-root drive' {
            $expected = [System.IO.DriveInfo]::new($script:localRoot)
            $r = Get-SEBDiskSpace -BackupRoot $script:localPath

            # Free space is volatile between the two reads; assert it is a sane positive figure and
            # within a wide tolerance of the reference read rather than exact equality.
            $r.CCBackupFreeBytes  | Should -BeGreaterThan 0
            $r.CCBackupTotalBytes | Should -Be $expected.TotalSize -Because 'total size is stable for a fixed drive'
            [math]::Abs($r.CCBackupFreeBytes - $expected.AvailableFreeSpace) |
                Should -BeLessThan 1GB -Because 'two reads moments apart should be close'
        }

        It 'reports free <= total for the backup-root drive (basic accounting invariant)' {
            $r = Get-SEBDiskSpace -BackupRoot $script:localPath
            $r.CCBackupFreeBytes | Should -BeLessOrEqual $r.CCBackupTotalBytes
        }
    }

    Context 'unconfigured tiers use the -1 sentinel' {
        It 'reports NAS as -1 when no NASPath is supplied' {
            $r = Get-SEBDiskSpace -BackupRoot $script:localPath
            $r.NASFreeBytes  | Should -Be -1
            $r.NASTotalBytes | Should -Be -1
        }

        It 'reports NAS as -1 for a whitespace-only NASPath' {
            $r = Get-SEBDiskSpace -BackupRoot $script:localPath -NASPath '   '
            $r.NASFreeBytes  | Should -Be -1
            $r.NASTotalBytes | Should -Be -1
        }

        It 'reports node staging as -1 when no Session is supplied' {
            $r = Get-SEBDiskSpace -BackupRoot $script:localPath
            $r.NodeStagingFreeBytes  | Should -Be -1
            $r.NodeStagingTotalBytes | Should -Be -1
        }
    }

    Context 'node staging via a (mocked) remote session' {
        It 'fills node staging from the canned remote drive query' {
            Mock Invoke-SEBRemoteCommand -ModuleName MetricsCollector {
                @{ FreeBytes = 50GB; TotalBytes = 200GB }
            }

            $r = Get-SEBDiskSpace -BackupRoot $script:localPath -Session $script:fakeSession

            $r.NodeStagingFreeBytes  | Should -Be 50GB
            $r.NodeStagingTotalBytes | Should -Be 200GB
            Should -Invoke Invoke-SEBRemoteCommand -ModuleName MetricsCollector -Times 1 -Exactly
        }

        It 'leaves node staging at -1 when the remote query throws' {
            Mock Invoke-SEBRemoteCommand -ModuleName MetricsCollector { throw 'node unreachable' }

            $r = Get-SEBDiskSpace -BackupRoot $script:localPath -Session $script:fakeSession -WarningAction SilentlyContinue

            $r.NodeStagingFreeBytes  | Should -Be -1
            $r.NodeStagingTotalBytes | Should -Be -1
            # The local C&C tier must still be populated -- a node failure does not poison it.
            $r.CCBackupTotalBytes | Should -BeGreaterThan 0
        }

        It 'coerces the remote drive figures to [long]' {
            Mock Invoke-SEBRemoteCommand -ModuleName MetricsCollector {
                @{ FreeBytes = 12345678901; TotalBytes = 98765432109 }
            }
            $r = Get-SEBDiskSpace -BackupRoot $script:localPath -Session $script:fakeSession
            $r.NodeStagingFreeBytes  | Should -BeOfType [long]
            $r.NodeStagingTotalBytes | Should -BeOfType [long]
            $r.NodeStagingFreeBytes  | Should -Be 12345678901
        }
    }

    Context 'NAS on a local/mapped (non-UNC) path' {
        It 'reads NAS free/total from a local-style path via DriveInfo' {
            # A drive-rooted (non-UNC) NASPath goes through the same local DriveInfo helper as the
            # backup root, so pointing it at the temp drive yields that drive's real figures.
            $r = Get-SEBDiskSpace -BackupRoot $script:localPath -NASPath $script:localPath
            $r.NASFreeBytes  | Should -BeGreaterThan 0
            $r.NASTotalBytes | Should -Be ([System.IO.DriveInfo]::new($script:localRoot).TotalSize)
        }
    }

    Context 'output shape' {
        It 'always returns all six tier properties typed as [long]' {
            $r = Get-SEBDiskSpace -BackupRoot $script:localPath
            foreach ($p in 'NodeStagingFreeBytes','NodeStagingTotalBytes','CCBackupFreeBytes','CCBackupTotalBytes','NASFreeBytes','NASTotalBytes') {
                $r.PSObject.Properties.Name | Should -Contain $p
                $r.$p | Should -BeOfType [long]
            }
        }
    }
}
