#Requires -Module Pester

# ConvertTo-RobocopyIpg maps a target Mbps to robocopy's integer-millisecond /IPG gap.
# Above ~512 Mbps a 1ms gap still caps throughput at ~512 Mbps, so throttling must be
# disabled (0) rather than clamped to 1ms, which would throttle a fast link down to 512.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . "$repoRoot/Modules/NetworkThrottle/Private/ConvertTo-RobocopyIpg.ps1"
}

Describe 'ConvertTo-RobocopyIpg' {
    It 'returns 0 (no throttle) for non-positive bandwidth' {
        ConvertTo-RobocopyIpg -MaxBandwidthMbps 0  | Should -Be 0
        ConvertTo-RobocopyIpg -MaxBandwidthMbps -5 | Should -Be 0
    }
    It 'computes a conservative (ceiling) gap for representable bandwidths' {
        ConvertTo-RobocopyIpg -MaxBandwidthMbps 10  | Should -Be 52   # ceil(51.2)
        ConvertTo-RobocopyIpg -MaxBandwidthMbps 100 | Should -Be 6    # ceil(5.12)
        ConvertTo-RobocopyIpg -MaxBandwidthMbps 512 | Should -Be 1    # exactly 1ms
    }
    It 'disables throttling above ~512 Mbps instead of capping at 512' {
        ConvertTo-RobocopyIpg -MaxBandwidthMbps 600  | Should -Be 0
        ConvertTo-RobocopyIpg -MaxBandwidthMbps 1000 | Should -Be 0
    }
}
