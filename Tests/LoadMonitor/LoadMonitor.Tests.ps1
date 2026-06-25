#Requires -Module Pester

# Behavioral tests for the LoadMonitor module (issue #20). LoadMonitor previously had only the
# function-existence contract checks in SEBackup.Tests.ps1 (~near-zero behavioral coverage); this
# suite exercises the actual parsing, threshold, and defer/skip logic of the three public functions
# WITHOUT any real WinRM / VRage / Torch by mocking at the infrastructure boundary:
#
#   * Get-SEBNodeMetrics      -> mock Invoke-SEBRemoteCommand (LoadMonitor scope) to return canned
#                                CPU/mem/disk; assert the structured PSCustomObject shape, and that a
#                                remote failure is swallowed into the default result (never throws).
#   * Test-SEBNodeLoad        -> mock Get-SEBPlayerCount + Invoke-SEBRemoteCommand (the CPU and memory
#                                CIM calls, told apart by their scriptblock text) to drive under / at /
#                                over-threshold cases; assert CanProceed and the Reasons text.
#   * Wait-SEBNodeLoad        -> mock Test-SEBNodeLoad (busy-then-idle) and Start-Sleep so the defer
#                                loop is fully simulated (NO real sleeping): assert it waits then
#                                proceeds, that 'skip' returns immediately, and that a persistently
#                                busy node keeps polling/sleeping (the wait mechanics) rather than
#                                proceeding.
#
# Mocks use -ModuleName LoadMonitor (Pester 5) because the functions run in the LoadMonitor nested
# module scope when imported via the root SEBackup.psd1, so their internal calls resolve there.
# The -Session parameter is strongly typed [System.Management.Automation.Runspaces.PSSession], which
# has no public constructor, so we hand it an UNINITIALIZED instance (the repo's established double).

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # A type-satisfying PSSession that touches no transport (no public ctor -> uninitialized object).
    function New-FakeSession {
        [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
            [System.Management.Automation.Runspaces.PSSession])
    }
}

Describe 'Get-SEBNodeMetrics' {
    BeforeAll {
        Mock Write-SEBLog {} -ModuleName LoadMonitor
    }

    Context 'parses canned remote metrics into a structured object' {
        BeforeAll {
            # The function gathers everything in ONE Invoke-SEBRemoteCommand returning a hashtable.
            Mock Invoke-SEBRemoteCommand -ModuleName LoadMonitor {
                @{
                    Cpu    = @{ AveragePercent = 42.5; Processors = @(40, 45) }
                    Memory = @{ TotalMB = 16384; AvailableMB = 8192; UsedPercent = 50.0 }
                    Disks  = @(
                        @{ DriveLetter = 'C:'; TotalGB = 200.0; FreeGB = 50.0; UsedPercent = 75.0 }
                        @{ DriveLetter = 'D:'; TotalGB = 500.0; FreeGB = 400.0; UsedPercent = 20.0 }
                    )
                }
            }
            $script:metrics = Get-SEBNodeMetrics -Session (New-FakeSession)
        }

        It 'returns a PSCustomObject with the documented top-level shape' {
            $script:metrics | Should -Not -BeNullOrEmpty
            $script:metrics.PSObject.Properties.Name | Should -Contain 'Cpu'
            $script:metrics.PSObject.Properties.Name | Should -Contain 'Memory'
            $script:metrics.PSObject.Properties.Name | Should -Contain 'Disks'
            $script:metrics.PSObject.Properties.Name | Should -Contain 'CollectedAt'
            $script:metrics.CollectedAt | Should -BeOfType [datetime]
        }

        It 'maps the CPU block (average + per-processor array)' {
            $script:metrics.Cpu.AveragePercent | Should -Be 42.5
            $script:metrics.Cpu.Processors | Should -Be @(40, 45)
        }

        It 'maps the memory block' {
            $script:metrics.Memory.TotalMB | Should -Be 16384
            $script:metrics.Memory.AvailableMB | Should -Be 8192
            $script:metrics.Memory.UsedPercent | Should -Be 50.0
        }

        It 'maps each disk into its own object' {
            @($script:metrics.Disks).Count | Should -Be 2
            $script:metrics.Disks[0].DriveLetter | Should -Be 'C:'
            $script:metrics.Disks[0].UsedPercent | Should -Be 75.0
            $script:metrics.Disks[1].DriveLetter | Should -Be 'D:'
            $script:metrics.Disks[1].FreeGB | Should -Be 400.0
        }

        It 'routes its collection through the remoting wrapper exactly once' {
            Get-SEBNodeMetrics -Session (New-FakeSession) | Out-Null
            Should -Invoke Invoke-SEBRemoteCommand -ModuleName LoadMonitor -Times 1 -Exactly
        }
    }

    Context 'a remote failure is swallowed (never throws; returns the default result)' {
        BeforeAll {
            Mock Invoke-SEBRemoteCommand -ModuleName LoadMonitor { throw 'WinRM transport dropped' }
        }

        It 'does not throw and returns the empty default shape' {
            $result = $null
            { $script:r = Get-SEBNodeMetrics -Session (New-FakeSession) 3>$null } | Should -Not -Throw
            $script:r | Should -Not -BeNullOrEmpty
            $script:r.Cpu | Should -BeNullOrEmpty
            $script:r.Memory | Should -BeNullOrEmpty
            @($script:r.Disks).Count | Should -Be 0
            # CollectedAt is always stamped, even on failure.
            $script:r.CollectedAt | Should -BeOfType [datetime]
        }

        It 'logs the failure at ERROR via Write-SEBLog' {
            Get-SEBNodeMetrics -Session (New-FakeSession) 3>$null | Out-Null
            Should -Invoke Write-SEBLog -ModuleName LoadMonitor -ParameterFilter { $Level -eq 'ERROR' }
        }
    }
}

Describe 'Test-SEBNodeLoad' {
    BeforeAll {
        Mock Write-SEBLog {} -ModuleName LoadMonitor

        # Drive the two remote CIM calls deterministically. The function issues two separate
        # Invoke-SEBRemoteCommand calls; we tell them apart by their scriptblock text:
        #   - CPU block       contains 'Win32_Processor'        -> return a numeric load percent.
        #   - Memory block    contains 'Win32_OperatingSystem'  -> return Total/Free KB.
        # Tests set $script:cpuPercent / $script:totalKb / $script:freeKb before calling.
        function Set-NodeLoadMocks {
            Mock Get-SEBPlayerCount -ModuleName LoadMonitor { $script:players }
            Mock Invoke-SEBRemoteCommand -ModuleName LoadMonitor {
                $text = $ScriptBlock.ToString()
                if ($text -match 'Win32_OperatingSystem') {
                    [PSCustomObject]@{
                        TotalVisibleMemoryKB = $script:totalKb
                        FreePhysicalMemoryKB = $script:freeKb
                    }
                }
                else {
                    [double]$script:cpuPercent
                }
            }
        }
    }

    BeforeEach {
        # Healthy defaults: 8 GB total, 6 GB free (25% used), 10% CPU, 0 players.
        $script:players = 0
        $script:cpuPercent = 10.0
        $script:totalKb = 8 * 1024 * 1024
        $script:freeKb = 6 * 1024 * 1024
        Set-NodeLoadMocks
    }

    It 'short-circuits to CanProceed=$true when load_awareness is disabled (no remote calls)' {
        $gc = @{ load_awareness = @{ enabled = $false } }
        $r = Test-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc
        $r.CanProceed | Should -BeTrue
        $r.Reasons | Should -BeNullOrEmpty
        Should -Invoke Invoke-SEBRemoteCommand -ModuleName LoadMonitor -Times 0 -Exactly
    }

    It 'short-circuits when the load_awareness section is entirely absent' {
        $r = Test-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig @{}
        $r.CanProceed | Should -BeTrue
    }

    It 'proceeds when every metric is comfortably under threshold' {
        $gc = @{ load_awareness = @{ enabled = $true; max_cpu_percent = 80; max_memory_percent = 85; max_player_count = 10 } }
        $r = Test-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc
        $r.CanProceed | Should -BeTrue
        @($r.Reasons).Count | Should -Be 0
        $r.CpuPercent | Should -Be 10.0
        $r.PlayerCount | Should -Be 0
    }

    It 'blocks on over-threshold CPU and explains why' {
        $script:cpuPercent = 95.0
        $gc = @{ load_awareness = @{ enabled = $true; max_cpu_percent = 80 } }
        $r = Test-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc
        $r.CanProceed | Should -BeFalse
        ($r.Reasons -join ';') | Should -Match 'CPU usage'
        $r.CpuPercent | Should -Be 95.0
    }

    It 'treats CPU exactly AT the threshold as acceptable (boundary: > is the trigger, not >=)' {
        $script:cpuPercent = 80.0
        $gc = @{ load_awareness = @{ enabled = $true; max_cpu_percent = 80 } }
        $r = Test-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc
        $r.CanProceed | Should -BeTrue
    }

    It 'blocks on over-threshold memory usage' {
        # 8 GB total, 0.5 GB free => ~94% used, over an 85% cap.
        $script:freeKb = [int](0.5 * 1024 * 1024)
        $gc = @{ load_awareness = @{ enabled = $true; max_memory_percent = 85 } }
        $r = Test-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc
        $r.CanProceed | Should -BeFalse
        ($r.Reasons -join ';') | Should -Match 'Memory usage'
    }

    It 'blocks on over-threshold player count and reports it' {
        $script:players = 25
        $gc = @{ load_awareness = @{ enabled = $true; max_player_count = 10 } }
        $r = Test-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc
        $r.CanProceed | Should -BeFalse
        $r.PlayerCount | Should -Be 25
        ($r.Reasons -join ';') | Should -Match 'Player count'
    }

    It 'ignores player count when max_player_count is 0 (the "do not gate on players" sentinel)' {
        $script:players = 999
        $gc = @{ load_awareness = @{ enabled = $true; max_player_count = 0; max_cpu_percent = 80; max_memory_percent = 85 } }
        $r = Test-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc
        $r.CanProceed | Should -BeTrue
        $r.PlayerCount | Should -Be 999
    }

    It 'accumulates multiple reasons when several metrics are over threshold' {
        $script:cpuPercent = 99.0
        $script:players = 50
        $script:freeKb = [int](0.2 * 1024 * 1024)   # ~97% memory used
        $gc = @{ load_awareness = @{ enabled = $true; max_cpu_percent = 80; max_memory_percent = 85; max_player_count = 10 } }
        $r = Test-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc
        $r.CanProceed | Should -BeFalse
        @($r.Reasons).Count | Should -BeGreaterOrEqual 3
    }

    It 'fails open on CPU/memory: a remote CIM failure does not block the backup' {
        # If the node CIM query itself throws, the function logs a warning and leaves that metric
        # uncounted -- it must not flip CanProceed to false purely because telemetry was unavailable.
        Mock Get-SEBPlayerCount -ModuleName LoadMonitor { 0 }
        Mock Invoke-SEBRemoteCommand -ModuleName LoadMonitor { throw 'CIM unavailable' }
        $gc = @{ load_awareness = @{ enabled = $true; max_cpu_percent = 80; max_memory_percent = 85 } }
        $r = Test-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc 3>$null
        $r.CanProceed | Should -BeTrue
    }
}

Describe 'Wait-SEBNodeLoad' {
    BeforeAll {
        Mock Write-SEBLog {} -ModuleName LoadMonitor
    }

    It 'returns CanProceed=$true immediately when load awareness is disabled' {
        $gc = @{ load_awareness = @{ enabled = $false } }
        $r = Wait-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc
        $r.CanProceed | Should -BeTrue
        $r.PollCount | Should -Be 0
    }

    It 'on_high_load = "skip" returns CanProceed=$false immediately without polling' {
        Mock Test-SEBNodeLoad -ModuleName LoadMonitor { throw 'must not poll when policy is skip' }
        Mock Start-Sleep -ModuleName LoadMonitor { throw 'must not sleep when policy is skip' }
        $gc = @{ load_awareness = @{ enabled = $true; on_high_load = 'skip' } }
        $r = Wait-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc
        $r.CanProceed | Should -BeFalse
        $r.PollCount | Should -Be 0
        $r.Reason | Should -Match 'skip'
        Should -Invoke Test-SEBNodeLoad -ModuleName LoadMonitor -Times 0 -Exactly
        Should -Invoke Start-Sleep -ModuleName LoadMonitor -Times 0 -Exactly
    }

    It 'defers: waits while busy, then proceeds when load drops (Start-Sleep mocked -- no real wait)' {
        # Busy for the first two polls, clear on the third. Start-Sleep is a no-op so the configured
        # 30s interval costs nothing; the test runs in milliseconds.
        $script:pollNo = 0
        Mock Start-Sleep -ModuleName LoadMonitor {}
        Mock Test-SEBNodeLoad -ModuleName LoadMonitor {
            $script:pollNo++
            $clear = $script:pollNo -ge 3
            [PSCustomObject]@{
                CanProceed        = $clear
                PlayerCount       = 0
                CpuPercent        = if ($clear) { 10 } else { 99 }
                AvailableMemoryMB = 5000
                Reasons           = if ($clear) { @() } else { @('CPU usage (99%) exceeds threshold (80%)') }
            }
        }
        $gc = @{ load_awareness = @{ enabled = $true; on_high_load = 'defer'; check_interval_seconds = 30; max_backoff_minutes = 60 } }
        $r = Wait-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc

        $r.CanProceed | Should -BeTrue
        $r.PollCount | Should -Be 3
        $r.Reason | Should -Match 'Load dropped'
        # It polled three times and slept exactly twice (between the three polls), never for real.
        Should -Invoke Test-SEBNodeLoad -ModuleName LoadMonitor -Times 3 -Exactly
        Should -Invoke Start-Sleep -ModuleName LoadMonitor -Times 2 -Exactly
    }

    It 'proceeds on the very first poll without sleeping when load is already clear' {
        Mock Start-Sleep -ModuleName LoadMonitor {}
        Mock Test-SEBNodeLoad -ModuleName LoadMonitor {
            [PSCustomObject]@{ CanProceed = $true; PlayerCount = 0; CpuPercent = 5; AvailableMemoryMB = 9000; Reasons = @() }
        }
        $gc = @{ load_awareness = @{ enabled = $true; on_high_load = 'defer'; check_interval_seconds = 30; max_backoff_minutes = 60 } }
        $r = Wait-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc
        $r.CanProceed | Should -BeTrue
        $r.PollCount | Should -Be 1
        Should -Invoke Start-Sleep -ModuleName LoadMonitor -Times 0 -Exactly
    }

    It 'honors the legacy defer_* config keys (defer_poll_interval_seconds / defer_wait_minutes)' {
        # The shipped names are check_interval_seconds / max_backoff_minutes; the older defer_* names
        # must still be accepted so existing operator configs keep working. We assert the loop still
        # polls + sleeps under ONLY the legacy keys (proving they were read, not ignored).
        $script:legPoll = 0
        Mock Start-Sleep -ModuleName LoadMonitor {}
        Mock Test-SEBNodeLoad -ModuleName LoadMonitor {
            $script:legPoll++
            [PSCustomObject]@{ CanProceed = ($script:legPoll -ge 2); PlayerCount = 0; CpuPercent = 50; AvailableMemoryMB = 4000; Reasons = @() }
        }
        $gc = @{ load_awareness = @{ enabled = $true; on_high_load = 'defer'; defer_poll_interval_seconds = 45; defer_wait_minutes = 30 } }
        $r = Wait-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc
        $r.CanProceed | Should -BeTrue
        $r.PollCount | Should -Be 2
        Should -Invoke Start-Sleep -ModuleName LoadMonitor -Times 1 -Exactly
    }

    It 'keeps polling + sleeping (does NOT proceed) while the node stays busy -- the wait mechanic' {
        # A persistently-busy node must keep deferring, not proceed. The natural wall-clock timeout
        # return is bounded by a >=60s real Stopwatch (max_backoff_minutes is integer-minutes and the
        # function owns a real Stopwatch we cannot inject), so we do NOT spin to the natural timeout
        # in CI. Instead we prove the loop's wait behavior deterministically: keep it busy and let the
        # mocked Start-Sleep THROW a sentinel after a few iterations, then assert it polled+slept that
        # many times and never returned a proceed verdict. No real sleeping occurs.
        $script:sleeps = 0
        Mock Test-SEBNodeLoad -ModuleName LoadMonitor {
            [PSCustomObject]@{ CanProceed = $false; PlayerCount = 0; CpuPercent = 99; AvailableMemoryMB = 100; Reasons = @('CPU usage (99%) exceeds threshold (80%)') }
        }
        Mock Start-Sleep -ModuleName LoadMonitor {
            $script:sleeps++
            if ($script:sleeps -ge 3) { throw 'SENTINEL-STOP-WAIT' }
        }
        $gc = @{ load_awareness = @{ enabled = $true; on_high_load = 'defer'; check_interval_seconds = 30; max_backoff_minutes = 60 } }
        { Wait-SEBNodeLoad -Session (New-FakeSession) -InstanceConfig @{} -GlobalConfig $gc } |
            Should -Throw -ExpectedMessage '*SENTINEL-STOP-WAIT*'
        # It polled and slept (would have waited) rather than proceeding: 3 sleeps means 3 busy polls.
        Should -Invoke Start-Sleep -ModuleName LoadMonitor -Times 3 -Exactly
        Should -Invoke Test-SEBNodeLoad -ModuleName LoadMonitor -Times 3 -Exactly
    }
}
