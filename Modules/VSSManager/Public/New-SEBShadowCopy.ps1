function New-SEBShadowCopy {
    <#
    .SYNOPSIS
        Creates a VSS shadow copy on a remote Windows node.

    .DESCRIPTION
        Creates a new Volume Shadow Copy Service (VSS) snapshot on the specified
        volume of a remote Windows node. The shadow copy provides a consistent,
        point-in-time view of the filesystem that can be mounted for backup
        operations without locking or interrupting the running application.

        The operation is executed on the remote node via Invoke-Command using
        the provided PSSession. The Win32_ShadowCopy WMI class is used to
        create the snapshot.

        Returns an object containing the ShadowID (for later removal),
        DeviceObject (for mounting), and the creation timestamp.

    .PARAMETER Volume
        The volume to create a shadow copy of, specified as a drive letter
        with trailing backslash (e.g., "C:\").

    .PARAMETER Session
        An active PSSession to the remote Windows node where the shadow copy
        should be created. The session must have administrative privileges.

    .EXAMPLE
        $session = New-PSSession -ComputerName 'Server01'
        $shadow = New-SEBShadowCopy -Volume 'C:\' -Session $session
        Write-Host "Shadow ID: $($shadow.ShadowID)"
        Write-Host "Device: $($shadow.DeviceObject)"

    .EXAMPLE
        $shadow = New-SEBShadowCopy -Volume 'D:\' -Session $remoteSession
        if ($shadow) {
            # Mount and use the shadow copy
        }

    .OUTPUTS
        PSCustomObject
        An object with the following properties:
        - ShadowID     [string]   : The unique identifier for the shadow copy.
        - DeviceObject [string]   : The device path for mounting the snapshot.
        - CreatedAt    [datetime] : The UTC timestamp when the snapshot was created.
        Returns $null if creation failed.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Volume,

        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    Write-Verbose "VSSManager: Creating shadow copy on $($Session.ComputerName) for volume $Volume"

    try {
        # Route through the wrapper for retry/logging/reconnect; the block stays node-local.
        $result = Invoke-SEBRemoteCommand -Session $Session -ScriptBlock {
            param($TargetVolume)

            try {
                $createResult = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{
                    Volume = $TargetVolume
                }

                if ($createResult.ReturnValue -ne 0) {
                    return @{
                        Success      = $false
                        Error        = "Win32_ShadowCopy Create returned error code: $($createResult.ReturnValue)"
                        ShadowID     = $null
                        DeviceObject = $null
                    }
                }

                $shadowId = $createResult.ShadowID

                # Retrieve the full shadow copy object to get the DeviceObject
                $shadow = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId }

                if (-not $shadow) {
                    return @{
                        Success      = $false
                        Error        = "Shadow copy was created (ID: $shadowId) but could not be retrieved"
                        ShadowID     = $shadowId
                        DeviceObject = $null
                    }
                }

                return @{
                    Success      = $true
                    Error        = $null
                    ShadowID     = $shadow.ID
                    DeviceObject = $shadow.DeviceObject
                }
            }
            catch {
                return @{
                    Success      = $false
                    Error        = $_.Exception.Message
                    ShadowID     = $null
                    DeviceObject = $null
                }
            }
        } -ArgumentList $Volume -ErrorAction Stop

        if ($result.Success) {
            $shadowInfo = [PSCustomObject]@{
                ShadowID     = $result.ShadowID
                DeviceObject = $result.DeviceObject
                CreatedAt    = [DateTime]::UtcNow
            }
            Write-Verbose "VSSManager: Shadow copy created - ID: $($shadowInfo.ShadowID), Device: $($shadowInfo.DeviceObject)"
            return $shadowInfo
        }
        else {
            Write-Warning "VSSManager: Failed to create shadow copy on $($Session.ComputerName): $($result.Error)"
            return $null
        }
    }
    catch {
        Write-Warning "VSSManager: Error creating shadow copy on $($Session.ComputerName): $($_.Exception.Message)"
        return $null
    }
}
