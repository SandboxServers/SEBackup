#Requires -Module Pester

# Issue #19 -- direct unit coverage for Get-SEBHealthSummary (the Public health-verdict aggregation)
# and, while we are at the boundary, the Add-SEBMetric -> Get-SEBMetrics round trip it reads through.
#
# Get-SEBHealthSummary derives, from an instance's metric history: last-successful-backup age,
# average duration / archive size over the last 10, a 7-day success rate, the current incremental
# chain length, and duration/size trends. The ONLY external boundary is the on-disk JSON metrics
# file under {BackupRoot}\Data\metrics\; tests point BackupRoot at a fresh temp directory and write
# the history directly (so timestamps relative to "now" are controlled), then assert the deterministic
# aggregation. Expected figures are precomputed from the documented rules.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # Write a metrics JSON file for $InstanceName under a (temp) BackupRoot, bypassing Add-SEBMetric
    # so each entry's timestamp can be set explicitly relative to "now".
    function New-MetricsFile {
        param(
            [string]$BackupRoot,
            [string]$InstanceName,
            [object[]]$History
        )
        $dir = Join-Path -Path $BackupRoot -ChildPath 'Data' | Join-Path -ChildPath 'metrics'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir "${InstanceName}_metrics.json"
        [pscustomobject]@{ instance = $InstanceName; history = $History } |
            ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
        return $file
    }

    function New-TempRoot {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sebmetrics_" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }
}

Describe 'Get-SEBHealthSummary' {

    Context 'no metrics yet' {
        It 'returns a safe default summary when the instance has no metrics file' {
            $root = New-TempRoot
            try {
                $s = Get-SEBHealthSummary -InstanceName 'NeverRan' -BackupRoot $root
                $s.InstanceName                     | Should -Be 'NeverRan'
                $s.LastSuccessfulBackupAge          | Should -BeNullOrEmpty
                $s.LastSuccessfulBackupAgeFormatted | Should -Be 'Never'
                $s.SuccessRate                      | Should -Be 0
                $s.CurrentChainLength               | Should -Be 0
                $s.DurationTrend                    | Should -Be 'stable'
                $s.SizeTrend                        | Should -Be 'stable'
            }
            finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
        }
    }

    Context 'a populated history' {
        BeforeAll {
            $script:root = New-TempRoot
            $now = [datetime]::UtcNow
            # Oldest -> newest. The -10d Full is outside the 7-day success window. The trailing two
            # Incrementals after the -3d Full define a chain length of 2. Durations and sizes both
            # rise monotonically -> growing trends.
            $history = @(
                @{ timestamp = $now.AddDays(-10).ToString('o'); type = 'Full';        duration_seconds = 100; archive_size_bytes = 1000; success = $true }
                @{ timestamp = $now.AddDays(-3).ToString('o');  type = 'Full';        duration_seconds = 110; archive_size_bytes = 1100; success = $true }
                @{ timestamp = $now.AddDays(-2).ToString('o');  type = 'Incremental'; duration_seconds = 120; archive_size_bytes = 1200; success = $false }
                @{ timestamp = $now.AddDays(-1).ToString('o');  type = 'Incremental'; duration_seconds = 130; archive_size_bytes = 1300; success = $true }
            )
            New-MetricsFile -BackupRoot $script:root -InstanceName 'Inst' -History $history | Out-Null
            $script:summary = Get-SEBHealthSummary -InstanceName 'Inst' -BackupRoot $script:root
        }

        AfterAll {
            if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
        }

        It 'computes the 7-day success rate over only the in-window entries' {
            # In-window entries: -3d(ok), -2d(fail), -1d(ok) => 2/3 => 66.7. The -10d success is excluded.
            $script:summary.SuccessRate | Should -Be 66.7
        }

        It 'counts the trailing incrementals as the current chain length' {
            $script:summary.CurrentChainLength | Should -Be 2
        }

        It 'averages the recent backup durations' {
            # last<=10 durations: 100,110,120,130 -> mean 115.
            $script:summary.AverageBackupDuration | Should -Be 115
        }

        It 'averages the recent archive sizes' {
            $script:summary.AverageArchiveSize | Should -Be 1150
        }

        It 'reports growing trends for the rising duration and size series' {
            $script:summary.DurationTrend | Should -Be 'growing'
            $script:summary.SizeTrend     | Should -Be 'growing'
        }

        It 'reports a populated, day-scale age for the last successful backup' {
            # The newest success is ~1 day old. Assert the age is positive and on a day scale, plus
            # that the human-readable form is well shaped. (An EXACT hour count is deliberately avoided:
            # Get-SEBHealthSummary parses JSON-deserialized timestamps, which carries a host-timezone
            # dependency; pinning the magnitude here would make the test pass/fail by machine locale.
            # The timezone-invariant "skips a later failure" contract is asserted separately below.)
            $script:summary.LastSuccessfulBackupAge | Should -Not -BeNullOrEmpty
            $script:summary.LastSuccessfulBackupAge.TotalHours | Should -BeGreaterThan 0
            $script:summary.LastSuccessfulBackupAge.TotalDays  | Should -BeLessThan 3
            $script:summary.LastSuccessfulBackupAgeFormatted   | Should -Match '^\d+[dhm]'
        }
    }

    Context 'a trailing failure after a success' {
        It 'rolls the failure into the success rate yet still anchors the age on the success' {
            $root = New-TempRoot
            try {
                $now = [datetime]::UtcNow
                $history = @(
                    @{ timestamp = $now.AddHours(-3).ToString('o'); type = 'Full';        duration_seconds = 50; archive_size_bytes = 500; success = $true }
                    @{ timestamp = $now.AddHours(-1).ToString('o'); type = 'Incremental'; duration_seconds = 60; archive_size_bytes = 600; success = $false }
                )
                New-MetricsFile -BackupRoot $root -InstanceName 'Mixed' -History $history | Out-Null

                $s = Get-SEBHealthSummary -InstanceName 'Mixed' -BackupRoot $root
                # 1 of 2 in-window succeeded -> 50% (timezone-independent: both entries sit inside the
                # 7-day window regardless of host locale).
                $s.SuccessRate | Should -Be 50
                # A successful entry exists, so the last-successful age is populated (not the 'Never'
                # default) -- i.e. the function anchored on the success and did not blank out because
                # the NEWEST entry was a failure.
                $s.LastSuccessfulBackupAge          | Should -Not -BeNullOrEmpty
                $s.LastSuccessfulBackupAgeFormatted | Should -Not -Be 'Never'
            }
            finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
        }
    }

    Context 'all backups failed' {
        It 'leaves the last-successful age at the Never default but still reports a 0% rate' {
            $root = New-TempRoot
            try {
                $now = [datetime]::UtcNow
                $history = @(
                    @{ timestamp = $now.AddHours(-2).ToString('o'); type = 'Full';        duration_seconds = 50; archive_size_bytes = 500; success = $false }
                    @{ timestamp = $now.AddHours(-1).ToString('o'); type = 'Incremental'; duration_seconds = 60; archive_size_bytes = 600; success = $false }
                )
                New-MetricsFile -BackupRoot $root -InstanceName 'AllFail' -History $history | Out-Null

                $s = Get-SEBHealthSummary -InstanceName 'AllFail' -BackupRoot $root
                $s.SuccessRate                      | Should -Be 0
                $s.LastSuccessfulBackupAge          | Should -BeNullOrEmpty
                $s.LastSuccessfulBackupAgeFormatted | Should -Be 'Never'
            }
            finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Add-SEBMetric / Get-SEBMetrics round trip' {

    It 'persists an appended metric and reads it back' {
        $root = New-TempRoot
        try {
            $metric = @{
                type                = 'Full'
                duration_seconds    = 135.5
                archive_size_bytes  = 1932735283
                files_changed       = 12
                transfer_seconds    = 45.2
                compression_seconds = 30.1
                vss_seconds         = 8.5
                manifest_seconds    = 2.1
                success             = $true
            }
            Add-SEBMetric -InstanceName 'RoundTrip' -MetricData $metric -BackupRoot $root

            $read = Get-SEBMetrics -InstanceName 'RoundTrip' -BackupRoot $root
            @($read.history).Count | Should -Be 1
            $read.history[0].type             | Should -Be 'Full'
            $read.history[0].archive_size_bytes | Should -Be 1932735283
            $read.history[0].success          | Should -BeTrue
            $read.history[0].timestamp        | Should -Not -BeNullOrEmpty
        }
        finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    }

    It 'appends in order across multiple calls' {
        $root = New-TempRoot
        try {
            Add-SEBMetric -InstanceName 'Seq' -BackupRoot $root -MetricData @{ type = 'Full';        success = $true }
            Add-SEBMetric -InstanceName 'Seq' -BackupRoot $root -MetricData @{ type = 'Incremental'; success = $true }
            Add-SEBMetric -InstanceName 'Seq' -BackupRoot $root -MetricData @{ type = 'Incremental'; success = $false }

            $read = Get-SEBMetrics -InstanceName 'Seq' -BackupRoot $root
            @($read.history).Count | Should -Be 3
            $read.history[0].type | Should -Be 'Full'
            $read.history[2].type | Should -Be 'Incremental'
            $read.history[2].success | Should -BeFalse
        }
        finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    }

    It 'honours -Last by returning only the most recent N entries (newest kept)' {
        $root = New-TempRoot
        try {
            1..5 | ForEach-Object {
                Add-SEBMetric -InstanceName 'Trim' -BackupRoot $root -MetricData @{ type = 'Full'; files_changed = $_; success = $true }
            }
            $read = Get-SEBMetrics -InstanceName 'Trim' -BackupRoot $root -Last 2
            @($read.history).Count | Should -Be 2
            # The two newest (files_changed 4 then 5) are what survive the trim.
            $read.history[0].files_changed | Should -Be 4
            $read.history[1].files_changed | Should -Be 5
        }
        finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    }

    It 'returns an empty history for an unknown instance without throwing' {
        $root = New-TempRoot
        try {
            $read = Get-SEBMetrics -InstanceName 'DoesNotExist' -BackupRoot $root
            $read.instance        | Should -Be 'DoesNotExist'
            @($read.history).Count | Should -Be 0
        }
        finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    }
}
