function Get-SEBLogPath {
    <#
    .SYNOPSIS
        Returns the current SEBackup log file path or log directory path.

    .DESCRIPTION
        Resolves and returns the full path to today's SEBackup log file. The log
        file follows the naming convention SEBackup_yyyy-MM-dd.log and is located
        in the log root directory.

        The log root directory defaults to the Logs folder two levels above the
        Logger module directory (i.e., <ProjectRoot>/Logs). This can be overridden
        by setting $script:SEBLogRoot within the module scope, which is useful for
        testing or custom deployment configurations.

        If the log directory does not yet exist, this function creates it
        automatically.

    .PARAMETER DirectoryOnly
        When specified, returns only the log root directory path instead of the
        full path to today's log file.

    .PARAMETER Date
        Specifies a date to return the log file path for. Defaults to today's date.
        Useful for retrieving paths to historical log files.

    .EXAMPLE
        Get-SEBLogPath
        # Returns: C:\Projects\SEBackup\Logs\SEBackup_2026-02-27.log

    .EXAMPLE
        Get-SEBLogPath -DirectoryOnly
        # Returns: C:\Projects\SEBackup\Logs

    .EXAMPLE
        Get-SEBLogPath -Date (Get-Date).AddDays(-1)
        # Returns the log file path for yesterday.

    .OUTPUTS
        System.String
        The full path to the log file or log directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [switch]$DirectoryOnly,

        [Parameter()]
        [datetime]$Date
    )

    # Resolve log root directory
    if ([string]::IsNullOrWhiteSpace($script:SEBLogRoot)) {
        $script:SEBLogRoot = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'Logs')
        )
    }

    # Ensure the directory exists
    if (-not (Test-Path -Path $script:SEBLogRoot -PathType Container)) {
        try {
            New-Item -Path $script:SEBLogRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Warning "Logger: Failed to create log directory '$($script:SEBLogRoot)': $_"
        }
    }

    if ($DirectoryOnly) {
        return $script:SEBLogRoot
    }

    if (-not $PSBoundParameters.ContainsKey('Date')) {
        $Date = Get-Date
    }

    $fileName = "SEBackup_$($Date.ToString('yyyy-MM-dd')).log"
    return [System.IO.Path]::Combine($script:SEBLogRoot, $fileName)
}
