function Format-LogLine {
    <#
    .SYNOPSIS
        Formats a structured log entry string for the SEBackup logging system.

    .DESCRIPTION
        Internal helper function that constructs a consistently formatted log line
        from the provided components. The output format is:
            [yyyy-MM-dd HH:mm:ss.fff] [LEVEL] [Context] Message

        If no context is provided, the context segment is omitted:
            [yyyy-MM-dd HH:mm:ss.fff] [LEVEL] Message

        This function is not exported and is intended for use only within the
        Logger module.

    .PARAMETER Message
        The log message text to include in the formatted line.

    .PARAMETER Level
        The severity level of the log entry. Expected values: DEBUG, INFO, WARN, ERROR.

    .PARAMETER Context
        Optional context identifier (e.g., server instance name, operation name)
        to include in the log line. When provided, it appears as a bracketed
        segment between the level and the message.

    .PARAMETER Timestamp
        The DateTime value to use for the log entry timestamp. If not provided,
        the current UTC time is used.

    .EXAMPLE
        Format-LogLine -Message "Backup started" -Level "INFO"
        # Returns: [2026-02-27 14:30:00.123] [INFO] Backup started

    .EXAMPLE
        Format-LogLine -Message "Compressing world" -Level "DEBUG" -Context "PvPArena"
        # Returns: [2026-02-27 14:30:00.456] [DEBUG] [PvPArena] Compressing world

    .EXAMPLE
        $ts = [datetime]::Parse("2026-01-15 08:00:00.000")
        Format-LogLine -Message "Test entry" -Level "WARN" -Timestamp $ts
        # Returns: [2026-01-15 08:00:00.000] [WARN] Test entry

    .OUTPUTS
        System.String
        A single formatted log line string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter()]
        [string]$Context,

        [Parameter()]
        [datetime]$Timestamp
    )

    if (-not $PSBoundParameters.ContainsKey('Timestamp')) {
        $Timestamp = [datetime]::UtcNow
    }

    $formattedTime = $Timestamp.ToString('yyyy-MM-dd HH:mm:ss.fff')

    # Pad level to 5 characters for consistent alignment (DEBUG/ERROR are 5, INFO/WARN are 4)
    $paddedLevel = $Level.PadRight(5)

    if ([string]::IsNullOrWhiteSpace($Context)) {
        return "[$formattedTime] [$paddedLevel] $Message"
    }
    else {
        return "[$formattedTime] [$paddedLevel] [$Context] $Message"
    }
}
