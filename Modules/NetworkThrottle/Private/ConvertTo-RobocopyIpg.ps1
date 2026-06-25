function ConvertTo-RobocopyIpg {
    <#
    .SYNOPSIS
        Converts a maximum bandwidth value in Mbps to an appropriate robocopy /IPG value in milliseconds.

    .DESCRIPTION
        Internal helper function that calculates the inter-packet gap (IPG) delay in milliseconds
        for robocopy's /IPG switch, given a target maximum bandwidth in megabits per second.

        Robocopy's /IPG parameter introduces a delay between each 64 KB packet. The conversion
        formula calculates how long to wait between packets to stay within the bandwidth limit:

            IPG (ms) = (PacketSizeKB * 8) / (MaxBandwidthMbps * 1000) * 1000

        For a 64 KB packet size:
            IPG (ms) = (64 * 8) / (MaxBandwidthMbps * 1000) * 1000
            IPG (ms) = 512 / MaxBandwidthMbps

        If the MaxBandwidthMbps is 0 or negative, returns 0 (no throttling).

    .PARAMETER MaxBandwidthMbps
        The target maximum bandwidth in megabits per second. Must be a positive integer
        for throttling to take effect. A value of 0 or less disables throttling (returns 0).

    .EXAMPLE
        ConvertTo-RobocopyIpg -MaxBandwidthMbps 10
        # Returns: 52 (~52ms delay between 64KB packets)

    .EXAMPLE
        ConvertTo-RobocopyIpg -MaxBandwidthMbps 1000
        # Returns: 0 -- above ~512 Mbps a 1ms IPG would still cap throughput at ~512 Mbps,
        # so throttling cannot represent the target and is disabled rather than over-limiting.

    .EXAMPLE
        ConvertTo-RobocopyIpg -MaxBandwidthMbps 0
        # Returns: 0 (no throttling)

    .OUTPUTS
        System.Int32
        The inter-packet gap value in milliseconds for robocopy /IPG.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [int]$MaxBandwidthMbps
    )

    if ($MaxBandwidthMbps -le 0) {
        return 0
    }

    # Robocopy sends data in 64 KB packets
    # IPG (ms) = (64 KB * 8 bits/byte) / (MaxBandwidthMbps * 1000 Kbps/Mbps) * 1000 ms/s
    # Simplified: 512 / MaxBandwidthMbps
    $rawIpg = 512.0 / $MaxBandwidthMbps

    # /IPG is an integer-millisecond gap with a 1ms floor. When the target bandwidth is high
    # enough that even a 1ms gap would still cap throughput below it (> ~512 Mbps), IPG cannot
    # represent the target -- clamping to 1ms would WRONGLY throttle a fast link down to ~512
    # Mbps, so disable throttling (return 0) instead.
    if ($rawIpg -lt 1) {
        return 0
    }

    return [int][math]::Ceiling($rawIpg)
}
