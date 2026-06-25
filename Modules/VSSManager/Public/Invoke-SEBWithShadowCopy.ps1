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

    try {
        # Step 1: Create the shadow copy
        Write-Verbose "VSSManager: Starting shadow copy lifecycle on $($Session.ComputerName) for volume $Volume"
        $shadow = New-SEBShadowCopy -Volume $Volume -Session $Session

        if ($null -eq $shadow) {
            Write-Error "VSSManager: Failed to create shadow copy on $($Session.ComputerName) for volume $Volume"
            return $null
        }

        # Step 2: Mount the shadow copy with a timestamped directory name
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $mountPoint = Join-Path -Path $MountBase -ChildPath "seb_$timestamp"

        $mountSuccess = Mount-SEBShadowCopy -DeviceObject $shadow.DeviceObject -MountPoint $mountPoint -Session $Session

        if (-not $mountSuccess) {
            Write-Error "VSSManager: Failed to mount shadow copy at $mountPoint on $($Session.ComputerName)"
            return $null
        }

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
        # Step 4: Clean up - dismount and remove shadow copy regardless of outcome

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
