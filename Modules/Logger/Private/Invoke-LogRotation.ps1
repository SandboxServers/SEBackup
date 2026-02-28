function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Removes expired log files older than 30 days from the SEBackup log directory.

    .DESCRIPTION
        Internal maintenance function that checks the SEBackup log directory for
        log files (SEBackup_*.log) that are older than 30 days and deletes them.

        To avoid unnecessary filesystem overhead, this function only performs the
        rotation check once per session. It tracks the last check time in the
        module-scoped variable $script:LastRotationCheck and skips execution if
        it has already run during the current PowerShell session.

        This function is not exported and is called automatically by Write-SEBLog.

    .PARAMETER Force
        Forces the rotation check to run even if it has already executed during
        this session. Useful for testing or manual maintenance.

    .EXAMPLE
        Invoke-LogRotation
        # Checks and removes log files older than 30 days (runs only once per session).

    .EXAMPLE
        Invoke-LogRotation -Force
        # Forces the rotation check regardless of whether it has already run.

    .NOTES
        Log files are identified by the naming pattern: SEBackup_*.log
        Only files matching this pattern in the configured log root directory
        are considered for removal.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Force
    )

    # Skip if we already ran rotation this session (unless forced)
    if ($script:LastRotationCheck -and -not $Force) {
        return
    }

    $logRoot = Get-SEBLogPath -DirectoryOnly

    if (-not (Test-Path -Path $logRoot -PathType Container)) {
        return
    }

    $cutoffDate = (Get-Date).AddDays(-30)
    $rotationCount = 0

    try {
        $expiredFiles = Get-ChildItem -Path $logRoot -Filter 'SEBackup_*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoffDate }

        foreach ($file in $expiredFiles) {
            try {
                Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                $rotationCount++
            }
            catch {
                # Best-effort removal; log files that cannot be deleted are skipped.
                # We avoid calling Write-SEBLog here to prevent infinite recursion.
                Write-Warning "Logger: Failed to remove expired log file '$($file.FullName)': $_"
            }
        }

        if ($rotationCount -gt 0) {
            # Write a note about rotation without using Write-SEBLog to avoid recursion
            # during the rotation process itself. The next Write-SEBLog call will
            # naturally follow.
            Write-Verbose "Logger: Removed $rotationCount expired log file(s) older than 30 days."
        }
    }
    catch {
        Write-Warning "Logger: Log rotation check failed: $_"
    }
    finally {
        # Mark rotation as complete for this session regardless of outcome
        $script:LastRotationCheck = [datetime]::UtcNow
    }
}
