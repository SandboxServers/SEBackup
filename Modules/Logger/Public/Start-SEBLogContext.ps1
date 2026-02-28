function Start-SEBLogContext {
    <#
    .SYNOPSIS
        Sets a context prefix that is automatically added to all subsequent log entries.

    .DESCRIPTION
        Establishes a logging context that is automatically prepended to every log
        entry written by Write-SEBLog until the context is cleared with
        Stop-SEBLogContext. This is useful for grouping related log entries
        together under a common identifier, such as a server instance name or
        a specific backup operation.

        The context is stored in the module-scoped variable $script:SEBLogContext.
        If a context is already active, calling Start-SEBLogContext again will
        replace it with the new context value.

        When a context is active, log entries appear as:
            [timestamp] [LEVEL] [ContextName] Message

        The -Context parameter on Write-SEBLog takes precedence over the session
        context if both are provided.

    .PARAMETER Context
        The context identifier string to use as a prefix for log entries.
        Typically a server instance name, operation name, or module name.

    .EXAMPLE
        Start-SEBLogContext -Context "PvPArena"
        Write-SEBLog -Message "Starting backup" -Level INFO
        # Logs: [2026-02-27 14:30:00.000] [INFO ] [PvPArena] Starting backup

    .EXAMPLE
        Start-SEBLogContext -Context "MaintenanceWindow"
        Write-SEBLog -Message "Stopping Torch server" -Level INFO
        Write-SEBLog -Message "Creating VSS snapshot" -Level INFO
        Stop-SEBLogContext
        # Both log entries include [MaintenanceWindow] prefix.

    .EXAMPLE
        Start-SEBLogContext -Context "Node-East"
        # All subsequent logs are tagged with [Node-East] until cleared.

    .OUTPUTS
        None

    .LINK
        Stop-SEBLogContext
        Write-SEBLog
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Context
    )

    $script:SEBLogContext = $Context
    Write-Verbose "Logger: Log context set to '$Context'."
}
