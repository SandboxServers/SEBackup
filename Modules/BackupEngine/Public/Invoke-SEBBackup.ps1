function Invoke-SEBBackup {
    <#
    .SYNOPSIS
        Orchestrates a complete backup workflow for a single Space Engineers Torch instance.

    .DESCRIPTION
        The main backup function for the SEBackup system. Executes the full backup
        workflow for one instance on one node:

        [0]  Load awareness check (if enabled)
        [1]  Acquire per-instance lock file (prevents concurrent runs)
        [2]  Load configs, create PSSession to node, read instance TOML
        [3]  Pre-flight checks (disk space, world exists, VSS, SMB share)
        [4]  Trigger VRage API save (flush to disk)
        [5]  Create VSS shadow copy
        [6]  Generate file manifest from shadow copy
        [7]  Copy files from VSS mount to node staging dir
        [8]  Compress staging to archive on the node
        [9]  Transfer archive from SMB share to C&C, distribute to tiers
        [10] Verify: Level 1 + Level 2 integrity checks
        [11] Record metrics (duration, size, success)
        [12] Send Discord webhook notification
        [13] Cleanup: staging, VSS, retention
        [14] Release lock, log summary

        Full vs incremental decision:
        - No previous backup -> Full
        - Hours since last full >= full_backup_interval_hours -> Full
        - Chain sequence >= max_incremental_chain_length -> Full
        - Otherwise -> Incremental

    .PARAMETER NodeName
        The name of the compute node hosting the Torch server instance.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance to back up.

    .PARAMETER ForceFull
        Forces a full backup regardless of the incremental decision logic.

    .PARAMETER SkipLoadCheck
        Skips the load awareness check before starting the backup.

    .PARAMETER SkipNotify
        Skips sending the Discord webhook notification at the end.

    .EXAMPLE
        $result = Invoke-SEBBackup -NodeName 'GameServer01' -InstanceName 'PvPArena'
        if ($result.Success) {
            Write-Host "Backup completed: $($result.ArchiveFile)"
        }

    .EXAMPLE
        Invoke-SEBBackup -NodeName 'GameServer01' -InstanceName 'Creative' -ForceFull -SkipLoadCheck

    .EXAMPLE
        Invoke-SEBBackup -NodeName 'GameServer01' -InstanceName 'PvPArena' -SkipNotify -Verbose

    .OUTPUTS
        PSCustomObject
        A result object with properties: Success, InstanceName, NodeName, BackupType,
        ArchiveFile, ArchiveSizeBytes, FileCount, Duration, ManifestFile, ChainId,
        ChainSequence, IntegrityPassed, Warnings, ErrorMessage.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter()]
        [switch]$ForceFull,

        [Parameter()]
        [switch]$SkipLoadCheck,

        [Parameter()]
        [switch]$SkipNotify
    )

    $overallStart = Get-Date
    $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue
    $warnings = [System.Collections.Generic.List[string]]::new()
    $lockAcquired = $false

    # Initialize result object (will be populated throughout)
    $result = [PSCustomObject]@{
        Success          = $false
        InstanceName     = $InstanceName
        NodeName         = $NodeName
        BackupType       = $null
        ArchiveFile      = $null
        ArchiveSizeBytes = 0
        FileCount        = 0
        Duration         = $null
        ManifestFile     = $null
        ChainId          = $null
        ChainSequence    = 0
        IntegrityPassed  = $false
        Warnings         = @()
        ErrorMessage     = $null
    }

    try {
        # ========================================================================
        # STEP 1-2: Load configs, create session, read instance config
        # ========================================================================
        if ($hasLogger) {
            Write-SEBLog -Message "=== Starting backup for '$InstanceName' on '$NodeName' ===" -Level INFO -Context $InstanceName
        }

        $globalConfig = Get-SEBGlobalConfig -Force
        if ($null -eq $globalConfig) {
            throw "Failed to load global configuration."
        }

        $nodeConfig = Get-SEBNodeConfig -NodeName $NodeName
        if ($null -eq $nodeConfig) {
            throw "Failed to load node configuration for '$NodeName'."
        }

        $session = New-SEBSession -NodeName $NodeName -NodeConfig ($nodeConfig.ContainsKey('node') ? $nodeConfig['node'] : $nodeConfig)
        if ($null -eq $session) {
            throw "Failed to create PSSession to node '$NodeName'."
        }

        $instanceConfig = Get-SEBInstanceConfig -Session $session -InstanceName $InstanceName
        if ($null -eq $instanceConfig) {
            throw "Failed to read instance config for '$InstanceName' from node '$NodeName'."
        }

        # ========================================================================
        # STEP 3: Acquire lock file
        # ========================================================================
        $lockResult = New-SEBLockFile -InstanceName $InstanceName
        if (-not $lockResult.Acquired) {
            throw "Could not acquire lock: $($lockResult.Reason)"
        }
        $lockAcquired = $true
        if ($lockResult.StaleLockBroken -and $hasLogger) {
            Write-SEBLog -Message "Stale lock was broken for '$InstanceName'." -Level WARN -Context $InstanceName
            $warnings.Add("Stale lock was broken before acquiring new lock.")
        }

        # ========================================================================
        # STEP 4: Load awareness check
        # ========================================================================
        $loadAwarenessEnabled = $globalConfig.load_awareness.enabled
        if ($loadAwarenessEnabled -and -not $SkipLoadCheck) {
            if ($hasLogger) {
                Write-SEBLog -Message "Running load awareness check for '$NodeName'..." -Level INFO -Context $InstanceName
            }

            $loadCheck = Test-SEBNodeLoad -Session $session -InstanceConfig $instanceConfig -GlobalConfig $globalConfig
            if (-not $loadCheck.CanProceed) {
                if ($hasLogger) {
                    Write-SEBLog -Message "Node '$NodeName' is under high load. Waiting for safe conditions..." -Level WARN -Context $InstanceName
                }
                $waitResult = Wait-SEBNodeLoad -Session $session -InstanceConfig $instanceConfig -GlobalConfig $globalConfig
                if (-not $waitResult.CanProceed) {
                    throw "Load awareness: backup deferred. Node '$NodeName' did not reach safe load levels within the maximum backoff period."
                }
                $warnings.Add("Backup was delayed by $([math]::Round($waitResult.WaitedSeconds, 0))s due to high node load.")
            }
        }

        # ========================================================================
        # STEP 5: Determine backup type (full vs incremental)
        # ========================================================================
        $ccBackupRoot = $globalConfig.storage.cc_backup_root
        $backupDecision = Get-SEBBackupType `
            -InstanceName $InstanceName `
            -GlobalConfig $globalConfig `
            -BackupRoot   $ccBackupRoot `
            -ForceFull:$ForceFull

        $backupType = $backupDecision.Type
        $result.BackupType = $backupType

        if ($hasLogger) {
            Write-SEBLog -Message "Backup type determined: $backupType -- $($backupDecision.Reason)" -Level INFO -Context $InstanceName
        }

        # ========================================================================
        # STEP 6: Pre-flight checks
        # ========================================================================
        $preFlightResult = Test-SEBPreFlight `
            -Session        $session `
            -NodeConfig     $nodeConfig `
            -InstanceConfig $instanceConfig `
            -GlobalConfig   $globalConfig

        if (-not $preFlightResult.Passed) {
            $failureMsg = "Pre-flight checks failed: " + ($preFlightResult.Failures -join '; ')
            throw $failureMsg
        }

        foreach ($w in $preFlightResult.Warnings) {
            $warnings.Add($w)
            if ($hasLogger) {
                Write-SEBLog -Message "Pre-flight warning: $w" -Level WARN -Context $InstanceName
            }
        }

        # ========================================================================
        # STEP 7: Trigger VRage API save (flush to disk)
        # ========================================================================
        $vragePort = if ($instanceConfig.ContainsKey('vrage_api') -and $instanceConfig['vrage_api'].ContainsKey('port')) {
            $instanceConfig['vrage_api']['port']
        }
        else {
            $globalConfig.defaults.vrage_api.port
        }

        $vrageKey = if ($instanceConfig.ContainsKey('vrage_api') -and $instanceConfig['vrage_api'].ContainsKey('security_key')) {
            $instanceConfig['vrage_api']['security_key']
        }
        else {
            $null
        }

        $saveTimeoutSeconds = if ($instanceConfig.ContainsKey('vrage_api') -and $instanceConfig['vrage_api'].ContainsKey('save_timeout_seconds')) {
            $instanceConfig['vrage_api']['save_timeout_seconds']
        }
        else {
            $globalConfig.defaults.vrage_api.save_timeout_seconds
        }

        $nodeHostname = if ($nodeConfig.ContainsKey('node') -and $nodeConfig['node'].ContainsKey('hostname')) {
            $nodeConfig['node']['hostname']
        }
        elseif ($nodeConfig.ContainsKey('hostname')) {
            $nodeConfig['hostname']
        }
        else {
            $session.ComputerName
        }

        if (-not [string]::IsNullOrWhiteSpace($vrageKey)) {
            if ($hasLogger) {
                Write-SEBLog -Message "Triggering VRage world save on ${nodeHostname}:${vragePort}..." -Level INFO -Context $InstanceName
            }

            $saveResult = Save-SEBVRageWorld `
                -Hostname       $nodeHostname `
                -Port           $vragePort `
                -SecurityKey    $vrageKey `
                -TimeoutSeconds $saveTimeoutSeconds

            if ($saveResult.Success) {
                if ($hasLogger) {
                    Write-SEBLog -Message "VRage world save completed in $([math]::Round($saveResult.Duration.TotalSeconds, 1))s." -Level INFO -Context $InstanceName
                }
            }
            else {
                $warnMsg = "VRage world save failed: $($saveResult.ErrorMessage). Proceeding with backup anyway."
                $warnings.Add($warnMsg)
                if ($hasLogger) {
                    Write-SEBLog -Message $warnMsg -Level WARN -Context $InstanceName
                }
            }
        }
        else {
            $warnings.Add("No VRage API security_key configured. Skipping world save trigger.")
            if ($hasLogger) {
                Write-SEBLog -Message "No VRage API security_key configured. Skipping save trigger." -Level WARN -Context $InstanceName
            }
        }

        # ========================================================================
        # STEP 8-9: VSS Shadow Copy -> Manifest -> Copy -> Compress
        # ========================================================================
        $worldPath = $instanceConfig['world_path']
        $nodeStagingBase = if ($instanceConfig.ContainsKey('staging_path')) {
            $instanceConfig['staging_path']
        }
        else {
            'C:\SEBackup\staging'
        }
        $nodeStagingDir = Join-Path -Path $nodeStagingBase -ChildPath $InstanceName

        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $typeLabel = if ($backupType -eq 'full') { 'FULL' } else { 'INC' }

        # Resolve the effective compression engine and level once so the archive extension,
        # the compression step, and restore all agree. An 'auto' engine that silently
        # resolved differently on different machines produced mismatched / unrestorable archives.
        $configEngine = if ($globalConfig.compression.engine) { $globalConfig.compression.engine } else { 'auto' }
        $compressionLevel = if ($globalConfig.compression.level_7zip) { [int]$globalConfig.compression.level_7zip } else { 5 }
        $resolvedEngine = $configEngine
        if ($resolvedEngine -eq 'auto') {
            try { $resolvedEngine = Get-SEBCompressionEngine -Session $session }
            catch { $resolvedEngine = 'dotnet' }
        }
        $compExt = if ($resolvedEngine -eq '7zip') { '.7z' } else { '.zip' }
        $archiveFileName = "${InstanceName}_${typeLabel}_${timestamp}${compExt}"

        # Resolve the volume root and the world path relative to it on the node, up front,
        # so the remote VSS block stays self-contained (no nested remoting, no C&C state).
        $pathInfo = Invoke-Command -Session $session -ScriptBlock {
            param($wPath)
            $qualifier = Split-Path -Path $wPath -Qualifier
            @{
                VolumeRoot    = "$qualifier\"
                WorldRelative = $wPath.Substring($qualifier.Length).TrimStart('\', '/')
            }
        } -ArgumentList $worldPath -ErrorAction Stop
        $volumeRoot = $pathInfo.VolumeRoot
        $worldRelative = $pathInfo.WorldRelative

        $vssMountBase = if ($globalConfig.defaults -and $globalConfig.defaults.vss -and $globalConfig.defaults.vss.mount_base) {
            $globalConfig.defaults.vss.mount_base
        }
        else {
            'C:\SEBackup\vss_mount'
        }

        if ($hasLogger) {
            Write-SEBLog -Message "Capturing consistent snapshot of '$worldPath' via VSS into staging '$nodeStagingDir'..." -Level INFO -Context $InstanceName
        }

        # STEP 8: Capture the world into node staging from a VSS snapshot. The script block
        # runs on the NODE (Invoke-SEBWithShadowCopy uses Invoke-Command -Session), so it does
        # only node-local work and receives everything it needs through -ArgumentList.
        Invoke-SEBWithShadowCopy `
            -Session   $session `
            -Volume    $volumeRoot `
            -MountBase $vssMountBase `
            -ScriptBlock {
                param($ShadowMountPath, $RelativePath, $DestDir)

                $scanPath = Join-Path -Path $ShadowMountPath -ChildPath $RelativePath

                if (Test-Path -Path $DestDir -PathType Container) {
                    Remove-Item -Path $DestDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                New-Item -Path $DestDir -ItemType Directory -Force -ErrorAction Stop | Out-Null

                $robocopyArgs = @($scanPath, $DestDir, '/E', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/MT:4')
                & robocopy @robocopyArgs | Out-Null
                if ($LASTEXITCODE -ge 8) {
                    throw "Robocopy failed with exit code $LASTEXITCODE during VSS staging copy."
                }
            } `
            -ArgumentList @($worldRelative, $nodeStagingDir)

        # STEP 9: Generate the manifest on the C&C from the captured staging copy
        # (New-SEBManifest reaches the node through the session). Only pass the previous
        # manifest for an incremental; passing it for a full would record the full as an
        # incremental and corrupt the chain metadata.
        $previousManifest = if ($backupType -eq 'incremental') { $backupDecision.LastManifest } else { $null }

        $manifestParams = @{
            SourcePath = $nodeStagingDir
            Session    = $session
        }
        if ($null -ne $previousManifest) {
            $manifestParams['PreviousManifest'] = $previousManifest
        }
        $manifest = New-SEBManifest @manifestParams

        if ($null -eq $manifest) {
            throw "Manifest generation failed for staging path '$nodeStagingDir'."
        }
        $result.FileCount = $manifest['files'].Count

        # For an incremental, diff against the parent and prune staging down to only the
        # changed files so the archive carries just the delta.
        $manifestDiff = $null
        if ($backupType -eq 'incremental' -and $null -ne $previousManifest) {
            $manifestDiff = Compare-SEBManifest -CurrentManifest $manifest -PreviousManifest $previousManifest

            if ($hasLogger) {
                Write-SEBLog -Message "Incremental diff: $($manifestDiff.AddedCount) added, $($manifestDiff.ModifiedCount) modified, $($manifestDiff.DeletedCount) deleted, $($manifestDiff.UnchangedCount) unchanged." -Level INFO -Context $InstanceName
            }

            $changedFiles = @($manifestDiff.Added) + @($manifestDiff.Modified)
            if ($changedFiles.Count -eq 0) {
                $warnings.Add("No file changes detected since last backup. Incremental archive will contain only the manifest.")
                if ($hasLogger) {
                    Write-SEBLog -Message "No changes detected. Creating minimal incremental backup." -Level INFO -Context $InstanceName
                }
            }

            # Prune unchanged files from staging on the node.
            Invoke-Command -Session $session -ScriptBlock {
                param($StagingDir, $KeepRelative)
                $keep = [System.Collections.Generic.HashSet[string]]::new(
                    [string[]]@($KeepRelative | ForEach-Object { $_.Replace('/', '\') }),
                    [System.StringComparer]::OrdinalIgnoreCase)
                $root = $StagingDir.TrimEnd('\', '/')
                Get-ChildItem -Path $StagingDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $rel = $_.FullName.Substring($root.Length + 1)
                    if (-not $keep.Contains($rel)) {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
            } -ArgumentList @($nodeStagingDir, $changedFiles) -ErrorAction Stop
        }

        # ========================================================================
        # STEP 10: Compress on node
        # ========================================================================
        if ($hasLogger) {
            Write-SEBLog -Message "Compressing staging directory to archive: $archiveFileName" -Level INFO -Context $InstanceName
        }

        $nodeArchivePath = Join-Path -Path $nodeStagingBase -ChildPath $archiveFileName

        Compress-SEBArchive `
            -SourcePath       $nodeStagingDir `
            -DestinationPath  $nodeArchivePath `
            -Session          $session `
            -Engine           $resolvedEngine `
            -CompressionLevel $compressionLevel

        # Get archive size from node
        $archiveInfo = Invoke-Command -Session $session -ScriptBlock {
            param($archPath)
            if (Test-Path -Path $archPath -PathType Leaf) {
                $fi = Get-Item -Path $archPath
                @{ SizeBytes = $fi.Length; Exists = $true }
            }
            else {
                @{ SizeBytes = 0; Exists = $false }
            }
        } -ArgumentList $nodeArchivePath -ErrorAction Stop

        if (-not $archiveInfo.Exists) {
            throw "Archive was not created on node: $nodeArchivePath"
        }

        $result.ArchiveSizeBytes = $archiveInfo.SizeBytes
        if ($hasLogger) {
            Write-SEBLog -Message "Archive created: $archiveFileName ($([math]::Round($archiveInfo.SizeBytes / 1MB, 2)) MB)" -Level INFO -Context $InstanceName
        }

        # ========================================================================
        # STEP 11: Transfer archive from node SMB share to C&C
        # ========================================================================
        $shareName = if ($instanceConfig.ContainsKey('share_name')) { $instanceConfig['share_name'] } else { $null }

        if ([string]::IsNullOrWhiteSpace($shareName)) {
            throw "Instance config does not specify 'share_name'. Cannot transfer archive from node."
        }

        $shareNodeConfig = @{ hostname = $nodeHostname }
        $shareInstanceConfig = @{ share_name = $shareName }
        $sharePath = Get-SEBSharePath -NodeConfig $shareNodeConfig -InstanceConfig $shareInstanceConfig

        # Compute the relative path of the archive within the share
        $shareArchivePath = Join-Path -Path $sharePath -ChildPath $archiveFileName

        # Determine C&C destination directories
        $ccInstanceDir = Join-Path -Path $ccBackupRoot -ChildPath $InstanceName
        $ccTypeDir = Join-Path -Path $ccInstanceDir -ChildPath $backupType
        $ccManifestDir = Join-Path -Path $ccInstanceDir -ChildPath 'manifests'

        foreach ($dir in @($ccTypeDir, $ccManifestDir)) {
            if (-not (Test-Path -Path $dir -PathType Container)) {
                New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
        }

        $ccArchivePath = Join-Path -Path $ccTypeDir -ChildPath $archiveFileName

        if ($hasLogger) {
            Write-SEBLog -Message "Transferring archive from '$shareArchivePath' to C&C '$ccArchivePath'..." -Level INFO -Context $InstanceName
        }

        $netBandwidthMbps = if ($globalConfig.network.max_bandwidth_mbps) { [int]$globalConfig.network.max_bandwidth_mbps } else { 0 }
        $netRobocopyIpgMs = if ($globalConfig.network.robocopy_ipg_ms) { [int]$globalConfig.network.robocopy_ipg_ms } else { 0 }

        Copy-SEBThrottled `
            -Source           $shareArchivePath `
            -Destination      $ccArchivePath `
            -MaxBandwidthMbps $netBandwidthMbps `
            -RobocopyIpgMs    $netRobocopyIpgMs

        $result.ArchiveFile = $ccArchivePath

        # Write manifest to C&C
        $manifestFileName = "${InstanceName}_${typeLabel}_${timestamp}.json"
        $ccManifestPath = Join-Path -Path $ccManifestDir -ChildPath $manifestFileName

        Write-SEBManifest -Manifest $manifest -Path $ccManifestPath
        $result.ManifestFile = $ccManifestPath
        $result.ChainId = $manifest['chain_id']
        $result.ChainSequence = $manifest['chain_sequence']

        if ($hasLogger) {
            Write-SEBLog -Message "Manifest written: $manifestFileName" -Level INFO -Context $InstanceName
        }

        # ========================================================================
        # STEP 12: Copy to NAS (warn if unreachable, don't abort)
        # ========================================================================
        $nasPath = $globalConfig.storage.nas_backup_path
        if (-not [string]::IsNullOrWhiteSpace($nasPath)) {
            try {
                $nasInstanceDir = Join-Path -Path $nasPath -ChildPath $InstanceName
                $nasTypeDir = Join-Path -Path $nasInstanceDir -ChildPath $backupType

                if (-not (Test-Path -Path $nasTypeDir -PathType Container)) {
                    New-Item -Path $nasTypeDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }

                $nasArchivePath = Join-Path -Path $nasTypeDir -ChildPath $archiveFileName

                if ($hasLogger) {
                    Write-SEBLog -Message "Copying archive to NAS: $nasArchivePath" -Level INFO -Context $InstanceName
                }

                Copy-SEBThrottled `
                    -Source           $ccArchivePath `
                    -Destination      $nasArchivePath `
                    -MaxBandwidthMbps $netBandwidthMbps `
                    -RobocopyIpgMs    $netRobocopyIpgMs

                if ($hasLogger) {
                    Write-SEBLog -Message "NAS copy completed." -Level INFO -Context $InstanceName
                }
            }
            catch {
                $nasWarn = "Failed to copy archive to NAS: $_"
                $warnings.Add($nasWarn)
                if ($hasLogger) {
                    Write-SEBLog -Message $nasWarn -Level WARN -Context $InstanceName
                }
            }
        }

        # ========================================================================
        # STEP 13: Integrity checks (Level 1 + Level 2)
        # ========================================================================
        $integrityPassed = $true

        # Level 1: Archive integrity (CRC/hash check)
        try {
            $level1Result = Test-SEBArchiveIntegrity -ArchivePath $ccArchivePath
            if (-not $level1Result.Passed) {
                $integrityPassed = $false
                $warnings.Add("Level 1 integrity check FAILED for archive: $($level1Result.ErrorMessage)")
                if ($hasLogger) {
                    Write-SEBLog -Message "Level 1 integrity check FAILED: $($level1Result.ErrorMessage)" -Level ERROR -Context $InstanceName
                }
            }
            else {
                if ($hasLogger) {
                    Write-SEBLog -Message "Level 1 integrity check PASSED." -Level INFO -Context $InstanceName
                }
            }
        }
        catch {
            $integrityPassed = $false
            $warnings.Add("Level 1 integrity check threw an error: $_")
            if ($hasLogger) {
                Write-SEBLog -Message "Level 1 integrity check error: $_" -Level ERROR -Context $InstanceName
            }
        }

        # Level 2: Manifest integrity (cross-check manifest vs archive contents)
        try {
            $level2Result = Test-SEBManifestIntegrity -ManifestPath $ccManifestPath -ArchivePath $ccArchivePath
            if (-not $level2Result.Passed) {
                $integrityPassed = $false
                $warnings.Add("Level 2 integrity check FAILED: $($level2Result.ErrorMessage)")
                if ($hasLogger) {
                    Write-SEBLog -Message "Level 2 integrity check FAILED: $($level2Result.ErrorMessage)" -Level ERROR -Context $InstanceName
                }
            }
            else {
                if ($hasLogger) {
                    Write-SEBLog -Message "Level 2 integrity check PASSED." -Level INFO -Context $InstanceName
                }
            }
        }
        catch {
            $integrityPassed = $false
            $warnings.Add("Level 2 integrity check threw an error: $_")
            if ($hasLogger) {
                Write-SEBLog -Message "Level 2 integrity check error: $_" -Level ERROR -Context $InstanceName
            }
        }

        $result.IntegrityPassed = $integrityPassed

        if (-not $integrityPassed) {
            # Mark backup as BAD by renaming with _BAD suffix
            $badArchivePath = $ccArchivePath -replace '(\.\w+)$', '_BAD$1'
            try {
                Rename-Item -Path $ccArchivePath -NewName (Split-Path -Path $badArchivePath -Leaf) -Force -ErrorAction Stop
                $result.ArchiveFile = $badArchivePath
            }
            catch {
                $warnings.Add("Failed to rename failed archive to BAD: $_")
            }
        }

        # ========================================================================
        # STEP 14: Metrics
        # ========================================================================
        $overallDuration = (Get-Date) - $overallStart
        $result.Duration = $overallDuration

        try {
            Add-SEBMetric -InstanceName $InstanceName -BackupRoot $ccBackupRoot -MetricData @{
                instance       = $InstanceName
                node           = $NodeName
                type           = $backupType
                success        = $integrityPassed
                duration_sec   = [math]::Round($overallDuration.TotalSeconds, 2)
                archive_bytes  = $result.ArchiveSizeBytes
                file_count     = $result.FileCount
                chain_id       = $result.ChainId
                chain_sequence = $result.ChainSequence
                timestamp      = [datetime]::UtcNow.ToString('o')
            }
        }
        catch {
            $warnings.Add("Failed to record metrics: $_")
        }

        # ========================================================================
        # STEP 15: Notification
        # ========================================================================
        if (-not $SkipNotify -and $globalConfig.notifications.enabled) {
            try {
                Send-SEBBackupNotification -InstanceName $InstanceName -BackupResult $result -GlobalConfig $globalConfig
            }
            catch {
                $warnings.Add("Failed to send notification: $_")
                if ($hasLogger) {
                    Write-SEBLog -Message "Notification failed: $_" -Level WARN -Context $InstanceName
                }
            }
        }

        # ========================================================================
        # STEP 16: Retention cleanup
        # ========================================================================
        try {
            Remove-SEBExpiredBackups -InstanceName $InstanceName -GlobalConfig $globalConfig
        }
        catch {
            $warnings.Add("Retention cleanup failed: $_")
            if ($hasLogger) {
                Write-SEBLog -Message "Retention cleanup failed: $_" -Level WARN -Context $InstanceName
            }
        }

        # ========================================================================
        # STEP 17: Cleanup staging on node
        # ========================================================================
        try {
            Invoke-Command -Session $session -ScriptBlock {
                param($stagingDir, $archivePath)

                # Remove the staging directory
                if (Test-Path -Path $stagingDir -PathType Container) {
                    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
                }

                # Remove old archives from the staging base, keeping only the latest full
                $stagingBase = Split-Path -Path $stagingDir -Parent
                $instanceName = Split-Path -Path $stagingDir -Leaf
                $oldArchives = Get-ChildItem -Path $stagingBase -Filter "${instanceName}_*" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -ne $archivePath } |
                    Where-Object { $_.Name -notmatch '_FULL_' -or $_.FullName -ne $archivePath } |
                    Sort-Object -Property LastWriteTime -Descending

                # Keep the latest FULL archive, remove all others (old fulls and all incrementals)
                $latestFullFound = $false
                foreach ($archive in $oldArchives) {
                    if ($archive.Name -match '_FULL_' -and -not $latestFullFound) {
                        $latestFullFound = $true
                        continue  # Keep latest full
                    }
                    Remove-Item -Path $archive.FullName -Force -ErrorAction SilentlyContinue
                }
            } -ArgumentList $nodeStagingDir, $nodeArchivePath -ErrorAction SilentlyContinue
        }
        catch {
            $warnings.Add("Node staging cleanup failed: $_")
        }

        # Mark success
        $result.Success = $integrityPassed

        if ($hasLogger) {
            $statusLabel = if ($result.Success) { 'SUCCESS' } else { 'COMPLETED WITH ERRORS' }
            Write-SEBLog -Message "=== Backup $statusLabel for '$InstanceName': $backupType, $([math]::Round($overallDuration.TotalSeconds, 1))s, $([math]::Round($result.ArchiveSizeBytes / 1MB, 2)) MB ===" -Level $(if ($result.Success) { 'INFO' } else { 'ERROR' }) -Context $InstanceName
        }
    }
    catch {
        $result.ErrorMessage = $_.Exception.Message
        $result.Duration = (Get-Date) - $overallStart

        if ($hasLogger) {
            Write-SEBLog -Message "=== Backup FAILED for '$InstanceName': $($_.Exception.Message) ===" -Level ERROR -Context $InstanceName
        }

        # Send failure notification
        if (-not $SkipNotify -and $globalConfig -and $globalConfig.notifications.enabled -and $globalConfig.notifications.on_failure) {
            try {
                Send-SEBBackupNotification -InstanceName $InstanceName -BackupResult $result -GlobalConfig $globalConfig
            }
            catch {
                # Swallow notification errors during failure path
            }
        }
    }
    finally {
        # ========================================================================
        # STEP 18: Release lock file and tear down the node session (always)
        # ========================================================================
        if ($lockAcquired) {
            Remove-SEBLockFile -InstanceName $InstanceName | Out-Null
        }

        # The session is created per backup; close it so sessions do not accumulate
        # across scheduled runs.
        if ($null -ne $session) {
            Remove-SEBSession -NodeName $NodeName | Out-Null
        }
    }

    $result.Warnings = $warnings.ToArray()
    return $result
}
