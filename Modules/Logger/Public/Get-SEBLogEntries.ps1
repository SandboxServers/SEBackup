function Get-SEBLogEntries {
    <#
    .SYNOPSIS
        Reads and parses SEBackup log entries into structured objects.

    .DESCRIPTION
        Reads an SEBackup log file and parses each entry into a structured object
        with Timestamp, Level, Context, and Message properties. Supports filtering
        by severity level, time range, context, and limiting the number of results.

        When no -Path is specified, the function reads today's log file. The log
        entries are parsed from the standard SEBackup log format:
            [yyyy-MM-dd HH:mm:ss.fff] [LEVEL] [Context] Message
        or:
            [yyyy-MM-dd HH:mm:ss.fff] [LEVEL] Message

    .PARAMETER Path
        The full path to the log file to parse. Defaults to today's log file
        as returned by Get-SEBLogPath.

    .PARAMETER Level
        Filters log entries to only include those matching the specified severity
        level. Valid values: DEBUG, INFO, WARN, ERROR.

    .PARAMETER Since
        Filters log entries to only include those with a timestamp on or after
        the specified DateTime value.

    .PARAMETER Context
        Filters log entries to only include those matching the specified context
        string. Supports wildcards (e.g., "PvP*").

    .PARAMETER Last
        Returns only the last N log entries (after all other filters are applied).

    .EXAMPLE
        Get-SEBLogEntries
        # Returns all entries from today's log file as parsed objects.

    .EXAMPLE
        Get-SEBLogEntries -Level ERROR
        # Returns only ERROR-level entries from today's log.

    .EXAMPLE
        Get-SEBLogEntries -Since (Get-Date).AddHours(-1)
        # Returns all entries from the last hour.

    .EXAMPLE
        Get-SEBLogEntries -Context "PvPArena" -Level WARN -Last 10
        # Returns the last 10 WARN entries with the PvPArena context.

    .EXAMPLE
        Get-SEBLogEntries -Path "C:\SEBackup\Logs\SEBackup_2026-02-25.log"
        # Reads and parses entries from a specific log file.

    .OUTPUTS
        PSCustomObject
        Objects with the following properties:
        - Timestamp [datetime] : The UTC timestamp of the log entry.
        - Level     [string]   : The severity level (DEBUG, INFO, WARN, ERROR).
        - Context   [string]   : The context tag, or empty string if none.
        - Message   [string]   : The log message text.

    .LINK
        Write-SEBLog
        Get-SEBLogPath
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [string]$Path,

        [Parameter()]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter()]
        [datetime]$Since,

        [Parameter()]
        [string]$Context,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Last
    )

    # Resolve log file path
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-SEBLogPath
    }

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        Write-Warning "Logger: Log file not found at '$Path'."
        return
    }

    # Read all lines from the file
    try {
        $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
    }
    catch {
        Write-Error "Logger: Failed to read log file '$Path': $_"
        return
    }

    # Regex to parse the standard log format:
    # [2026-02-27 14:30:00.123] [INFO ] [ContextName] Message text here
    # [2026-02-27 14:30:00.123] [INFO ] Message text here
    $logPattern = '^\[(?<timestamp>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\]\s+\[(?<level>\w+)\s*\]\s*(?:\[(?<context>[^\]]*)\]\s+)?(?<message>.*)$'

    $entries = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match $logPattern) {
            $entryTimestamp = [datetime]::ParseExact(
                $Matches['timestamp'].Trim(),
                'yyyy-MM-dd HH:mm:ss.fff',
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            )
            $entryLevel   = $Matches['level'].Trim()
            $entryContext = if ($Matches['context']) { $Matches['context'].Trim() } else { '' }
            $entryMessage = $Matches['message'].Trim()

            # Apply filters

            # Level filter
            if ($PSBoundParameters.ContainsKey('Level') -and $entryLevel -ne $Level) {
                continue
            }

            # Since filter
            if ($PSBoundParameters.ContainsKey('Since') -and $entryTimestamp -lt $Since) {
                continue
            }

            # Context filter (supports wildcards)
            if ($PSBoundParameters.ContainsKey('Context') -and $entryContext -notlike $Context) {
                continue
            }

            $entry = [PSCustomObject]@{
                Timestamp = $entryTimestamp
                Level     = $entryLevel
                Context   = $entryContext
                Message   = $entryMessage
            }

            # Add type name for formatting
            $entry.PSObject.TypeNames.Insert(0, 'SEBackup.LogEntry')

            $entries.Add($entry)
        }
        else {
            # Line does not match expected format; treat as continuation of previous
            # message or a raw line. Attach to the last entry if one exists.
            if ($entries.Count -gt 0) {
                $lastEntry = $entries[$entries.Count - 1]
                $lastEntry.Message = "$($lastEntry.Message)`n$line"
            }
        }
    }

    # Apply -Last filter
    if ($PSBoundParameters.ContainsKey('Last') -and $entries.Count -gt $Last) {
        $entries = [System.Collections.Generic.List[PSCustomObject]]::new(
            $entries.GetRange($entries.Count - $Last, $Last)
        )
    }

    return $entries
}
