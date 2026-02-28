function Get-SEBTrendIndicator {
    <#
    .SYNOPSIS
        Determines a trend direction from a series of numeric values using simple linear regression.

    .DESCRIPTION
        Internal helper function that takes an array of numeric values (ordered chronologically)
        and computes the slope of a simple linear regression line. Based on the slope magnitude
        relative to the mean, returns one of three trend indicators:

        - "growing":   the values show a clear upward trend
        - "shrinking": the values show a clear downward trend
        - "stable":    the values show no significant trend

        The threshold for "significant" is a slope whose absolute magnitude exceeds 5% of
        the mean value per data point. This avoids flagging minor fluctuations as trends.

        Requires at least 3 data points to compute a meaningful trend. With fewer points,
        returns "stable".

    .PARAMETER Values
        An array of numeric values ordered chronologically (oldest to newest).

    .EXAMPLE
        Get-SEBTrendIndicator -Values @(100, 110, 120, 130, 140)
        # Returns: "growing"

    .EXAMPLE
        Get-SEBTrendIndicator -Values @(500, 498, 502, 501, 499)
        # Returns: "stable"

    .EXAMPLE
        Get-SEBTrendIndicator -Values @(200, 180, 160, 140, 120)
        # Returns: "shrinking"

    .OUTPUTS
        System.String
        One of: "growing", "stable", "shrinking".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [double[]]$Values
    )

    # Need at least 3 data points for a meaningful trend
    if ($Values.Count -lt 3) {
        return 'stable'
    }

    $n = $Values.Count

    # Simple linear regression: y = mx + b
    # m = (n * sum(xy) - sum(x) * sum(y)) / (n * sum(x^2) - (sum(x))^2)
    $sumX = 0.0
    $sumY = 0.0
    $sumXY = 0.0
    $sumX2 = 0.0

    for ($i = 0; $i -lt $n; $i++) {
        $x = [double]$i
        $y = $Values[$i]
        $sumX += $x
        $sumY += $y
        $sumXY += ($x * $y)
        $sumX2 += ($x * $x)
    }

    $denominator = ($n * $sumX2) - ($sumX * $sumX)
    if ($denominator -eq 0) {
        return 'stable'
    }

    $slope = (($n * $sumXY) - ($sumX * $sumY)) / $denominator
    $mean = $sumY / $n

    # Avoid division by zero for mean
    if ($mean -eq 0) {
        if ($slope -gt 0) { return 'growing' }
        if ($slope -lt 0) { return 'shrinking' }
        return 'stable'
    }

    # Threshold: slope magnitude > 5% of mean per data point
    $threshold = [math]::Abs($mean) * 0.05

    if ($slope -gt $threshold) {
        return 'growing'
    }
    elseif ($slope -lt -$threshold) {
        return 'shrinking'
    }
    else {
        return 'stable'
    }
}
