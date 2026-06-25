function Dismount-SEBShadowCopy {
    <#
    .SYNOPSIS
        Removes a VSS shadow copy mount point symlink from a remote Windows node.

    .DESCRIPTION
        Removes the directory symbolic link created by Mount-SEBShadowCopy on
        a remote Windows node. Uses cmd /c rd to remove the symlink without
        affecting the underlying shadow copy data.

        This function should be called before Remove-SEBShadowCopy to ensure
        the mount point is cleaned up. The Invoke-SEBWithShadowCopy wrapper
        handles this automatically in its finally block.

        The operation is executed on the remote node via Invoke-Command.

    .PARAMETER MountPoint
        The path to the directory symlink to remove (e.g.,
        "C:\Temp\seb_20260227_120000").

    .PARAMETER Session
        An active PSSession to the remote Windows node. The session must have
        administrative privileges.

    .EXAMPLE
        Dismount-SEBShadowCopy -MountPoint 'C:\Temp\seb_snapshot' -Session $session
        # Removes the symlink, shadow copy data is unaffected

    .EXAMPLE
        # Full lifecycle
        Mount-SEBShadowCopy -DeviceObject $shadow.DeviceObject -MountPoint $mp -Session $session
        # ... copy files from $mp ...
        Dismount-SEBShadowCopy -MountPoint $mp -Session $session
        Remove-SEBShadowCopy -ShadowID $shadow.ShadowID -Session $session

    .OUTPUTS
        System.Boolean
        $true if the mount point was removed successfully, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MountPoint,

        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    Write-Verbose "VSSManager: Dismounting shadow copy at $MountPoint on $($Session.ComputerName)"

    try {
        # VSS lifecycle write (removes the mount-point symlink), run from cleanup. -RetryCount 0:
        # this is a single-shot teardown -- a transport drop after the symlink is removed must
        # not trigger a retry+backoff that buys nothing (the block already treats a missing
        # mount point as success). Route through the wrapper for logging/reconnect; the block
        # stays node-local.
        $result = Invoke-SEBRemoteCommand -Session $Session -RetryCount 0 -ScriptBlock {
            param($Mount)

            try {
                # Check if the mount point exists
                if (-not (Test-Path -Path $Mount)) {
                    return @{
                        Success = $true
                        Error   = $null
                        Message = "Mount point '$Mount' does not exist - nothing to remove"
                    }
                }

                # Remove the directory symlink using rd (does not recurse into target)
                $output = cmd /c rd "$Mount" 2>&1
                $exitCode = $LASTEXITCODE

                if ($exitCode -ne 0) {
                    return @{
                        Success = $false
                        Error   = "rd failed (exit code $exitCode): $output"
                        Message = $null
                    }
                }

                # Verify removal
                if (Test-Path -Path $Mount) {
                    return @{
                        Success = $false
                        Error   = "rd reported success but mount point '$Mount' still exists"
                        Message = $null
                    }
                }

                return @{
                    Success = $true
                    Error   = $null
                    Message = "Mount point removed successfully"
                }
            }
            catch {
                return @{
                    Success = $false
                    Error   = $_.Exception.Message
                    Message = $null
                }
            }
        } -ArgumentList $MountPoint -ErrorAction Stop

        if ($result.Success) {
            Write-Verbose "VSSManager: Mount point $MountPoint removed on $($Session.ComputerName)"
            return $true
        }
        else {
            Write-Warning "VSSManager: Failed to dismount $MountPoint on $($Session.ComputerName): $($result.Error)"
            return $false
        }
    }
    catch {
        Write-Warning "VSSManager: Error dismounting $MountPoint on $($Session.ComputerName): $($_.Exception.Message)"
        return $false
    }
}
