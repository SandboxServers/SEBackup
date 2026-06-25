#Requires -Module Pester

# Issue #19 -- direct unit coverage for Get-SEBTrendIndicator, the Private trend-direction helper
# that drives the DurationTrend / SizeTrend fields of the health summary. It fits a simple linear
# regression over a chronologically ordered numeric series and classifies the slope, relative to a
# 5%-of-mean threshold, as 'growing' / 'shrinking' / 'stable'.
#
# This is pure math (numbers in, string out) with no I/O, so it is exercised with in-memory series
# and asserted exactly. Because the function is NOT exported, every test runs InModuleScope so the
# private function is reachable. Expected outcomes were precomputed from the regression/threshold
# definition in the source, so they fail if that math is changed.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null
}

Describe 'Get-SEBTrendIndicator' {

    Context 'clear monotonic trends' {
        It 'classifies a steadily rising series as growing' {
            InModuleScope MetricsCollector {
                Get-SEBTrendIndicator -Values @(100, 110, 120, 130, 140) | Should -Be 'growing'
            }
        }

        It 'classifies a steadily falling series as shrinking' {
            InModuleScope MetricsCollector {
                Get-SEBTrendIndicator -Values @(200, 180, 160, 140, 120) | Should -Be 'shrinking'
            }
        }

        It 'classifies a flat / noisy series as stable' {
            InModuleScope MetricsCollector {
                # Tiny fluctuations around 500: slope is well under 5% of the mean.
                Get-SEBTrendIndicator -Values @(500, 498, 502, 501, 499) | Should -Be 'stable'
            }
        }
    }

    Context 'too few points to judge a trend' {
        It 'returns stable for a two-point series even with a large jump' {
            InModuleScope MetricsCollector {
                # Fewer than 3 points -> no meaningful regression -> stable, regardless of the gap.
                Get-SEBTrendIndicator -Values @(1, 1000) | Should -Be 'stable'
            }
        }

        It 'returns stable for a single point' {
            InModuleScope MetricsCollector {
                Get-SEBTrendIndicator -Values @(42) | Should -Be 'stable'
            }
        }
    }

    Context 'threshold behaviour (5% of the mean per data point)' {
        It 'calls a slope just OVER 5% of the mean growing' {
            InModuleScope MetricsCollector {
                # slope 5.10 vs threshold 5.00 (mean 100.10) -> just crosses into growing.
                Get-SEBTrendIndicator -Values @(90, 95, 100, 105, 110.5) | Should -Be 'growing'
            }
        }

        It 'calls a slope under 5% of the mean stable' {
            InModuleScope MetricsCollector {
                # slope 1.00 vs threshold 5.00 (mean 100) -> stays stable.
                Get-SEBTrendIndicator -Values @(98, 99, 100, 101, 102) | Should -Be 'stable'
            }
        }
    }

    Context 'degenerate means' {
        It 'returns stable when every value is zero (mean 0, slope 0)' {
            InModuleScope MetricsCollector {
                Get-SEBTrendIndicator -Values @(0, 0, 0, 0) | Should -Be 'stable'
            }
        }

        It 'returns growing for a rising series whose mean is exactly zero' {
            InModuleScope MetricsCollector {
                # mean = 0 triggers the sign-of-slope branch; this series rises through zero.
                Get-SEBTrendIndicator -Values @(-10, 0, 10) | Should -Be 'growing'
            }
        }

        It 'returns shrinking for a falling series whose mean is exactly zero' {
            InModuleScope MetricsCollector {
                Get-SEBTrendIndicator -Values @(10, 0, -10) | Should -Be 'shrinking'
            }
        }
    }

    It 'always returns one of the three documented indicator strings' {
        InModuleScope MetricsCollector {
            foreach ($series in @(
                    , @(1, 2, 3, 4, 5)
                    , @(5, 4, 3, 2, 1)
                    , @(7, 7, 7)
                    , @(1, 1000)
                )) {
                Get-SEBTrendIndicator -Values $series | Should -BeIn @('growing', 'shrinking', 'stable')
            }
        }
    }
}
