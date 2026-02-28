function Remove-SEBSession {
    <#
    .SYNOPSIS
        Removes and disposes of cached PSSession(s) for SEBackup nodes.

    .DESCRIPTION
        Closes and removes one or all cached PSSessions that were created by
        New-SEBSession. The session is removed from the module-scoped cache
        and disposed via Remove-PSSession.

        Use -NodeName to remove the session for a specific node, or -All to
        remove every cached session.

    .PARAMETER NodeName
        The name of the specific node whose session should be removed.

    .PARAMETER All
        When specified, removes all cached sessions for every node.

    .EXAMPLE
        Remove-SEBSession -NodeName "GameServer01"
        # Closes and removes the session for GameServer01.

    .EXAMPLE
        Remove-SEBSession -All
        # Closes and removes all cached sessions.

    .EXAMPLE
        try { Invoke-SEBRemoteCommand ... }
        finally { Remove-SEBSession -NodeName "GameServer01" }
        # Ensures the session is cleaned up even if an error occurs.

    .OUTPUTS
        None.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'ByName')]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter(Mandatory, ParameterSetName = 'All')]
        [switch]$All
    )

    if ($All) {
        $nodeNames = @($script:SEBSessions.Keys)
        foreach ($name in $nodeNames) {
            $session = $script:SEBSessions[$name]
            try {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                Write-Verbose "Removed session for node '$name' (ID: $($session.Id))"
            }
            catch {
                Write-Warning "Failed to cleanly remove session for node '$name': $_"
            }
            $script:SEBSessions.Remove($name)
        }

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Removed all cached PSSessions ($($nodeNames.Count) total)" -Level INFO
        }
        Write-Verbose "All cached sessions removed ($($nodeNames.Count) total)."
    }
    else {
        if (-not $script:SEBSessions.ContainsKey($NodeName)) {
            Write-Verbose "No cached session found for node '$NodeName'. Nothing to remove."
            return
        }

        $session = $script:SEBSessions[$NodeName]
        try {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            Write-Verbose "Removed session for node '$NodeName' (ID: $($session.Id))"
        }
        catch {
            Write-Warning "Failed to cleanly remove session for node '$NodeName': $_"
        }
        $script:SEBSessions.Remove($NodeName)

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Removed PSSession for node '$NodeName'" -Level INFO
        }
    }
}
