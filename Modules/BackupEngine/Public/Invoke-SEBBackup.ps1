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

            $loadCheck = Test-SEBNodeLoad -Session $session -Config $globalConfig.load_awareness
            if (-not $loadCheck.Safe) {
                if ($hasLogger) {
                    Write-SEBLog -Message "Node '$NodeName' is under high load. Waiting for safe conditions..." -Level WARN -Context $InstanceName
                }
                $waitResult = Wait-SEBNodeLoad -Session $session -Config $globalConfig.load_awareness
                if (-not $waitResult.Proceeded) {
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

        # Determine compression extension
        $compExt = if ($globalConfig.compression.engine -eq '7zip') { '.7z' } else { '.zip' }
        $archiveFileName = "${InstanceName}_${typeLabel}_${timestamp}${compExt}"

        # Get the volume letter from the world path for VSS
        $volumeLetter = Invoke-Command -Session $session -ScriptBlock {
            param($wPath)
            (Split-Path -Path $wPath -Qualifier).TrimEnd(':')
        } -ArgumentList $worldPath -ErrorAction Stop

        $manifest = $null
        $manifestDiff = $null
        $archivePath = $null

        # VSS lifecycle with try/finally
        Invoke-SEBWithShadowCopy -Session $session -VolumeLetter $volumeLetter -ScriptBlock {
            param($ShadowMountPath)

            # Compute the relative portion of world_path beneath the volume root
            $worldRelative = Invoke-Command -Session $session -ScriptBlock {
                param($wPath)
                $qualifier = Split-Path -Path $wPath -Qualifier
                $wPath.Substring($qualifier.Length).TrimStart('\', '/')
            } -ArgumentList $worldPath -ErrorAction Stop

            $vssScanPath = Join-Path -Path $ShadowMountPath -ChildPath $worldRelative

            if ($hasLogger) {
                Write-SEBLog -Message "VSS shadow copy mounted. Scanning: $vssScanPath" -Level INFO -Context $InstanceName
            }

            # --- Generate manifest ---
            $previousManifest = $backupDecision.LastManifest
            $script:manifest = New-SEBManifest `
                -SourcePath       $vssScanPath `
                -PreviousManifest $previousManifest `
                -Session          $session

            $result.FileCount = $script:manifest['files'].Count

            # --- For incremental: compare manifests to get diff ---
            $filesToCopy = $null
            if ($backupType -eq 'incremental') {
                $script:manifestDiff = Compare-SEBManifest `
                    -CurrentManifest  $script:manifest `
                    -PreviousManifest $previousManifest

                $filesToCopy = @($script:manifestDiff.Added) + @($script:manifestDiff.Modified)

                if ($hasLogger) {
                    Write-SEBLog -Message "Incremental diff: $($script:manifestDiff.AddedCount) added, $($script:manifestDiff.ModifiedCount) modified, $($script:manifestDiff.DeletedCount) deleted, $($script:manifestDiff.UnchangedCount) unchanged." -Level INFO -Context $InstanceName
                }

                # If no changes, still produce an incremental with just the manifest
                if ($script:manifestDiff.TotalChanges -eq 0) {
                    $warnings.Add("No file changes detected since last backup. Incremental archive will contain only the manifest.")
                    if ($hasLogger) {
                        Write-SEBLog -Message "No changes detected. Creating minimal incremental backup." -Level INFO -Context $InstanceName
                    }
                }
            }

            # --- Copy files from VSS mount to node staging dir ---
            if ($hasLogger) {
                Write-SEBLog -Message "Copying files from VSS mount to staging: $nodeStagingDir" -Level INFO -Context $InstanceName
            }

            Invoke-Command -Session $session -ScriptBlock {
                param($sourceDir, $destDir, $isIncremental, $changedFiles)

                # Ensure staging directory exists and is clean
                if (Test-Path -Path $destDir -PathType Container) {
                    Remove-Item -Path $destDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                New-Item -Path $destDir -ItemType Directory -Force -ErrorAction Stop | Out-Null

                if ($isIncremental -and $null -ne $changedFiles -and $changedFiles.Count -gt 0) {
                    # Copy only changed files (added + modified)
                    foreach ($relPath in $changedFiles) {
                        $srcFile = Join-Path -Path $sourceDir -ChildPath ($relPath.Replace('/', '\'))
                        $dstFile = Join-Path -Path $destDir -ChildPath ($relPath.Replace('/', '\'))
                        $dstFileDir = Split-Path -Path $dstFile -Parent

                        if (-not (Test-Path -Path $dstFileDir -PathType Container)) {
                            New-Item -Path $dstFileDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                        }

                        if (Test-Path -Path $srcFile -PathType Leaf) {
                            Copy-Item -Path $srcFile -Destination $dstFile -Force -ErrorAction Stop
                        }
                    }
                }
                else {
                    # Full backup: copy everything with robocopy for performance
                    $robocopyArgs = @($sourceDir, $destDir, '/E', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/MT:4')
                    $robocopyResult = & robocopy @robocopyArgs
                    $robocopyExit = $LASTEXITCODE

                    # Robocopy exit codes 0-7 indicate success (with various copy/skip counts)
                    if ($robocopyExit -ge 8) {
                        throw "Robocopy failed with exit code $robocopyExit during staging copy."
                    }
                }
            } -ArgumentList $vssScanPath, $nodeStagingDir, ($backupType -eq 'incremental'), $filesToCopy -ErrorAction Stop
        }

        # Retrieve manifest from script scope (set inside VSS block)
        $manifest = $script:manifest
        $manifestDiff = $script:manifestDiff

        if ($null -eq $manifest) {
            throw "Manifest generation failed inside VSS scope."
        }

        # ========================================================================
        # STEP 10: Compress on node
        # ========================================================================
        if ($hasLogger) {
            Write-SEBLog -Message "Compressing staging directory to archive: $archiveFileName" -Level INFO -Context $InstanceName
        }

        $nodeArchivePath = Join-Path -Path $nodeStagingBase -ChildPath $archiveFileName

        Compress-SEBArchive `
            -SourcePath  $nodeStagingDir `
            -Destination $nodeArchivePath `
            -Session     $session `
            -Config      $globalConfig.compression

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

        Copy-SEBThrottled `
            -Source      $shareArchivePath `
            -Destination $ccArchivePath `
            -Config      $globalConfig.network

        $result.ArchiveFile = $ccArchivePath

        # Write manifest to C&C
        $manifestFileName = "${InstanceName}_${typeLabel}_${timestamp}.json"
        $ccManifestPath = Join-Path -Path $ccManifestDir -ChildPath $manifestFileName

        $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $ccManifestPath -Force -ErrorAction Stop
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
                    -Source      $ccArchivePath `
                    -Destination $nasArchivePath `
                    -Config      $globalConfig.network

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
            if (-not $level1Result.Valid) {
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
            if (-not $level2Result.Valid) {
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
            Add-SEBMetric -Metric @{
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
                Send-SEBBackupNotification -BackupResult $result -GlobalConfig $globalConfig
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
                Send-SEBBackupNotification -BackupResult $result -GlobalConfig $globalConfig
            }
            catch {
                # Swallow notification errors during failure path
            }
        }
    }
    finally {
        # ========================================================================
        # STEP 18: Release lock file (always)
        # ========================================================================
        if ($lockAcquired) {
            Remove-SEBLockFile -InstanceName $InstanceName | Out-Null
        }
    }

    $result.Warnings = $warnings.ToArray()
    return $result
}
