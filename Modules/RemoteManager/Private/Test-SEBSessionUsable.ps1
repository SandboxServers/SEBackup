function Test-SEBSessionUsable {
    <#
    .SYNOPSIS
        "Can this SEBackup PSSession accept a command RIGHT NOW" predicate.

    .DESCRIPTION
        Returns $true only when a session is ready to accept a new top-level
        command RIGHT NOW: it is established (State=Opened) AND its runspace is idle
        (Availability=Available).

        This is the "usable now" half of the session-liveness split. It is the ONE
        source of truth for the WRAPPER's execution gate (Invoke-SEBRemoteCommand):
        a session that is not usable is either Busy-but-Opened (wait briefly, never
        tear down) or terminal (reconnect once). Keeping this gate in one place
        removes the drift that used to exist between hand-copied conditions.

        Do NOT use this predicate to decide whether a cached session "exists" or may
        be reused -- that is the ALIVE concern (Test-SEBSessionAlive: State=Opened
        AND Availability != None), which counts a Busy session as alive so a shared
        in-use per-node session is not destroyed and re-keyed. New-SEBSession (cache
        reuse) and Test-SEBSessionExists (ownership probe) use Test-SEBSessionAlive;
        only Invoke-SEBRemoteCommand uses this stricter predicate.

        Why both State AND Availability (confirmed against the .NET docs for
        System.Management.Automation.Runspaces):
        - RunspaceState.Opened (2) means the runspace is established and valid.
          Any other state (Broken, Closed, Disconnected, Opening, ...) cannot run
          a command and must be rebuilt.
        - RunspaceAvailability.Available (1) means the runspace is idle and can
          accept a command. Availability=None (0) means it is "not in the Opened
          state"; Busy (3) means it is mid-command; AvailableForNestedCommand (2)
          and RemoteDebug (4) are nested/debug edges. None of those can take a new
          top-level command, so only Available counts as usable.

    .PARAMETER Session
        The PSSession to test.

    .OUTPUTS
        System.Boolean
        $true if the session is Opened and Available; otherwise $false.
    #>
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $isOpen = $Session.State -eq [System.Management.Automation.Runspaces.RunspaceState]::Opened
    $isAvailable = $Session.Availability -eq [System.Management.Automation.Runspaces.RunspaceAvailability]::Available
    return ($isOpen -and $isAvailable)
}
