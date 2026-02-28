function Test-SEBChainIntegrity {
    <#
    .SYNOPSIS
        Performs a Level 3 full chain integrity check with dry-run reconstruction.

    .DESCRIPTION
        The most comprehensive integrity verification level. Validates an entire
        backup chain by:

        1. Retrieving the manifest chain via Get-SEBManifestChain.
        2. Running Level 1 (archive CRC) and Level 2 (manifest cross-check)
           verification on every archive in the chain.
        3. Extracting the full backup to a temporary directory.
        4. Layering each incremental backup in order -- overwriting modified files,
           adding new files, and removing files listed in each incremental's
           deleted_files array.
        5. Verifying the final reconstructed state by comparing SHA256 hashes of
           every file against the last manifest's file list.
        6. Cleaning up the temporary directory.

        This proves that the chain can be fully reassembled to produce a valid
        restore point. Use this for periodic deep validation or pre-restore
        confidence checks.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance whose backup chain to verify.

    .PARAMETER BackupRoot
        The root path of the backup storage directory (e.g., C:\SEBackup\Backups).

    .PARAMETER ChainId
        The chain identifier to verify. If not specified, the latest chain for
        the instance is used.

    .EXAMPLE
        $result = Test-SEBChainIntegrity -InstanceName "PvPArena" -BackupRoot "C:\SEBackup\Backups"
        Write-Host "Chain valid: $($result.Passed), Length: $($result.ChainLength)"

    .EXAMPLE
        $result = Test-SEBChainIntegrity -InstanceName "Creative01" -BackupRoot "D:\Backups" -ChainId "chain_20260201_020000"
        if (-not $result.ReconstructionValid) {
            Write-Warning "Chain reconstruction failed -- restore may not work."
        }

    .OUTPUTS
        PSCustomObject
        An object with properties: Level, Passed, ChainId, ChainLength,
        ArchiveResults, ReconstructionValid, CheckedAt, Duration, ErrorMessage.

    .LINK
        Test-SEBArchiveIntegrity
        Test-SEBManifestIntegrity
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot,

        [Parameter()]
        [string]$ChainId
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $result = [PSCustomObject]@{
        Level               = 3
        Passed              = $false
        ChainId             = $ChainId
        ChainLength         = 0
        ArchiveResults      = @()
        ReconstructionValid = $false
        CheckedAt           = [datetime]::UtcNow
        Duration            = $null
        ErrorMessage        = $null
    }

    $tempDir = $null

    try {
        Write-Verbose "IntegrityManager: Level 3 chain integrity check for instance '$InstanceName'"

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Level 3 chain integrity check: instance=$InstanceName, chain=$ChainId" -Level INFO -Context 'Integrity'
        }

        # --- Step 1: Get the manifest chain ---
        $chainParams = @{
            InstanceName = $InstanceName
            BackupRoot   = $BackupRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($ChainId)) {
            $chainParams['ChainId'] = $ChainId
        }

        $chain = Get-SEBManifestChain @chainParams

        if ($null -eq $chain -or $chain.Count -eq 0) {
            $result.ErrorMessage = "No manifest chain found for instance '$InstanceName'" +
                $(if ($ChainId) { " (chain: $ChainId)" } else { " (latest)" })
            return $result
        }

        $result.ChainLength = $chain.Count
        if (-not $result.ChainId -and $chain[0].chain_id) {
            $result.ChainId = $chain[0].chain_id
        }

        Write-Verbose "IntegrityManager: Chain contains $($chain.Count) manifest(s)"

        # --- Step 2: Run Level 1 + Level 2 on every archive ---
        $archiveResults = [System.Collections.Generic.List[PSCustomObject]]::new()
        $allArchivesPassed = $true

        foreach ($manifest in $chain) {
            $archivePath = $manifest.archive_path
            $manifestPath = $manifest._manifest_path  # Internal path set by Get-SEBManifestChain

            # If the manifest object doesn't carry its own path, derive it
            if (-not $manifestPath) {
                $instanceDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName
                $manifestFileName = [System.IO.Path]::GetFileNameWithoutExtension($archivePath) + '.manifest.json'
                $manifestPath = Join-Path -Path $instanceDir -ChildPath $manifestFileName
            }

            if (-not $archivePath -or -not (Test-Path -Path $archivePath -PathType Leaf)) {
                $archiveResults.Add([PSCustomObject]@{
                    ArchivePath  = $archivePath
                    Level1Passed = $false
                    Level2Passed = $false
                    ErrorMessage = "Archive file not found: $archivePath"
                })
                $allArchivesPassed = $false
                continue
            }

            # Level 1 check
            $level1 = Test-SEBArchiveIntegrity -ArchivePath $archivePath

            # Level 2 check
            $level2 = $null
            if ($manifestPath -and (Test-Path -Path $manifestPath -PathType Leaf)) {
                $level2 = Test-SEBManifestIntegrity -ArchivePath $archivePath -ManifestPath $manifestPath
            }

            $archiveEntry = [PSCustomObject]@{
                ArchivePath  = $archivePath
                Level1Passed = $level1.Passed
                Level2Passed = if ($level2) { $level2.Passed } else { $null }
                ErrorMessage = @($level1.ErrorMessage, $(if ($level2) { $level2.ErrorMessage })) |
                    Where-Object { $_ } | Join-String -Separator '; '
            }

            $archiveResults.Add($archiveEntry)

            if (-not $level1.Passed -or ($level2 -and -not $level2.Passed)) {
                $allArchivesPassed = $false
            }
        }

        $result.ArchiveResults = $archiveResults.ToArray()

        if (-not $allArchivesPassed) {
            $result.ErrorMessage = "One or more archives failed Level 1/Level 2 checks."

            if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
                Write-SEBLog -Message "Level 3 aborted: archive-level checks failed for instance '$InstanceName'" -Level ERROR -Context 'Integrity'
            }

            return $result
        }

        # --- Step 3: Extract the full backup to a temp directory ---
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "SEBackup_ChainVerify_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -Path $tempDir -ItemType Directory -Force -ErrorAction Stop | Out-Null

        Write-Verbose "IntegrityManager: Reconstructing chain in temp directory '$tempDir'"

        $fullManifest = $chain[0]
        $fullArchivePath = $fullManifest.archive_path

        # Extract the full backup
        Expand-SEBArchive -ArchivePath $fullArchivePath -DestinationPath $tempDir

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Extracted full backup: $fullArchivePath" -Level DEBUG -Context 'Integrity'
        }

        # --- Step 4: Layer each incremental in order ---
        for ($i = 1; $i -lt $chain.Count; $i++) {
            $incManifest = $chain[$i]
            $incArchivePath = $incManifest.archive_path

            Write-Verbose "IntegrityManager: Applying incremental $i of $($chain.Count - 1): $incArchivePath"

            # Extract incremental to a staging directory
            $stagingDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "SEBackup_IncStage_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
            New-Item -Path $stagingDir -ItemType Directory -Force -ErrorAction Stop | Out-Null

            try {
                Expand-SEBArchive -ArchivePath $incArchivePath -DestinationPath $stagingDir

                # Copy modified and new files from staging to reconstruction
                $stagingFiles = Get-ChildItem -Path $stagingDir -Recurse -File
                foreach ($file in $stagingFiles) {
                    $relativePath = $file.FullName.Substring($stagingDir.Length).TrimStart('\', '/')
                    $destPath = Join-Path -Path $tempDir -ChildPath $relativePath
                    $destDir = [System.IO.Path]::GetDirectoryName($destPath)

                    if (-not (Test-Path -Path $destDir -PathType Container)) {
                        New-Item -Path $destDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    }

                    Copy-Item -Path $file.FullName -Destination $destPath -Force -ErrorAction Stop
                }

                # Process deleted files from the incremental manifest
                $deletedFiles = $incManifest.deleted_files
                if ($deletedFiles -and $deletedFiles.Count -gt 0) {
                    foreach ($deletedFile in $deletedFiles) {
                        $deletedPath = Join-Path -Path $tempDir -ChildPath $deletedFile
                        if (Test-Path -Path $deletedPath) {
                            Remove-Item -Path $deletedPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                }

                if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
                    Write-SEBLog -Message "Applied incremental $i`: $incArchivePath" -Level DEBUG -Context 'Integrity'
                }
            }
            finally {
                # Clean up staging directory
                if (Test-Path -Path $stagingDir) {
                    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # --- Step 5: Verify the final reconstructed state ---
        $lastManifest = $chain[$chain.Count - 1]
        $reconstructionResult = Compare-ReconstructedState -ReconstructedPath $tempDir -Manifest $lastManifest

        $result.ReconstructionValid = $reconstructionResult.IsValid

        if ($reconstructionResult.IsValid) {
            $result.Passed = $true
            Write-Verbose "IntegrityManager: Level 3 PASSED -- chain reconstruction verified"

            if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
                Write-SEBLog -Message "Level 3 PASSED: instance=$InstanceName, chain=$($result.ChainId), length=$($chain.Count)" -Level INFO -Context 'Integrity'
            }
        }
        else {
            $result.ErrorMessage = "Reconstruction verification failed: $($reconstructionResult.ErrorMessage)"
            Write-Verbose "IntegrityManager: Level 3 FAILED -- reconstruction does not match final manifest"

            if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
                Write-SEBLog -Message "Level 3 FAILED: reconstruction mismatch for instance '$InstanceName'" -Level ERROR -Context 'Integrity'
            }
        }
    }
    catch {
        $result.ErrorMessage = "Level 3 check error: $_"

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Level 3 check error for instance '$InstanceName': $_" -Level ERROR -Context 'Integrity'
        }
    }
    finally {
        # --- Step 6: Clean up temp directory ---
        if ($tempDir -and (Test-Path -Path $tempDir)) {
            Write-Verbose "IntegrityManager: Cleaning up temp directory '$tempDir'"
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        $stopwatch.Stop()
        $result.Duration = $stopwatch.Elapsed
    }

    return $result
}
