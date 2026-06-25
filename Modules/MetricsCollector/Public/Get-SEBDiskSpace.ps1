function Get-SEBDiskSpace {
    <#
    .SYNOPSIS
        Checks disk space across all three backup storage tiers.

    .DESCRIPTION
        Reports free and total disk space for the three tiers in the SEBackup storage
        hierarchy:

        1. Node Staging: temporary staging area on the game server node (checked via
           optional PSSession for remote nodes)
        2. CC Backup Root: the central controller's local backup storage
        3. NAS Path: the network-attached storage for long-term archive retention

        Each tier reports free bytes and total bytes. If a path is not configured or
        not reachable, the corresponding values are set to -1 to indicate unavailability.

    .PARAMETER BackupRoot
        The path to the central controller's backup root directory (cc_backup_root).

    .PARAMETER NASPath
        The UNC or local path to the NAS backup storage. If empty or not provided,
        NAS space is reported as -1 (unconfigured).

    .PARAMETER Session
        An optional PSSession to a remote game server node. When provided, the node
        staging disk space is queried via the remote session. When not provided, node
        staging space is reported as -1 (not available).

    .EXAMPLE
        Get-SEBDiskSpace -BackupRoot "C:\SEBackup\Backups" -NASPath "\\NAS\Backups"

    .EXAMPLE
        $session = New-SEBSession -NodeName "GameNode01"
        Get-SEBDiskSpace -BackupRoot "C:\SEBackup\Backups" -NASPath "\\NAS\Backups" -Session $session

    .OUTPUTS
        PSCustomObject
        An object with properties:
        - NodeStagingFreeBytes (long): free bytes on the node staging drive, or -1
        - NodeStagingTotalBytes (long): total bytes on the node staging drive, or -1
        - CCBackupFreeBytes (long): free bytes on the CC backup root drive
        - CCBackupTotalBytes (long): total bytes on the CC backup root drive
        - NASFreeBytes (long): free bytes on the NAS path, or -1
        - NASTotalBytes (long): total bytes on the NAS path, or -1

    .LINK
        Get-SEBHealthSummary
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot,

        [Parameter()]
        [string]$NASPath,

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $result = [PSCustomObject]@{
        NodeStagingFreeBytes  = [long]-1
        NodeStagingTotalBytes = [long]-1
        CCBackupFreeBytes     = [long]-1
        CCBackupTotalBytes    = [long]-1
        NASFreeBytes          = [long]-1
        NASTotalBytes         = [long]-1
    }

    # Helper script block to get drive space from a path
    $getDriveSpace = {
        param([string]$TargetPath)
        if ([string]::IsNullOrWhiteSpace($TargetPath)) {
            return @{ FreeBytes = -1; TotalBytes = -1 }
        }
        try {
            # Resolve to the drive root
            $driveRoot = [System.IO.Path]::GetPathRoot($TargetPath)
            if ([string]::IsNullOrWhiteSpace($driveRoot)) {
                return @{ FreeBytes = -1; TotalBytes = -1 }
            }
            $driveInfo = [System.IO.DriveInfo]::new($driveRoot)
            return @{
                FreeBytes  = $driveInfo.AvailableFreeSpace
                TotalBytes = $driveInfo.TotalSize
            }
        }
        catch {
            return @{ FreeBytes = -1; TotalBytes = -1 }
        }
    }

    # 1. Node Staging (via remote session if provided)
    if ($Session) {
        try {
            # Route through the wrapper for retry/logging/reconnect; the block stays node-local.
            $nodeSpace = Invoke-SEBRemoteCommand -Session $Session -ScriptBlock {
                try {
                    # Use the system drive as a proxy for node staging space
                    $sysDrive = [System.IO.DriveInfo]::new($env:SystemDrive)
                    return @{
                        FreeBytes  = $sysDrive.AvailableFreeSpace
                        TotalBytes = $sysDrive.TotalSize
                    }
                }
                catch {
                    return @{ FreeBytes = -1; TotalBytes = -1 }
                }
            } -ErrorAction Stop

            $result.NodeStagingFreeBytes = [long]$nodeSpace.FreeBytes
            $result.NodeStagingTotalBytes = [long]$nodeSpace.TotalBytes
        }
        catch {
            Write-Warning "Get-SEBDiskSpace: Failed to query node staging space via session: $_"
        }
    }

    # 2. CC Backup Root (local)
    try {
        $ccSpace = & $getDriveSpace -TargetPath $BackupRoot
        $result.CCBackupFreeBytes = [long]$ccSpace.FreeBytes
        $result.CCBackupTotalBytes = [long]$ccSpace.TotalBytes
    }
    catch {
        Write-Warning "Get-SEBDiskSpace: Failed to query CC backup root space: $_"
    }

    # 3. NAS Path
    if (-not [string]::IsNullOrWhiteSpace($NASPath)) {
        try {
            # For UNC paths, we cannot use DriveInfo directly.
            # Use Get-PSDrive or WMI/CIM depending on availability.
            if ($NASPath.StartsWith('\\')) {
                # UNC path: try to query via .NET
                # Create a temporary PSDrive mapped to the UNC path to check space
                $testDriveCreated = $false
                $tempDriveName = 'SEBNASCheck'

                try {
                    # Remove any existing temp drive
                    Remove-PSDrive -Name $tempDriveName -ErrorAction SilentlyContinue

                    New-PSDrive -Name $tempDriveName -PSProvider FileSystem -Root $NASPath -ErrorAction Stop | Out-Null
                    $testDriveCreated = $true

                    $psDrive = Get-PSDrive -Name $tempDriveName -ErrorAction Stop
                    if ($null -ne $psDrive.Free) {
                        $result.NASFreeBytes = [long]$psDrive.Free
                        # PSDrive does not always expose total; calculate if Used is available
                        if ($null -ne $psDrive.Used) {
                            $result.NASTotalBytes = [long]($psDrive.Free + $psDrive.Used)
                        }
                    }
                }
                finally {
                    if ($testDriveCreated) {
                        Remove-PSDrive -Name $tempDriveName -ErrorAction SilentlyContinue
                    }
                }
            }
            else {
                # Local/mapped drive path
                $nasSpace = & $getDriveSpace -TargetPath $NASPath
                $result.NASFreeBytes = [long]$nasSpace.FreeBytes
                $result.NASTotalBytes = [long]$nasSpace.TotalBytes
            }
        }
        catch {
            Write-Warning "Get-SEBDiskSpace: Failed to query NAS space at '$NASPath': $_"
        }
    }

    return $result
}
