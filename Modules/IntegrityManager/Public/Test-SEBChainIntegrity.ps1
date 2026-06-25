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
    [OutputType([PSCustomObject])]
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

    # Resolve the optional structured logger once; the module works with or without it.
    $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue

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
        # InstanceName becomes a directory segment (<BackupRoot>/<InstanceName>); reject any path
        # traversal so a crafted instance name cannot redirect reads/extraction outside BackupRoot.
        if ($InstanceName -match '[\\/]' -or $InstanceName.Contains('..') -or [System.IO.Path]::IsPathRooted($InstanceName)) {
            $result.ErrorMessage = "Invalid InstanceName '$InstanceName': path separators and traversal are not allowed."
            return $result
        }

        Write-Verbose "IntegrityManager: Level 3 chain integrity check for instance '$InstanceName'"

        if ($hasLogger) {
            Write-SEBLog -Message "Level 3 chain integrity check: instance=$InstanceName, chain=$ChainId" -Level INFO -Context 'Integrity'
        }

        # --- Step 1: Resolve a real target manifest, then get the chain ---
        # Get-SEBManifestChain walks parent_manifest links backwards from a TARGET manifest;
        # its real signature is mandatory -InstanceName, -TargetManifest, -BackupRoot. It has
        # NO -ChainId parameter. So translate this function's optional -ChainId into a concrete
        # target manifest filename before calling it. Get-SEBLatestManifest owns the
        # manifest-directory scan for both cases:
        #   - No -ChainId: it returns the latest manifest for the instance (any type).
        #   - With -ChainId: it returns the head of that chain (highest chain_sequence,
        #     tie-broken by timestamp), preserving the -ChainId behaviour advertised here
        #     while honouring the real downstream signature.
        $targetManifest = $null

        $latest = if ([string]::IsNullOrWhiteSpace($ChainId)) {
            Get-SEBLatestManifest -InstanceName $InstanceName -BackupRoot $BackupRoot
        }
        else {
            Get-SEBLatestManifest -InstanceName $InstanceName -BackupRoot $BackupRoot -ChainId $ChainId
        }
        if ($latest) {
            $targetManifest = $latest['_source_filename']
        }

        if ([string]::IsNullOrWhiteSpace($targetManifest)) {
            $result.ErrorMessage = "No manifest chain found for instance '$InstanceName'" +
                $(if (-not [string]::IsNullOrWhiteSpace($ChainId)) { " (chain: $ChainId)" } else { " (latest)" })
            return $result
        }

        # Wrap in @() so a single-member (full-only) chain stays an array. Get-SEBManifestChain
        # returns $list.ToArray(); for one element PowerShell would otherwise unwrap that to a
        # bare hashtable, making $chain.Count the key count and $chain[0] $null. A brand-new
        # instance whose only backup is a full must still pass L3, so keep it array-shaped.
        $chain = @(Get-SEBManifestChain -InstanceName $InstanceName -TargetManifest $targetManifest -BackupRoot $BackupRoot)

        if ($null -eq $chain -or $chain.Count -eq 0) {
            $result.ErrorMessage = "No manifest chain found for instance '$InstanceName'" +
                $(if (-not [string]::IsNullOrWhiteSpace($ChainId)) { " (chain: $ChainId)" } else { " (latest)" })
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

        $instanceDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName
        foreach ($manifest in $chain) {
            # Resolve archive_path to the full path under <BackupRoot>/<Instance>/<type>/, with
            # traversal guards (archive_path/type are attacker-controllable manifest data) and a
            # fallback for legacy manifests that predate the archive_path field.
            $archivePath = Resolve-SEBChainArchivePath -Manifest $manifest -InstanceDir $instanceDir

            # Resolve the manifest's own file path from the filename recorded by Read-SEBManifest.
            $manifestPath = if ($manifest._source_filename) {
                Join-Path -Path (Join-Path -Path $instanceDir -ChildPath 'manifests') -ChildPath $manifest._source_filename
            }
            else { $null }

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

            if ($hasLogger) {
                Write-SEBLog -Message "Level 3 aborted: archive-level checks failed for instance '$InstanceName'" -Level ERROR -Context 'Integrity'
            }

            return $result
        }

        # --- Step 3: Extract the full backup to a temp directory ---
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "SEBackup_ChainVerify_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -Path $tempDir -ItemType Directory -Force -ErrorAction Stop | Out-Null

        Write-Verbose "IntegrityManager: Reconstructing chain in temp directory '$tempDir'"

        $fullManifest = $chain[0]
        $fullArchivePath = Resolve-SEBChainArchivePath -Manifest $fullManifest -InstanceDir $instanceDir
        if (-not $fullArchivePath -or -not (Test-Path -Path $fullArchivePath -PathType Leaf)) {
            $result.ErrorMessage = "Full backup archive could not be resolved safely for instance '$InstanceName'."
            return $result
        }

        # Extract the full backup. Expand-SEBArchive returns a descriptor object; discard it so
        # it does not leak into this function's pipeline and turn the single result object into
        # an array.
        Expand-SEBArchive -ArchivePath $fullArchivePath -DestinationPath $tempDir | Out-Null

        if ($hasLogger) {
            Write-SEBLog -Message "Extracted full backup: $fullArchivePath" -Level DEBUG -Context 'Integrity'
        }

        # --- Step 4: Layer each incremental in order ---
        for ($i = 1; $i -lt $chain.Count; $i++) {
            $incManifest = $chain[$i]
            $incArchivePath = Resolve-SEBChainArchivePath -Manifest $incManifest -InstanceDir $instanceDir
            if (-not $incArchivePath -or -not (Test-Path -Path $incArchivePath -PathType Leaf)) {
                $result.ErrorMessage = "Incremental archive $i could not be resolved safely for instance '$InstanceName'."
                return $result
            }

            Write-Verbose "IntegrityManager: Applying incremental $i of $($chain.Count - 1): $incArchivePath"

            # Extract incremental to a staging directory
            $stagingDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "SEBackup_IncStage_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
            New-Item -Path $stagingDir -ItemType Directory -Force -ErrorAction Stop | Out-Null

            try {
                # Discard the descriptor object so it does not leak into the result pipeline.
                Expand-SEBArchive -ArchivePath $incArchivePath -DestinationPath $stagingDir | Out-Null

                # Copy modified and new files from staging to reconstruction. Get-ChildItem -Recurse
                # follows directory symlinks/junctions, so a crafted archive could surface files from
                # outside $stagingDir and -- after Join-Path -- write them outside $tempDir. Anchor the
                # relative path to the resolved staging root and constrain every destination to the
                # resolved temp root, mirroring the deleted_files containment below.
                $stagingRoot = [System.IO.Path]::GetFullPath($stagingDir).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
                $tempRoot = [System.IO.Path]::GetFullPath($tempDir).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
                $stagingFiles = Get-ChildItem -Path $stagingDir -Recurse -File
                foreach ($file in $stagingFiles) {
                    $fullSource = [System.IO.Path]::GetFullPath($file.FullName)
                    if (-not $fullSource.StartsWith($stagingRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                        Write-Verbose "IntegrityManager: staged file '$($file.FullName)' escapes the staging root; skipping."
                        continue
                    }

                    $relativePath = $fullSource.Substring($stagingRoot.Length)
                    $destPath = Join-Path -Path $tempDir -ChildPath $relativePath
                    $fullDest = [System.IO.Path]::GetFullPath($destPath)
                    if (-not $fullDest.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                        Write-Verbose "IntegrityManager: staged file destination '$destPath' escapes the reconstruction root; skipping."
                        continue
                    }

                    $destDir = [System.IO.Path]::GetDirectoryName($fullDest)
                    if (-not (Test-Path -Path $destDir -PathType Container)) {
                        New-Item -Path $destDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    }

                    Copy-Item -LiteralPath $file.FullName -Destination $fullDest -Force -ErrorAction Stop
                }

                # Process deleted files from the incremental manifest. deleted_files is manifest
                # data, so an entry like '..\..\target' could escape $tempDir after Join-Path and
                # let Remove-Item delete outside the reconstruction workspace. Constrain every
                # removal to the temp root.
                $deletedFiles = $incManifest.deleted_files
                if ($deletedFiles -and $deletedFiles.Count -gt 0) {
                    # $tempRoot was resolved with the copy loop above (same try-scope, always runs).
                    foreach ($deletedFile in $deletedFiles) {
                        if ([string]::IsNullOrWhiteSpace($deletedFile) -or [System.IO.Path]::IsPathRooted($deletedFile)) {
                            Write-Verbose "IntegrityManager: skipping unsafe deleted_files entry '$deletedFile'."
                            continue
                        }
                        $deletedPath = [System.IO.Path]::GetFullPath((Join-Path -Path $tempDir -ChildPath $deletedFile))
                        if (-not $deletedPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                            Write-Verbose "IntegrityManager: deleted_files entry '$deletedFile' escapes the reconstruction root; skipping."
                            continue
                        }
                        if (Test-Path -LiteralPath $deletedPath) {
                            Remove-Item -LiteralPath $deletedPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                }

                if ($hasLogger) {
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

            if ($hasLogger) {
                Write-SEBLog -Message "Level 3 PASSED: instance=$InstanceName, chain=$($result.ChainId), length=$($chain.Count)" -Level INFO -Context 'Integrity'
            }
        }
        else {
            $result.ErrorMessage = "Reconstruction verification failed: $($reconstructionResult.ErrorMessage)"
            Write-Verbose "IntegrityManager: Level 3 FAILED -- reconstruction does not match final manifest"

            if ($hasLogger) {
                Write-SEBLog -Message "Level 3 FAILED: reconstruction mismatch for instance '$InstanceName'" -Level ERROR -Context 'Integrity'
            }
        }
    }
    catch {
        $result.ErrorMessage = "Level 3 check error: $_"

        if ($hasLogger) {
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
