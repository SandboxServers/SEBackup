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

        The "already exists" determination uses Test-SEBSessionAlive (present AND
        State=Opened AND Availability != None) -- the SAME predicate New-SEBSession
        uses to decide cache reuse, so the two agree on what counts as a
        pre-existing session. A session that is Busy (Availability=Busy, because
        another caller is mid-command on the shared per-node handle) is ALIVE and
        returns $true: New-SEBSession would reuse it, so the probing caller must
        treat it as pre-existing and NOT take ownership / tear it down. Only a
        genuinely dead/never-opened entry (which New-SEBSession would discard and
        recreate) returns $false.

        Note this is intentionally broader than Test-SEBSessionUsable ("can accept
        a command NOW", State=Opened AND Availability=Available), which is the
        wrapper's execution gate, not an ownership/existence probe.

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

    return (Test-SEBSessionAlive -Session $script:SEBSessions[$NodeName])
}
