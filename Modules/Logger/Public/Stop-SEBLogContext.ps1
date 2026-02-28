function Stop-SEBLogContext {
    <#
    .SYNOPSIS
        Clears the current SEBackup logging context.

    .DESCRIPTION
        Removes the active logging context that was previously set by
        Start-SEBLogContext. After calling this function, subsequent log entries
        written by Write-SEBLog will no longer include a context prefix unless
        one is explicitly provided via the -Context parameter.

        This function is safe to call even if no context is currently active;
        it will simply ensure the context is cleared.

    .EXAMPLE
        Start-SEBLogContext -Context "PvPArena"
        Write-SEBLog -Message "Backup complete" -Level INFO
        Stop-SEBLogContext
        Write-SEBLog -Message "Idle" -Level DEBUG
        # First log has [PvPArena] prefix, second log does not.

    .EXAMPLE
        Stop-SEBLogContext
        # Safely clears context even if none was active.

    .OUTPUTS
        None

    .LINK
        Start-SEBLogContext
        Write-SEBLog
    #>
    [CmdletBinding()]
    param()

    $previousContext = $script:SEBLogContext
    $script:SEBLogContext = $null

    if ($previousContext) {
        Write-Verbose "Logger: Log context '$previousContext' cleared."
    }
    else {
        Write-Verbose "Logger: No active log context to clear."
    }
}
