function Test-SEBSessionExists {
    <#
    .SYNOPSIS
        Tests whether an open cached PSSession already exists for a node.

    .DESCRIPTION
        Reports whether the module-scoped session cache (the same cache used by
        New-SEBSession and Remove-SEBSession) already holds an OPEN session for
        the specified node.

        This lets a caller determine session OWNERSHIP before calling
        New-SEBSession: if a session already exists, New-SEBSession will return
        that cached session rather than create a new one, so the caller must NOT
        tear it down (it belongs to whoever created it). If no session exists,
        New-SEBSession creates one and the caller owns it.

        The "open" determination mirrors New-SEBSession exactly: a cached session
        is only considered to exist here if it is present AND in the Opened state.
        A cached-but-broken/closed session returns $false, because New-SEBSession
        would discard and recreate it (making the caller the owner of the new one).

    .PARAMETER NodeName
        The name of the node to check for a cached session. This is the same key
        New-SEBSession and Remove-SEBSession use.

    .EXAMPLE
        $preexisted = Test-SEBSessionExists -NodeName 'GameServer01'
        $session = New-SEBSession -NodeName 'GameServer01'
        try { Invoke-Command -Session $session -ScriptBlock { ... } }
        finally { if (-not $preexisted) { Remove-SEBSession -NodeName 'GameServer01' } }
        # Only tears down the session if this caller created it.

    .OUTPUTS
        System.Boolean
        $true if an open cached session exists for the node, otherwise $false.
    #>
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName
    )

    if (-not $script:SEBSessions.ContainsKey($NodeName)) {
        return $false
    }

    $existingSession = $script:SEBSessions[$NodeName]
    return ($existingSession.State -eq [System.Management.Automation.Runspaces.RunspaceState]::Opened)
}
