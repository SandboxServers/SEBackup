function Test-SEBSessionAlive {
    <#
    .SYNOPSIS
        Liveness predicate for "this SEBackup PSSession still EXISTS -- do not destroy it".

    .DESCRIPTION
        Returns $true when a session is established and has NOT been torn down, even
        if it is momentarily mid-command. This is deliberately WEAKER than
        Test-SEBSessionUsable:

        - Test-SEBSessionUsable  = State=Opened AND Availability=Available
          "can accept a NEW top-level command RIGHT NOW". Used by the wrapper's
          execution gate (Busy => wait; terminal => reconnect).
        - Test-SEBSessionAlive   = State=Opened AND Availability != None
          "the handle is live; a Busy/nested/debug runspace is in use, not dead".
          Used to decide whether a cached session may be REUSED rather than torn
          down and rebuilt.

        Why the two concepts must differ (issue #22 re-review): a session shared as
        the per-node cache entry can be Busy because ANOTHER caller is mid-command
        on it. Treating Busy as "not usable" and therefore removing/recreating it
        would kill that in-flight command and re-key the cache while it is in use.
        New-SEBSession (cache reuse) and Test-SEBSessionExists (ownership probe)
        must NOT do that -- they only care that the session is alive, so a Busy
        session counts as alive and is left intact.

        Availability semantics (confirmed against the .NET docs for
        System.Management.Automation.Runspaces.RunspaceAvailability):
        - None (0)  = "the Runspace has not been in the Opened state" -- i.e. dead,
          never-opened, or torn down. The ONLY availability value that means the
          handle cannot be relied upon to exist.
        - Available (1), AvailableForNestedCommand (2), Busy (3), RemoteDebug (4)
          all imply the runspace is established and present; they differ only in
          whether it can take a new top-level command, which is the USABLE concern,
          not the ALIVE concern.
        A Broken/Closed/Disconnected runspace reports State != Opened (and
        Availability None), so requiring State=Opened already excludes those.

    .PARAMETER Session
        The PSSession to test.

    .OUTPUTS
        System.Boolean
        $true if the session is Opened and its Availability is not None;
        otherwise $false.
    #>
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $isOpen = $Session.State -eq [System.Management.Automation.Runspaces.RunspaceState]::Opened
    $isTornDown = $Session.Availability -eq [System.Management.Automation.Runspaces.RunspaceAvailability]::None
    return ($isOpen -and -not $isTornDown)
}
