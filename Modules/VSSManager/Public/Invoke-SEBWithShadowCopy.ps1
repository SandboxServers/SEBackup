function Invoke-SEBWithShadowCopy {
    <#
    .SYNOPSIS
        Executes a script block within a VSS shadow copy lifecycle on a remote node.

    .DESCRIPTION
        The primary wrapper function for performing operations against a
        consistent VSS snapshot. This function manages the full shadow copy
        lifecycle:

        1. Creates a new VSS shadow copy on the specified volume.
        2. Mounts the shadow copy to a timestamped directory under MountBase.
        3. Executes the provided script block on the remote node, passing the
           mount point path as the first argument followed by any additional
           ArgumentList values.
        4. Cleans up by dismounting and removing the shadow copy in a finally
           block, ensuring cleanup occurs even if the script block fails.

        The mount point directory name follows the pattern
        "seb_yyyyMMdd_HHmmss" to avoid collisions and aid in identifying
        orphaned mount points from failed runs.

    .PARAMETER Volume
        The volume to snapshot (e.g., "C:\").

    .PARAMETER MountBase
        The base directory on the remote node under which the timestamped
        shadow copy mount point will be created (e.g., "C:\Temp\SEBMounts").

    .PARAMETER Session
        An active PSSession to the remote Windows node. The session must have
        administrative privileges for VSS operations.

    .PARAMETER ScriptBlock
        The script block to execute on the remote node. The mount point path
        is passed as the first argument ($args[0] or the first param).
        Additional arguments from -ArgumentList follow.

    .PARAMETER ArgumentList
        Optional additional arguments to pass to the script block after the
        mount point path.

    .EXAMPLE
        $result = Invoke-SEBWithShadowCopy -Volume 'C:\' -MountBase 'C:\Temp\SEBMounts' -Session $session -ScriptBlock {
            param($MountPoint)
            # Copy files from the consistent snapshot
            Copy-Item -Path "$MountPoint\GameData\*" -Destination 'D:\Backups\' -Recurse
            return @{ FilesCopied = $true }
        }

    .EXAMPLE
        $result = Invoke-SEBWithShadowCopy -Volume 'D:\' -MountBase 'D:\Temp' -Session $session -ScriptBlock {
            param($MountPoint, $DestPath)
            Get-ChildItem -Path $MountPoint -Recurse | Measure-Object -Property Length -Sum
        } -ArgumentList @('D:\BackupDest')

    .OUTPUTS
        System.Object
        Whatever the provided ScriptBlock returns, or $null if the shadow
        copy lifecycle failed before the script block could execute.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Volume,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MountBase,

        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [object[]]$ArgumentList
    )

    $shadow = $null
    $mountPoint = $null
    $mounted = $false

    # This function takes $Session BY VALUE, but its VSS sub-calls (New/Mount/Dismount/Remove)
    # route through Invoke-SEBRemoteCommand, which on a dead handle reconnects into the module
    # cache WITHOUT writing back into this local $Session. The central world-capture below and
    # the finally cleanup are raw Invoke-Command on $Session, so they would run on a stale handle
    # after such a reconnect. Refresh $Session from the cache (a HIT returns the live session;
    # after any reconnect the cache holds the live handle) after each sub-call, keyed off the
    # node parsed from the session Name. If the session was not created by New-SEBSession (no
    # 'SEBackup-<node>' name -> no cache entry), refresh is a no-op and we keep the caller's handle.
    #
    # Each refresh is wrapped in Resolve-SessionFromCache, which is NON-THROWING: New-SEBSession
    # can throw on a cache miss whose recreate fails (the very failure that just killed the
    # capture), and an unguarded throw here -- especially in the finally -- would skip the
    # Dismount/Remove cleanup and LEAK the mounted snapshot + VSS shadow copy. On any refresh
    # failure we keep the existing (possibly stale) handle; the Dismount/Remove sub-calls route
    # through Invoke-SEBRemoteCommand and self-heal/reconnect, or fail best-effort with a warning.
    # New-SEBSession itself pins the real host (it remembers each node's connection target), so a
    # NodeConfig-less refresh here still rebuilds to the pinned IP/FQDN, never the bare alias.
    $cacheNode = if ($Session.Name -match '^SEBackup-(.+)$') { $Matches[1] } else { $null }

    function Resolve-SessionFromCache {
        # Best-effort refresh of $Session from the module cache. Returns the live session on
        # success, or the current $Session unchanged if there is no cache node or the refresh
        # throws. Never propagates an exception to the caller.
        param($Current, $Node)
        if (-not $Node) { return $Current }
        try {
            $live = New-SEBSession -NodeName $Node
            if ($live) { return $live }
        }
        catch {
            Write-Warning "VSSManager: could not refresh session for '$Node' from cache; using existing handle. $_"
        }
        return $Current
    }

    try {
        # Step 1: Create the shadow copy
        Write-Verbose "VSSManager: Starting shadow copy lifecycle on $($Session.ComputerName) for volume $Volume"
        $shadow = New-SEBShadowCopy -Volume $Volume -Session $Session

        if ($null -eq $shadow) {
            Write-Error "VSSManager: Failed to create shadow copy on $($Session.ComputerName) for volume $Volume"
            return $null
        }
        # Refresh in case the create reconnected the cached session (non-throwing).
        $Session = Resolve-SessionFromCache -Current $Session -Node $cacheNode

        # Step 2: Mount the shadow copy with a timestamped directory name
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $mountPoint = Join-Path -Path $MountBase -ChildPath "seb_$timestamp"

        $mountSuccess = Mount-SEBShadowCopy -DeviceObject $shadow.DeviceObject -MountPoint $mountPoint -Session $Session

        if (-not $mountSuccess) {
            Write-Error "VSSManager: Failed to mount shadow copy at $mountPoint on $($Session.ComputerName)"
            return $null
        }
        # Refresh in case the mount reconnected the cached session, so the raw capture below
        # (and the finally cleanup) use the live handle (non-throwing).
        $Session = Resolve-SessionFromCache -Current $Session -Node $cacheNode

        $mounted = $true
        Write-Verbose "VSSManager: Shadow copy mounted at $mountPoint, executing script block"

        # Step 3: Execute the user's script block with mount point as first argument
        $fullArgumentList = @($mountPoint)
        if ($PSBoundParameters.ContainsKey('ArgumentList') -and $null -ne $ArgumentList) {
            $fullArgumentList += $ArgumentList
        }

        # Raw Invoke-Command (not Invoke-SEBRemoteCommand): this function is itself the node-remoting
        # wrapper for VSS-scoped work (it is one of the contract test's $remoteWrappers). Nesting it
        # inside Invoke-SEBRemoteCommand would double the retry/backoff and could re-run the caller's
        # block mid-shadow-copy on a retry. The session is created and owned by the caller.
        $result = Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $fullArgumentList

        return $result
    }
    finally {
        # Step 4: Clean up - dismount and remove shadow copy regardless of outcome.
        # Refresh the handle from the cache first: the script block above (or an earlier sub-call)
        # may have left $Session stale via a cache-only reconnect, and the cleanup sub-calls take
        # the session by value -- using the live handle avoids a failed teardown that leaks a
        # mounted snapshot. This refresh is NON-THROWING (Resolve-SessionFromCache): if New-SEBSession
        # throws here (e.g. the node is unreachable -- the same failure that killed the capture), we
        # MUST still proceed to Dismount/Remove rather than let the throw skip cleanup and leak the
        # snapshot + mount. On failure we fall through with the existing handle; the sub-calls
        # self-heal via Invoke-SEBRemoteCommand or fail best-effort.
        $Session = Resolve-SessionFromCache -Current $Session -Node $cacheNode

        # Dismount if we successfully mounted
        if ($mounted -and $mountPoint) {
            Write-Verbose "VSSManager: Cleaning up - dismounting $mountPoint"
            $dismountResult = Dismount-SEBShadowCopy -MountPoint $mountPoint -Session $Session
            if (-not $dismountResult) {
                Write-Warning "VSSManager: Cleanup warning - failed to dismount $mountPoint on $($Session.ComputerName)"
            }
        }

        # Remove the shadow copy if we successfully created one
        if ($shadow -and $shadow.ShadowID) {
            Write-Verbose "VSSManager: Cleaning up - removing shadow copy $($shadow.ShadowID)"
            $removeResult = Remove-SEBShadowCopy -ShadowID $shadow.ShadowID -Session $Session
            if (-not $removeResult) {
                Write-Warning "VSSManager: Cleanup warning - failed to remove shadow copy $($shadow.ShadowID) on $($Session.ComputerName)"
            }
        }
    }
}
