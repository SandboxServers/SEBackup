function Test-SEBPreFlight {
    <#
    .SYNOPSIS
        Runs all pre-flight checks before a backup operation.

    .DESCRIPTION
        Validates that all prerequisites for a backup are met before proceeding.
        Checks include:

        - Disk space on the remote node staging directory (via Invoke-Command)
        - Disk space on the C&C backup root directory
        - Disk space on the NAS path (if configured and accessible)
        - World save folder exists on the remote node with a Sandbox.sbc file
        - SMB share is accessible from the C&C machine

        Returns a result object indicating whether all checks passed along with
        details of any failures.

    .PARAMETER Session
        An active PSSession connected to the target compute node.

    .PARAMETER NodeConfig
        The node configuration hashtable.

    .PARAMETER InstanceConfig
        The instance configuration hashtable.

    .PARAMETER GlobalConfig
        The global configuration hashtable.

    .PARAMETER MinDiskSpaceGB
        The minimum free disk space in GB required on each volume. Defaults to 5.

    .EXAMPLE
        $result = Test-SEBPreFlight -Session $session -NodeConfig $nodeConfig `
            -InstanceConfig $instanceConfig -GlobalConfig $globalConfig
        if (-not $result.Passed) {
            $result.Failures | ForEach-Object { Write-Error $_ }
        }

    .OUTPUTS
        PSCustomObject
        An object with properties: Passed (bool), Failures (string[]),
        Warnings (string[]), DiskSpaceNode (hashtable), DiskSpaceCC (hashtable),
        DiskSpaceNAS (hashtable or null).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [hashtable]$NodeConfig,

        [Parameter(Mandatory)]
        [hashtable]$InstanceConfig,

        [Parameter(Mandatory)]
        [hashtable]$GlobalConfig,

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$MinDiskSpaceGB = 5
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $diskSpaceNode = $null
    $diskSpaceCC = $null
    $diskSpaceNAS = $null

    $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue
    $instanceName = $InstanceConfig['_InstanceName']

    # --- Check 1: Node staging disk space ---
    try {
        $nodeStagingPath = if ($InstanceConfig.ContainsKey('staging_path')) {
            $InstanceConfig['staging_path']
        }
        else {
            'C:\SEBackup\staging'
        }

        $diskSpaceNode = Invoke-SEBRemoteCommand -Session $Session -ScriptBlock {
            param($stagingPath)
            $driveLetter = (Split-Path -Path $stagingPath -Qualifier).TrimEnd(':')
            $drive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
            @{
                DriveLetter = $driveLetter
                FreeGB      = [math]::Round($drive.Free / 1GB, 2)
                UsedGB      = [math]::Round($drive.Used / 1GB, 2)
                TotalGB     = [math]::Round(($drive.Free + $drive.Used) / 1GB, 2)
            }
        } -ArgumentList $nodeStagingPath -ErrorAction Stop

        if ($diskSpaceNode.FreeGB -lt $MinDiskSpaceGB) {
            $failures.Add("Node staging disk space is critically low: $($diskSpaceNode.FreeGB) GB free on drive $($diskSpaceNode.DriveLetter): (minimum: ${MinDiskSpaceGB} GB).")
        }
    }
    catch {
        $failures.Add("Failed to check node staging disk space: $_")
    }

    # --- Check 2: C&C backup root disk space ---
    $ccBackupRoot = $GlobalConfig.storage.cc_backup_root
    try {
        if (Test-Path -Path $ccBackupRoot -PathType Container) {
            $ccDriveLetter = (Split-Path -Path $ccBackupRoot -Qualifier).TrimEnd(':')
            $ccDrive = Get-PSDrive -Name $ccDriveLetter -ErrorAction Stop
            $diskSpaceCC = @{
                DriveLetter = $ccDriveLetter
                FreeGB      = [math]::Round($ccDrive.Free / 1GB, 2)
                UsedGB      = [math]::Round($ccDrive.Used / 1GB, 2)
                TotalGB     = [math]::Round(($ccDrive.Free + $ccDrive.Used) / 1GB, 2)
            }

            if ($diskSpaceCC.FreeGB -lt $MinDiskSpaceGB) {
                $failures.Add("C&C backup root disk space is critically low: $($diskSpaceCC.FreeGB) GB free on drive $($diskSpaceCC.DriveLetter): (minimum: ${MinDiskSpaceGB} GB).")
            }
        }
        else {
            # Create the backup root if it does not exist
            New-Item -Path $ccBackupRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
            $ccDriveLetter = (Split-Path -Path $ccBackupRoot -Qualifier).TrimEnd(':')
            $ccDrive = Get-PSDrive -Name $ccDriveLetter -ErrorAction Stop
            $diskSpaceCC = @{
                DriveLetter = $ccDriveLetter
                FreeGB      = [math]::Round($ccDrive.Free / 1GB, 2)
                UsedGB      = [math]::Round($ccDrive.Used / 1GB, 2)
                TotalGB     = [math]::Round(($ccDrive.Free + $ccDrive.Used) / 1GB, 2)
            }
        }
    }
    catch {
        $failures.Add("Failed to check C&C backup root disk space at '$ccBackupRoot': $_")
    }

    # --- Check 3: NAS disk space (warning only) ---
    $nasPath = $GlobalConfig.storage.nas_backup_path
    if (-not [string]::IsNullOrWhiteSpace($nasPath)) {
        try {
            if (Test-Path -Path $nasPath -PathType Container) {
                $nasDriveLetter = (Split-Path -Path $nasPath -Qualifier).TrimEnd(':')
                $nasDrive = Get-PSDrive -Name $nasDriveLetter -ErrorAction Stop
                $diskSpaceNAS = @{
                    DriveLetter = $nasDriveLetter
                    FreeGB      = [math]::Round($nasDrive.Free / 1GB, 2)
                    UsedGB      = [math]::Round($nasDrive.Used / 1GB, 2)
                    TotalGB     = [math]::Round(($nasDrive.Free + $nasDrive.Used) / 1GB, 2)
                }

                if ($diskSpaceNAS.FreeGB -lt $MinDiskSpaceGB) {
                    $warnings.Add("NAS disk space is low: $($diskSpaceNAS.FreeGB) GB free (minimum: ${MinDiskSpaceGB} GB).")
                }
            }
            else {
                $warnings.Add("NAS path '$nasPath' is not accessible.")
            }
        }
        catch {
            $warnings.Add("Failed to check NAS disk space at '$nasPath': $_")
        }
    }

    # --- Check 4: World save folder exists with Sandbox.sbc ---
    try {
        $worldPath = $InstanceConfig['world_path']
        if ([string]::IsNullOrWhiteSpace($worldPath)) {
            $failures.Add("Instance config does not specify a 'world_path'.")
        }
        else {
            $worldCheck = Invoke-SEBRemoteCommand -Session $Session -ScriptBlock {
                param($wPath)
                # Node-local result name (not '$result') so the remote-scope contract test can
                # confirm this block references no C&C-scoped variable.
                $worldInfo = @{
                    FolderExists  = Test-Path -Path $wPath -PathType Container
                    SandboxExists = Test-Path -Path (Join-Path -Path $wPath -ChildPath 'Sandbox.sbc') -PathType Leaf
                }
                $worldInfo
            } -ArgumentList $worldPath -ErrorAction Stop

            if (-not $worldCheck.FolderExists) {
                $failures.Add("World save folder does not exist on the node: '$worldPath'.")
            }
            elseif (-not $worldCheck.SandboxExists) {
                $failures.Add("World save folder exists but Sandbox.sbc is missing: '$worldPath'.")
            }
        }
    }
    catch {
        $failures.Add("Failed to check world save folder on node: $_")
    }

    # --- Check 5: SMB share accessible from C&C ---
    try {
        $hostname = if ($NodeConfig.ContainsKey('node') -and $NodeConfig['node'].ContainsKey('hostname')) {
            $NodeConfig['node']['hostname']
        }
        elseif ($NodeConfig.ContainsKey('hostname')) {
            $NodeConfig['hostname']
        }
        else {
            $Session.ComputerName
        }

        $shareName = if ($InstanceConfig.ContainsKey('share_name')) { $InstanceConfig['share_name'] } else { $null }

        if ([string]::IsNullOrWhiteSpace($shareName)) {
            $warnings.Add("Instance config does not specify a 'share_name'. SMB share check skipped.")
        }
        else {
            $shareNodeConfig = @{ hostname = $hostname }
            $shareInstanceConfig = @{ share_name = $shareName }
            $sharePath = Get-SEBSharePath -NodeConfig $shareNodeConfig -InstanceConfig $shareInstanceConfig

            $credential = Get-SEBCredential -NodeName $InstanceConfig['_NodeName']
            $shareAccessible = Test-SEBShare -SharePath $sharePath -Credential $credential

            if (-not $shareAccessible) {
                $failures.Add("SMB share is not accessible from C&C: '$sharePath'.")
            }
        }
    }
    catch {
        $warnings.Add("Failed to check SMB share accessibility: $_")
    }

    # Log results
    if ($hasLogger) {
        if ($failures.Count -gt 0) {
            Write-SEBLog -Message "Pre-flight checks FAILED for '$instanceName': $($failures.Count) failure(s), $($warnings.Count) warning(s)" -Level ERROR -Context $instanceName
        }
        elseif ($warnings.Count -gt 0) {
            Write-SEBLog -Message "Pre-flight checks PASSED with warnings for '$instanceName': $($warnings.Count) warning(s)" -Level WARN -Context $instanceName
        }
        else {
            Write-SEBLog -Message "Pre-flight checks PASSED for '$instanceName'" -Level INFO -Context $instanceName
        }
    }

    return [PSCustomObject]@{
        Passed         = ($failures.Count -eq 0)
        Failures       = $failures.ToArray()
        Warnings       = $warnings.ToArray()
        DiskSpaceNode  = $diskSpaceNode
        DiskSpaceCC    = $diskSpaceCC
        DiskSpaceNAS   = $diskSpaceNAS
    }
}
