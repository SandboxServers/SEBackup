function Mount-SEBShadowCopy {
    <#
    .SYNOPSIS
        Mounts a VSS shadow copy to a directory symlink on a remote Windows node.

    .DESCRIPTION
        Creates a directory symbolic link from the specified mount point to the
        VSS shadow copy device object on a remote Windows node. This makes the
        shadow copy's filesystem accessible via a standard directory path,
        enabling file copy operations for backups.

        CRITICAL: A trailing backslash is appended to the DeviceObject path
        before creating the symlink. This is required by Windows for VSS
        device object symlinks to function correctly.

        The parent directory of the mount point is created automatically if
        it does not exist. The symlink is created using cmd /c mklink /D.

        The operation is executed on the remote node via Invoke-Command.

    .PARAMETER DeviceObject
        The VSS device object path to mount. This is the DeviceObject property
        returned by New-SEBShadowCopy (e.g., "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1").

    .PARAMETER MountPoint
        The local directory path on the remote node where the shadow copy
        should be mounted (e.g., "C:\Temp\seb_20260227_120000").

    .PARAMETER Session
        An active PSSession to the remote Windows node. The session must have
        administrative privileges.

    .EXAMPLE
        $shadow = New-SEBShadowCopy -Volume 'C:\' -Session $session
        Mount-SEBShadowCopy -DeviceObject $shadow.DeviceObject -MountPoint 'C:\Temp\seb_snapshot' -Session $session
        # Shadow copy is now accessible at C:\Temp\seb_snapshot

    .EXAMPLE
        Mount-SEBShadowCopy -DeviceObject '\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1' -MountPoint 'D:\Backup\snapshot' -Session $session

    .OUTPUTS
        System.Boolean
        $true if the mount point was created successfully, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DeviceObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MountPoint,

        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    Write-Verbose "VSSManager: Mounting shadow copy to $MountPoint on $($Session.ComputerName)"

    try {
        # NON-IDEMPOTENT write (creates a directory symlink mount). -RetryCount 0 so a
        # transport drop after the mklink succeeds does NOT re-run -- the second attempt's
        # mklink would fail on the now-existing mount point and report a false failure. Route
        # through the wrapper for logging/reconnect; the block stays node-local.
        $result = Invoke-SEBRemoteCommand -Session $Session -RetryCount 0 -ScriptBlock {
            param($Device, $Mount)

            try {
                # Create parent directory if it does not exist
                $parentDir = Split-Path -Path $Mount -Parent
                if (-not (Test-Path -Path $parentDir -PathType Container)) {
                    New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
                }

                # Verify mount point does not already exist
                if (Test-Path -Path $Mount) {
                    return @{
                        Success = $false
                        Error   = "Mount point '$Mount' already exists"
                    }
                }

                # CRITICAL: Append trailing backslash to DeviceObject for VSS symlinks
                $devicePath = $Device.TrimEnd('\') + '\'

                # Create the directory symlink
                $output = cmd /c mklink /D "$Mount" "$devicePath" 2>&1
                $exitCode = $LASTEXITCODE

                if ($exitCode -ne 0) {
                    return @{
                        Success = $false
                        Error   = "mklink failed (exit code $exitCode): $output"
                    }
                }

                # Verify the symlink was created
                if (-not (Test-Path -Path $Mount)) {
                    return @{
                        Success = $false
                        Error   = "mklink reported success but mount point '$Mount' does not exist"
                    }
                }

                return @{
                    Success = $true
                    Error   = $null
                }
            }
            catch {
                return @{
                    Success = $false
                    Error   = $_.Exception.Message
                }
            }
        } -ArgumentList $DeviceObject, $MountPoint -ErrorAction Stop

        if ($result.Success) {
            Write-Verbose "VSSManager: Shadow copy mounted at $MountPoint on $($Session.ComputerName)"
            return $true
        }
        else {
            Write-Warning "VSSManager: Failed to mount shadow copy at $MountPoint on $($Session.ComputerName): $($result.Error)"
            return $false
        }
    }
    catch {
        Write-Warning "VSSManager: Error mounting shadow copy on $($Session.ComputerName): $($_.Exception.Message)"
        return $false
    }
}
