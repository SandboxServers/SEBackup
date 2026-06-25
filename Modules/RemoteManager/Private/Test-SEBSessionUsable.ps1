function Test-SEBSessionUsable {
    <#
    .SYNOPSIS
        The single liveness predicate for a SEBackup PSSession.

    .DESCRIPTION
        Returns $true only when a session is ready to accept a new command RIGHT
        NOW: it is established (State=Opened) AND its runspace is idle
        (Availability=Available).

        This is the ONE source of truth for "is this session usable" and is
        called from New-SEBSession (cache hit), Test-SEBSessionExists (ownership
        probe), and Invoke-SEBRemoteCommand (pre-execution health gate). Keeping
        the predicate in one place removes the drift that used to exist between
        three hand-copied conditions.

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
