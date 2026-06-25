function Invoke-SEBRestore {
    <#
    .SYNOPSIS
        Restores a Space Engineers Torch server instance to a specific backup point.

    .DESCRIPTION
        The main restore function for the SEBackup system. Reconstructs the world
        save state from a full + incremental backup chain and deploys it to the
        Torch server instance.

        Restore workflow:
        1.  Load configs, create session to node.
        2.  Get the manifest chain from the full backup to the target restore point.
        3.  Verify all archives in the chain exist and pass integrity checks.
        4.  Unless SkipSafetyBackup: run a safety full backup of the current state.
        5.  Stop Torch server on the node (service or console mode).
        6.  Reconstruct in a temp working directory on the node:
            a. Extract the full backup archive to temp dir.
            b. For each incremental in sequence order:
               - Extract incremental (overwriting existing files).
               - Process deleted_files list (remove files that were deleted).
        7.  Verify reconstructed state matches the target manifest (SHA256).
        8.  Deploy:
            a. Rename current world dir to {WorldName}_prerestore_{timestamp}.
            b. Copy reconstructed files to the world save location.
            c. Verify the copy.
        9.  Start Torch server and wait for VRage API ping.
        10. Send restore notification.
        11. Clean up temp directory.
        12. Return result.

    .PARAMETER NodeName
        The name of the compute node hosting the Torch server instance.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance to restore.

    .PARAMETER RestorePoint
        The manifest filename identifying the target restore point (e.g.,
        'PvPArena_INC_20260227_120000.json').

    .PARAMETER SkipSafetyBackup
        Skips the safety backup of the current state before restoring.
        Use with caution -- without a safety backup, the current state cannot
        be recovered via Undo-SEBRestore if the pre-restore directory rename fails.

    .PARAMETER Force
        Skips the confirmation prompt. Required for non-interactive use.

    .EXAMPLE
        $result = Invoke-SEBRestore -NodeName 'GameServer01' -InstanceName 'PvPArena' `
            -RestorePoint 'PvPArena_FULL_20260227_100000.json' -Force
        if ($result.Success) {
            Write-Host "Restored to $($result.RestorePoint). Undo available: $($result.UndoAvailable)"
        }

    .EXAMPLE
        Invoke-SEBRestore -NodeName 'GameServer01' -InstanceName 'Creative' `
            -RestorePoint 'Creative_INC_20260227_180000.json' -SkipSafetyBackup -Force

    .OUTPUTS
        PSCustomObject
        An object with: Success (bool), RestorePoint (string), Duration (TimeSpan),
        SafetyBackupPath (string), UndoAvailable (bool), ErrorMessage (string),
        Warnings (string[]).
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

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RestorePoint,

        [Parameter()]
        [switch]$SkipSafetyBackup,

        [Parameter()]
        [switch]$Force
    )

    $overallStart = Get-Date
    $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue
    $warnings = [System.Collections.Generic.List[string]]::new()
    $lockAcquired = $false

    $result = [PSCustomObject]@{
        Success          = $false
        RestorePoint     = $RestorePoint
        Duration         = $null
        SafetyBackupPath = $null
        UndoAvailable    = $false
        ErrorMessage     = $null
        Warnings         = @()
    }

    try {
        # ====================================================================
        # STEP 0: Acquire the per-instance lock. This is the SAME lock the backup
        # engine uses, so a restore cannot run concurrently with a scheduled backup
        # (or another restore) of the same instance and corrupt the world mid-write.
        # ====================================================================
        $lockResult = New-SEBLockFile -InstanceName $InstanceName
        if (-not $lockResult.Acquired) {
            throw "Could not acquire lock for restore of '$InstanceName': $($lockResult.Reason)"
        }
        $lockAcquired = $true
        if ($lockResult.StaleLockBroken) {
            $warnings.Add("A stale lock was broken before the restore acquired its lock.")
        }

        # ====================================================================
        # STEP 1: Load configs, create session
        # ====================================================================
        if ($hasLogger) {
            Write-SEBLog -Message "=== Starting restore for '$InstanceName' on '$NodeName' to restore point '$RestorePoint' ===" -Level INFO -Context $InstanceName
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

        $ccBackupRoot = $globalConfig.storage.cc_backup_root

        # ====================================================================
        # STEP 2: Confirmation prompt (unless Force)
        # ====================================================================
        if (-not $Force) {
            $confirmation = Read-Host -Prompt "RESTORE WARNING: This will overwrite the current world save for '$InstanceName' on '$NodeName'. Continue? (yes/no)"
            if ($confirmation -notin @('yes', 'y', 'YES', 'Y')) {
                throw "Restore cancelled by user."
            }
        }

        # ====================================================================
        # STEP 3: Validate the restore chain
        # ====================================================================
        if ($hasLogger) {
            Write-SEBLog -Message "Validating restore chain for '$RestorePoint'..." -Level INFO -Context $InstanceName
        }

        $chainValidation = Test-SEBRestoreChain `
            -InstanceName $InstanceName `
            -RestorePoint $RestorePoint `
            -BackupRoot   $ccBackupRoot

        if (-not $chainValidation.Valid) {
            $chainErrors = $chainValidation.Errors -join '; '
            throw "Restore chain validation failed: $chainErrors"
        }

        foreach ($w in $chainValidation.Warnings) {
            $warnings.Add($w)
        }

        if ($hasLogger) {
            Write-SEBLog -Message "Chain validated: $($chainValidation.ChainLength) archive(s) in chain." -Level INFO -Context $InstanceName
        }

        # ====================================================================
        # STEP 4: Safety backup (unless SkipSafetyBackup)
        # ====================================================================
        if (-not $SkipSafetyBackup) {
            if ($hasLogger) {
                Write-SEBLog -Message "Running safety backup before restore..." -Level INFO -Context $InstanceName
            }

            try {
                # The restore already holds the per-instance lock (STEP 0) and owns the cached
                # node session (STEP 1). Pass -SkipLock so the nested backup does not deadlock on
                # the lock we hold, and -KeepSession so its finally does not Remove-SEBSession the
                # session this restore keeps using for the (destructive) steps that follow.
                $safetyResult = Invoke-SEBBackup `
                    -NodeName     $NodeName `
                    -InstanceName $InstanceName `
                    -ForceFull `
                    -SkipLoadCheck `
                    -SkipNotify `
                    -SkipLock `
                    -KeepSession

                if ($safetyResult.Success) {
                    $result.SafetyBackupPath = $safetyResult.ArchiveFile
                    if ($hasLogger) {
                        Write-SEBLog -Message "Safety backup completed: $($safetyResult.ArchiveFile)" -Level INFO -Context $InstanceName
                    }
                }
                else {
                    $warnings.Add("Safety backup completed with issues: $($safetyResult.ErrorMessage)")
                    if ($hasLogger) {
                        Write-SEBLog -Message "Safety backup had issues: $($safetyResult.ErrorMessage)" -Level WARN -Context $InstanceName
                    }
                }
            }
            catch {
                $warnings.Add("Safety backup failed: $_. Proceeding with restore anyway.")
                if ($hasLogger) {
                    Write-SEBLog -Message "Safety backup failed: $_. Proceeding." -Level WARN -Context $InstanceName
                }
            }
        }
        else {
            $warnings.Add("Safety backup was skipped (SkipSafetyBackup specified).")
        }

        # ====================================================================
        # STEP 5: Stop Torch server
        # ====================================================================
        if ($hasLogger) {
            Write-SEBLog -Message "Stopping Torch server..." -Level INFO -Context $InstanceName
        }

        $stopResult = Stop-SEBTorchServer `
            -Session        $session `
            -InstanceConfig $instanceConfig `
            -NodeConfig     $nodeConfig

        if (-not $stopResult.Stopped) {
            if ($stopResult.Method -eq 'manual') {
                $warnings.Add("Server must be stopped manually: $($stopResult.ErrorMessage)")
                if ($hasLogger) {
                    Write-SEBLog -Message "Manual server stop required. Proceeding assuming server is stopped." -Level WARN -Context $InstanceName
                }
            }
            else {
                throw "Failed to stop Torch server: $($stopResult.ErrorMessage)"
            }
        }

        # ====================================================================
        # STEP 6: Reconstruct in temp working directory
        # ====================================================================
        $worldPath = $instanceConfig['world_path']
        $tempRestoreDir = "C:\SEBackup\restore_temp\$InstanceName"

        if ($hasLogger) {
            Write-SEBLog -Message "Reconstructing world state in temp directory on node..." -Level INFO -Context $InstanceName
        }

        # Read the chain manifests in order for deleted_files processing
        $manifestDir = Join-Path -Path $ccBackupRoot -ChildPath $InstanceName -AdditionalChildPath 'manifests'
        $chainManifestsOrdered = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($manifestPath in $chainValidation.ChainManifests) {
            $mContent = Get-Content -Path $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $chainManifestsOrdered.Add($mContent)
        }

        # Sort by chain_sequence
        $chainManifestsOrdered = [System.Collections.Generic.List[hashtable]]@(
            $chainManifestsOrdered | Sort-Object -Property { [int]$_['chain_sequence'] }
        )

        # Clean up any previous restore temp dir
        Invoke-Command -Session $session -ScriptBlock {
            param($tempDir)
            if (Test-Path -Path $tempDir -PathType Container) {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction Stop
            }
            New-Item -Path $tempDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } -ArgumentList $tempRestoreDir -ErrorAction Stop

        # Extract each archive in chain order
        for ($i = 0; $i -lt $chainValidation.ChainArchives.Count; $i++) {
            $archivePath = $chainValidation.ChainArchives[$i]
            $archiveManifest = $chainManifestsOrdered[$i]
            $archiveType = $archiveManifest['type']
            $archiveSeq = [int]$archiveManifest['chain_sequence']

            if ($hasLogger) {
                Write-SEBLog -Message "Extracting archive $($i + 1)/$($chainValidation.ChainArchives.Count): $(Split-Path -Path $archivePath -Leaf) (sequence $archiveSeq, $archiveType)" -Level INFO -Context $InstanceName
            }

            # Transfer the archive to the node temp area for extraction
            $nodeArchiveTempPath = "C:\SEBackup\restore_temp\${InstanceName}_archive_temp_$(Split-Path -Path $archivePath -Leaf)"

            # Copy archive from C&C to node via SMB
            $nodeHostname = if ($nodeConfig.ContainsKey('node') -and $nodeConfig['node'].ContainsKey('hostname')) {
                $nodeConfig['node']['hostname']
            }
            elseif ($nodeConfig.ContainsKey('hostname')) {
                $nodeConfig['hostname']
            }
            else {
                $session.ComputerName
            }

            $shareName = if ($instanceConfig.ContainsKey('share_name')) { $instanceConfig['share_name'] } else { $null }

            # Use Copy-SEBThrottled to transfer the archive to the node
            # First copy to a temp location accessible via SMB
            if (-not [string]::IsNullOrWhiteSpace($shareName)) {
                $shareNodeConfig = @{ hostname = $nodeHostname }
                $shareInstanceConfig = @{ share_name = $shareName }
                $sharePath = Get-SEBSharePath -NodeConfig $shareNodeConfig -InstanceConfig $shareInstanceConfig

                $shareDestPath = Join-Path -Path $sharePath -ChildPath "restore_temp_$(Split-Path -Path $archivePath -Leaf)"
                $netBandwidthMbps = if ($globalConfig.network.max_bandwidth_mbps) { [int]$globalConfig.network.max_bandwidth_mbps } else { 0 }
                $netRobocopyIpgMs = if ($globalConfig.network.robocopy_ipg_ms) { [int]$globalConfig.network.robocopy_ipg_ms } else { 0 }
                Copy-SEBThrottled -Source $archivePath -Destination $shareDestPath -MaxBandwidthMbps $netBandwidthMbps -RobocopyIpgMs $netRobocopyIpgMs

                # Get the local path on the node for the archive
                $nodeArchiveTempPath = Invoke-Command -Session $session -ScriptBlock {
                    param($shareBasePath, $fileName)
                    # The share maps to a local path - find the archive
                    $localFile = Get-ChildItem -Path (Split-Path -Path $shareBasePath -Parent) -Filter $fileName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($localFile) { return $localFile.FullName }
                    return $null
                } -ArgumentList $sharePath, "restore_temp_$(Split-Path -Path $archivePath -Leaf)" -ErrorAction SilentlyContinue

                if ([string]::IsNullOrWhiteSpace($nodeArchiveTempPath)) {
                    # Fallback: use the share path directly as a UNC path from the node
                    $nodeArchiveTempPath = $shareDestPath
                }
            }
            else {
                throw "No share_name configured. Cannot transfer archive to node."
            }

            # Extract on the node
            Invoke-Command -Session $session -ScriptBlock {
                param($archPath, $destDir, $archType)

                if ($archPath.EndsWith('.7z')) {
                    # Use 7-Zip for extraction
                    $7zPath = if (Test-Path 'C:\Program Files\7-Zip\7z.exe') {
                        'C:\Program Files\7-Zip\7z.exe'
                    }
                    elseif (Get-Command '7z' -ErrorAction SilentlyContinue) {
                        '7z'
                    }
                    else {
                        throw "7-Zip is not installed on the node."
                    }

                    $overwriteFlag = if ($archType -eq 'incremental') { '-aoa' } else { '-aoa' }
                    $result = & $7zPath x $archPath "-o$destDir" $overwriteFlag -y 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "7-Zip extraction failed (exit code $LASTEXITCODE): $result"
                    }
                }
                else {
                    # Use Expand-Archive for .zip
                    if ($archType -eq 'full') {
                        Expand-Archive -Path $archPath -DestinationPath $destDir -Force -ErrorAction Stop
                    }
                    else {
                        # For incremental, extract to a temp dir and copy over
                        $incTempDir = "${destDir}_inc_temp"
                        if (Test-Path $incTempDir) { Remove-Item -Path $incTempDir -Recurse -Force }
                        Expand-Archive -Path $archPath -DestinationPath $incTempDir -Force -ErrorAction Stop

                        # Copy files from inc temp to dest, overwriting
                        $incFiles = Get-ChildItem -Path $incTempDir -Recurse -File
                        foreach ($f in $incFiles) {
                            $relativePath = $f.FullName.Substring($incTempDir.Length + 1)
                            $destPath = Join-Path -Path $destDir -ChildPath $relativePath
                            $destFileDir = Split-Path -Path $destPath -Parent
                            if (-not (Test-Path $destFileDir)) {
                                New-Item -Path $destFileDir -ItemType Directory -Force | Out-Null
                            }
                            Copy-Item -Path $f.FullName -Destination $destPath -Force
                        }
                        Remove-Item -Path $incTempDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            } -ArgumentList $nodeArchiveTempPath, $tempRestoreDir, $archiveType -ErrorAction Stop

            # Process deleted_files for incrementals
            if ($archiveType -eq 'incremental' -and $archiveManifest.ContainsKey('deleted_files')) {
                $deletedFiles = $archiveManifest['deleted_files']
                if ($deletedFiles -and $deletedFiles.Count -gt 0) {
                    Invoke-Command -Session $session -ScriptBlock {
                        param($restoreDir, $filesToDelete)
                        foreach ($relPath in $filesToDelete) {
                            $fullPath = Join-Path -Path $restoreDir -ChildPath ($relPath.Replace('/', '\'))
                            if (Test-Path -Path $fullPath -PathType Leaf) {
                                Remove-Item -Path $fullPath -Force -ErrorAction SilentlyContinue
                            }
                        }
                    } -ArgumentList $tempRestoreDir, $deletedFiles -ErrorAction SilentlyContinue

                    if ($hasLogger) {
                        Write-SEBLog -Message "Processed $($deletedFiles.Count) deleted file(s) for sequence $archiveSeq." -Level INFO -Context $InstanceName
                    }
                }
            }

            # Clean up the temp archive on the node
            Invoke-Command -Session $session -ScriptBlock {
                param($archPath)
                if (Test-Path -Path $archPath -PathType Leaf) {
                    Remove-Item -Path $archPath -Force -ErrorAction SilentlyContinue
                }
            } -ArgumentList $nodeArchiveTempPath -ErrorAction SilentlyContinue
        }

        # ====================================================================
        # STEP 7: Verify reconstructed state against target manifest
        # ====================================================================
        if ($hasLogger) {
            Write-SEBLog -Message "Verifying reconstructed state against target manifest..." -Level INFO -Context $InstanceName
        }

        $targetManifest = $chainManifestsOrdered | Select-Object -Last 1
        $verifyResult = Invoke-Command -Session $session -ScriptBlock {
            param($restoreDir, $expectedFiles)

            $mismatches = [System.Collections.Generic.List[string]]::new()
            $checked = 0

            foreach ($relPath in $expectedFiles.Keys) {
                $fullPath = Join-Path -Path $restoreDir -ChildPath ($relPath.Replace('/', '\'))
                $expected = $expectedFiles[$relPath]

                if (-not (Test-Path -Path $fullPath -PathType Leaf)) {
                    $mismatches.Add("MISSING: $relPath")
                    continue
                }

                $actualHash = (Get-FileHash -Path $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
                if ($actualHash -ne $expected['sha256']) {
                    $mismatches.Add("HASH MISMATCH: $relPath (expected: $($expected['sha256']), got: $actualHash)")
                }
                $checked++
            }

            @{
                Checked    = $checked
                Mismatches = $mismatches.ToArray()
                Total      = $expectedFiles.Count
            }
        } -ArgumentList $tempRestoreDir, $targetManifest['files'] -ErrorAction Stop

        if ($verifyResult.Mismatches.Count -gt 0) {
            # The reconstructed world does not match the manifest. Abort BEFORE deploy so the
            # live world (and the pre-restore safety backup) remain intact -- deploying a
            # known-corrupt reconstruction is the worst possible outcome for a restore tool.
            $mismatchSample = $verifyResult.Mismatches | Select-Object -First 5
            throw "Reconstruction verification failed with $($verifyResult.Mismatches.Count) mismatch(es); aborting before deploy to avoid restoring a corrupt world. Samples: $($mismatchSample -join '; ')"
        }
        else {
            if ($hasLogger) {
                Write-SEBLog -Message "Reconstruction verified: $($verifyResult.Checked)/$($verifyResult.Total) files match." -Level INFO -Context $InstanceName
            }
        }

        # ====================================================================
        # STEP 8: Deploy reconstructed files
        # ====================================================================
        if ($hasLogger) {
            Write-SEBLog -Message "Deploying reconstructed files to '$worldPath'..." -Level INFO -Context $InstanceName
        }

        $deployResult = Deploy-SEBRestoredFiles `
            -Session   $session `
            -SourceDir $tempRestoreDir `
            -WorldPath $worldPath

        if (-not $deployResult.Deployed) {
            throw "Deployment failed: $($deployResult.ErrorMessage)"
        }

        $result.UndoAvailable = ($null -ne $deployResult.PreRestorePath)

        if ($hasLogger) {
            Write-SEBLog -Message "Deployment complete: $($deployResult.FilesCopied) files. Pre-restore backup at: $($deployResult.PreRestorePath)" -Level INFO -Context $InstanceName
        }

        # ====================================================================
        # STEP 9: Start Torch server
        # ====================================================================
        if ($hasLogger) {
            Write-SEBLog -Message "Starting Torch server..." -Level INFO -Context $InstanceName
        }

        $startResult = Start-SEBTorchServer `
            -Session        $session `
            -InstanceConfig $instanceConfig `
            -NodeConfig     $nodeConfig

        if ($startResult.Started) {
            if ($startResult.APIResponding) {
                if ($hasLogger) {
                    Write-SEBLog -Message "Torch server started and API responding." -Level INFO -Context $InstanceName
                }
            }
            else {
                $warnings.Add("Torch server started but VRage API is not responding within timeout. Server may still be loading.")
            }
        }
        else {
            $warnings.Add("Failed to start Torch server: $($startResult.ErrorMessage)")
            if ($hasLogger) {
                Write-SEBLog -Message "Failed to start Torch server: $($startResult.ErrorMessage)" -Level WARN -Context $InstanceName
            }
        }

        # ====================================================================
        # STEP 10: Send restore notification
        # ====================================================================
        if ($globalConfig.notifications.enabled) {
            try {
                # Use the restore notifier (honors the notifications.on_restore gate) and pass the
                # now-mandatory -InstanceName. The previous call routed through the *backup*
                # notifier without -InstanceName, so every successful restore threw a
                # ParameterBindingException and silently sent nothing.
                Send-SEBRestoreNotification `
                    -InstanceName $InstanceName `
                    -RestorePoint $RestorePoint `
                    -GlobalConfig $globalConfig
            }
            catch {
                $warnings.Add("Failed to send restore notification: $_")
            }
        }

        # ====================================================================
        # STEP 11: Cleanup temp directory
        # ====================================================================
        try {
            Invoke-Command -Session $session -ScriptBlock {
                param($tempDir)
                if (Test-Path -Path $tempDir -PathType Container) {
                    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                # Also clean up the restore_temp parent if empty
                $parentDir = Split-Path -Path $tempDir -Parent
                if ((Test-Path -Path $parentDir) -and
                    (Get-ChildItem -Path $parentDir -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item -Path $parentDir -Force -ErrorAction SilentlyContinue
                }
            } -ArgumentList $tempRestoreDir -ErrorAction SilentlyContinue
        }
        catch {
            $warnings.Add("Cleanup of temp restore directory failed: $_")
        }

        # ====================================================================
        # Success
        # ====================================================================
        $result.Success = $true
        $result.Duration = (Get-Date) - $overallStart

        if ($hasLogger) {
            Write-SEBLog -Message "=== Restore SUCCEEDED for '$InstanceName': restored to '$RestorePoint' in $([math]::Round($result.Duration.TotalSeconds, 1))s ===" -Level INFO -Context $InstanceName
        }
    }
    catch {
        $result.ErrorMessage = $_.Exception.Message
        $result.Duration = (Get-Date) - $overallStart

        if ($hasLogger) {
            Write-SEBLog -Message "=== Restore FAILED for '$InstanceName': $($_.Exception.Message) ===" -Level ERROR -Context $InstanceName
        }
    }
    finally {
        # Always release the instance lock.
        if ($lockAcquired) {
            Remove-SEBLockFile -InstanceName $InstanceName | Out-Null
        }
    }

    $result.Warnings = $warnings.ToArray()
    return $result
}
