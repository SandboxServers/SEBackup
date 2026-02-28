function Write-SEBLog {
    <#
    .SYNOPSIS
        Writes a structured, thread-safe log entry to the SEBackup log file and console.

    .DESCRIPTION
        The primary logging function for the SEBackup system. Writes a formatted
        log entry to the daily rotating log file and optionally displays it on the
        console with color-coded output based on severity level.

        Log entries follow the format:
            [yyyy-MM-dd HH:mm:ss.fff] [LEVEL] [Context] Message

        Features:
        - Thread-safe file writes using a named system mutex, allowing multiple
          PowerShell processes or runspaces to log concurrently without corruption.
        - Daily log file rotation with automatic file naming (SEBackup_yyyy-MM-dd.log).
        - Color-coded console output: DEBUG=Gray, INFO=Cyan, WARN=Yellow, ERROR=Red.
        - Automatic context injection from Start-SEBLogContext session context.
        - Periodic log rotation to remove files older than 30 days.

    .PARAMETER Message
        The log message text to record. This parameter accepts pipeline input.

    .PARAMETER Level
        The severity level of the log entry. Must be one of: DEBUG, INFO, WARN, ERROR.
        Defaults to INFO if not specified.

    .PARAMETER Context
        An optional context identifier to include in the log entry (e.g., a server
        instance name or operation name). If not provided and a session context has
        been set via Start-SEBLogContext, the session context is used instead.
        An explicitly provided -Context value always takes precedence over the
        session context.

    .PARAMETER NoConsole
        When specified, suppresses console output for this log entry. The entry
        is still written to the log file. Useful for high-frequency operations
        where console output would be excessive.

    .EXAMPLE
        Write-SEBLog -Message "Backup operation started" -Level INFO
        # Writes an INFO-level entry to the log file and console.

    .EXAMPLE
        Write-SEBLog -Message "VSS snapshot failed" -Level ERROR -Context "PvPArena"
        # Writes an ERROR-level entry with [PvPArena] context.

    .EXAMPLE
        Write-SEBLog -Message "Checking file hash" -Level DEBUG -NoConsole
        # Writes a DEBUG entry to the log file only; no console output.

    .EXAMPLE
        "Starting phase 1", "Starting phase 2" | Write-SEBLog -Level INFO
        # Logs multiple messages via pipeline input.

    .OUTPUTS
        None

    .LINK
        Get-SEBLogPath
        Get-SEBLogEntries
        Start-SEBLogContext
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter()]
        [string]$Context,

        [Parameter()]
        [switch]$NoConsole
    )

    begin {
        # Resolve the effective context: explicit parameter > session context > none
        $effectiveContext = if (-not [string]::IsNullOrWhiteSpace($Context)) {
            $Context
        }
        elseif (-not [string]::IsNullOrWhiteSpace($script:SEBLogContext)) {
            $script:SEBLogContext
        }
        else {
            $null
        }

        # Resolve log file path
        $logFilePath = Get-SEBLogPath

        # Console color map
        $colorMap = @{
            'DEBUG' = 'Gray'
            'INFO'  = 'Cyan'
            'WARN'  = 'Yellow'
            'ERROR' = 'Red'
        }
    }

    process {
        $timestamp = [datetime]::UtcNow

        # Format the log line using the private helper
        $logLine = Format-LogLine -Message $Message -Level $Level -Context $effectiveContext -Timestamp $timestamp

        # Thread-safe file write using a named mutex
        $mutexName = 'Global\SEBackupLoggerMutex'
        $mutexAcquired = $false

        try {
            # Create or open the named mutex
            if (-not $script:LogMutex) {
                $script:LogMutex = [System.Threading.Mutex]::new($false, $mutexName)
            }

            # Attempt to acquire the mutex with a 5-second timeout
            $mutexAcquired = $script:LogMutex.WaitOne(5000)

            if ($mutexAcquired) {
                # Ensure the log directory exists
                $logDir = [System.IO.Path]::GetDirectoryName($logFilePath)
                if (-not (Test-Path -Path $logDir -PathType Container)) {
                    New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }

                # Append the log line to the file
                [System.IO.File]::AppendAllText(
                    $logFilePath,
                    "$logLine`n",
                    [System.Text.Encoding]::UTF8
                )
            }
            else {
                # Mutex timeout - fall back to a direct write attempt
                Write-Warning "Logger: Mutex acquisition timed out. Attempting direct write."
                [System.IO.File]::AppendAllText(
                    $logFilePath,
                    "$logLine`n",
                    [System.Text.Encoding]::UTF8
                )
            }
        }
        catch {
            Write-Warning "Logger: Failed to write log entry to '$logFilePath': $_"
        }
        finally {
            if ($mutexAcquired -and $script:LogMutex) {
                try { $script:LogMutex.ReleaseMutex() } catch { }
            }
        }

        # Console output with color coding
        if (-not $NoConsole) {
            $consoleColor = $colorMap[$Level]
            Write-Host $logLine -ForegroundColor $consoleColor
        }

        # Trigger periodic log rotation (runs at most once per session)
        Invoke-LogRotation
    }
}
