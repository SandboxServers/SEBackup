function Clear-SEBOrphanShadowCopies {
    <#
    .SYNOPSIS
        Removes orphaned VSS shadow copies and mount points from a remote node.

    .DESCRIPTION
        Cleanup function that finds and removes any orphaned VSS shadow copy
        mount points and their associated shadow copies that may have been
        left behind by previous failed backup runs.

        The function performs two cleanup operations:

        1. Mount point cleanup: Scans the MountBase directory for symlinks
           matching the "seb_*" naming pattern used by Invoke-SEBWithShadowCopy.
           Each matching symlink is removed using cmd /c rd.

        2. Shadow copy cleanup: Checks all existing Win32_ShadowCopy instances
           to identify any that may have been left orphaned. Shadow copies
           created by SEBackup are identified by checking if they were created
           within the scope of a seb_* mount point.

        This function is safe to run at any time and is recommended as a
        pre-backup or scheduled maintenance step.

    .PARAMETER Session
        An active PSSession to the remote Windows node to clean up. The
        session must have administrative privileges.

    .PARAMETER MountBase
        The base directory on the remote node where SEBackup mount points
        are created (e.g., "C:\Temp\SEBMounts"). The function will search
        for seb_* subdirectories within this path.

    .EXAMPLE
        Clear-SEBOrphanShadowCopies -Session $session -MountBase 'C:\Temp\SEBMounts'
        # Removes any orphaned seb_* symlinks and associated shadow copies

    .EXAMPLE
        # Run as pre-backup maintenance
        Clear-SEBOrphanShadowCopies -Session $session -MountBase 'C:\Temp\SEBMounts' -Verbose
        $result = Invoke-SEBWithShadowCopy -Volume 'C:\' -MountBase 'C:\Temp\SEBMounts' -Session $session -ScriptBlock { ... }

    .OUTPUTS
        PSCustomObject
        An object with the following properties:
        - MountPointsRemoved  [int]    : Number of orphaned mount points removed.
        - ShadowCopiesRemoved [int]    : Number of orphaned shadow copies removed.
        - Errors              [string[]] : Any errors encountered during cleanup.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MountBase
    )

    Write-Verbose "VSSManager: Scanning for orphaned shadow copies on $($Session.ComputerName) in $MountBase"

    try {
        $result = Invoke-Command -Session $Session -ScriptBlock {
            param($BasePath)

            $mountsRemoved = 0
            $shadowsRemoved = 0
            $errors = [System.Collections.Generic.List[string]]::new()

            # Step 1: Clean up orphaned mount point symlinks
            if (Test-Path -Path $BasePath -PathType Container) {
                $orphanedMounts = Get-ChildItem -Path $BasePath -Directory -Filter 'seb_*' -ErrorAction SilentlyContinue

                foreach ($mount in $orphanedMounts) {
                    try {
                        # Check if this is a symlink (ReparsePoint)
                        $isSymlink = ($mount.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

                        if ($isSymlink) {
                            $output = cmd /c rd "$($mount.FullName)" 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                $mountsRemoved++
                            }
                            else {
                                $errors.Add("Failed to remove mount point '$($mount.FullName)': $output")
                            }
                        }
                        else {
                            # Not a symlink - might be a leftover directory, remove it if empty
                            $childCount = @(Get-ChildItem -Path $mount.FullName -Force -ErrorAction SilentlyContinue).Count
                            if ($childCount -eq 0) {
                                Remove-Item -Path $mount.FullName -Force -ErrorAction Stop
                                $mountsRemoved++
                            }
                            else {
                                $errors.Add("Directory '$($mount.FullName)' is not a symlink and is not empty - skipping")
                            }
                        }
                    }
                    catch {
                        $errors.Add("Error removing mount point '$($mount.FullName)': $($_.Exception.Message)")
                    }
                }
            }

            # Step 2: Check for orphaned shadow copies
            # We look for shadow copies that have no associated mount point
            # and were likely created by SEBackup (we cannot definitively identify
            # these, but we can check for ones that are no longer mounted)
            try {
                $allShadows = Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue

                foreach ($shadow in $allShadows) {
                    # Check if any seb_* symlink still points to this shadow's device
                    $deviceObj = $shadow.DeviceObject
                    $isOrphaned = $false

                    # If we found and removed mount points above, check if this shadow
                    # was associated with one of them. We check by looking for symlinks
                    # that point to this device object's path.
                    if ($orphanedMounts) {
                        foreach ($mount in $orphanedMounts) {
                            # Try to resolve symlink target (may not work if already removed)
                            # Instead, check if device was created around the same time as
                            # the mount point's timestamp
                            $mountTimestamp = $mount.Name -replace '^seb_', ''
                            if ($mountTimestamp -match '^\d{8}_\d{6}$') {
                                try {
                                    $mountTime = [DateTime]::ParseExact($mountTimestamp, 'yyyyMMdd_HHmmss', $null)
                                    $shadowTime = $shadow.InstallDate
                                    # If shadow was created within 60 seconds of mount point, likely ours
                                    $timeDiff = [Math]::Abs(($shadowTime - $mountTime).TotalSeconds)
                                    if ($timeDiff -lt 60) {
                                        $isOrphaned = $true
                                        break
                                    }
                                }
                                catch {
                                    # Timestamp parsing failed, skip
                                }
                            }
                        }
                    }

                    if ($isOrphaned) {
                        try {
                            $shadow | Remove-CimInstance
                            $shadowsRemoved++
                        }
                        catch {
                            $errors.Add("Failed to remove orphaned shadow copy $($shadow.ID): $($_.Exception.Message)")
                        }
                    }
                }
            }
            catch {
                $errors.Add("Error querying shadow copies: $($_.Exception.Message)")
            }

            return @{
                MountPointsRemoved  = $mountsRemoved
                ShadowCopiesRemoved = $shadowsRemoved
                Errors              = [string[]]$errors.ToArray()
            }
        } -ArgumentList $MountBase -ErrorAction Stop

        $cleanupResult = [PSCustomObject]@{
            MountPointsRemoved  = $result.MountPointsRemoved
            ShadowCopiesRemoved = $result.ShadowCopiesRemoved
            Errors              = $result.Errors
        }

        Write-Verbose "VSSManager: Cleanup on $($Session.ComputerName) - Mounts removed: $($cleanupResult.MountPointsRemoved), Shadows removed: $($cleanupResult.ShadowCopiesRemoved)"

        if ($cleanupResult.Errors.Count -gt 0) {
            foreach ($err in $cleanupResult.Errors) {
                Write-Warning "VSSManager: Cleanup issue on $($Session.ComputerName): $err"
            }
        }

        return $cleanupResult
    }
    catch {
        Write-Warning "VSSManager: Error during orphan cleanup on $($Session.ComputerName): $($_.Exception.Message)"
        return [PSCustomObject]@{
            MountPointsRemoved  = 0
            ShadowCopiesRemoved = 0
            Errors              = @($_.Exception.Message)
        }
    }
}
