function Test-SEBManifestIntegrity {
    <#
    .SYNOPSIS
        Performs a Level 2 integrity check verifying archive contents against their manifest.

    .DESCRIPTION
        Cross-references the contents of a backup archive against its corresponding
        manifest JSON file. This Level 2 check validates that:

        1. The number of files inside the archive matches the manifest's file list.
        2. Every file name in the manifest exists inside the archive.
        3. File sizes in the archive match the manifest's recorded sizes.
        4. The archive's SHA256 hash matches the archive_sha256 value stored in the manifest.

        This verification level catches scenarios where an archive was silently
        modified, truncated during transfer, or where a manifest was paired with
        the wrong archive.

    .PARAMETER ArchivePath
        The full path to the backup archive file to verify.

    .PARAMETER ManifestPath
        The full path to the manifest JSON file that describes the archive's
        expected contents.

    .PARAMETER Session
        An optional PSSession to a remote node. When specified, remote operations
        (file hash computation, archive listing) are performed on the remote machine.

    .EXAMPLE
        $result = Test-SEBManifestIntegrity `
            -ArchivePath "C:\SEBackup\Backups\PvPArena\full_20260201_020000.7z" `
            -ManifestPath "C:\SEBackup\Backups\PvPArena\full_20260201_020000.manifest.json"
        $result.FileCountMatch   # True if file counts agree
        $result.HashMatch        # True if SHA256 matches

    .EXAMPLE
        $result = Test-SEBManifestIntegrity -ArchivePath $archive -ManifestPath $manifest
        if (-not $result.Passed) {
            $result.Mismatches | ForEach-Object { Write-Warning $_ }
        }

    .OUTPUTS
        PSCustomObject
        An object with properties: Level, Passed, ArchivePath, ManifestPath,
        FileCountMatch, HashMatch, Mismatches, CheckedAt, ErrorMessage.

    .LINK
        Test-SEBArchiveIntegrity
        Test-SEBChainIntegrity
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ArchivePath,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$ManifestPath,

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $result = [PSCustomObject]@{
        Level          = 2
        Passed         = $false
        ArchivePath    = $ArchivePath
        ManifestPath   = $ManifestPath
        FileCountMatch = $false
        HashMatch      = $false
        Mismatches     = @()
        CheckedAt      = [datetime]::UtcNow
        ErrorMessage   = $null
    }

    try {
        Write-Verbose "IntegrityManager: Level 2 check on '$ArchivePath' against '$ManifestPath'"

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Level 2 integrity check: $ArchivePath vs $ManifestPath" -Level INFO -Context 'Integrity'
        }

        # --- Step 1: Read the manifest JSON ---
        if (-not (Test-Path -Path $ManifestPath -PathType Leaf)) {
            $result.ErrorMessage = "Manifest file not found: $ManifestPath"
            return $result
        }

        $manifestRaw = Get-Content -Path $ManifestPath -Raw -ErrorAction Stop
        # Parse as a hashtable so 'files' is the path-keyed v2 map (not a PSCustomObject
        # that foreach would treat as a single opaque item).
        $manifest = $manifestRaw | ConvertFrom-Json -AsHashtable -ErrorAction Stop

        # --- Step 2: List files inside the archive ---
        $archiveContentsParams = @{
            ArchivePath = $ArchivePath
        }
        if ($Session) {
            $archiveContentsParams['Session'] = $Session
        }

        $archiveContents = Get-SEBArchiveContents @archiveContentsParams
        if ($null -eq $archiveContents) {
            $result.ErrorMessage = "Failed to list archive contents for: $ArchivePath"
            return $result
        }

        # --- Step 3: Compare file count, names, and sizes ---
        $mismatches = [System.Collections.Generic.List[string]]::new()

        # Get the file list from the manifest's path-keyed 'files' hashtable (v2 schema:
        # relativePath -> @{ size; sha256; last_write }), normalized to forward slashes.
        $manifestFiles = @{}
        if ($manifest.files) {
            foreach ($relativePath in $manifest.files.Keys) {
                $manifestFiles[$relativePath.Replace('\', '/')] = $manifest.files[$relativePath]
            }
        }

        # Build a lookup from archive contents, normalized to forward slashes so the keys
        # line up with the manifest regardless of the compression engine's separator.
        $archiveFiles = @{}
        foreach ($item in $archiveContents) {
            $itemPath = if ($item.Path) { $item.Path } elseif ($item.Name) { $item.Name } else { $item.ToString() }
            $archiveFiles[$itemPath.Replace('\', '/')] = $item
        }

        # File count comparison
        $manifestCount = $manifestFiles.Count
        $archiveCount = $archiveFiles.Count

        # An incremental archive carries only the delta (added/modified files), while the
        # manifest's 'files' map is the FULL logical world state (it must stay full so restore
        # and Level-3 reconstruction can verify the complete world). So for an incremental the
        # archive is expected to be a SUBSET of the manifest: every archived file must appear in
        # the manifest with a matching size, but unchanged files are legitimately absent from the
        # archive. Requiring an exact match here renamed every incremental '_BAD'. Full archives
        # are still required to match the manifest exactly. Whole-chain completeness (no changed
        # file omitted) is verified separately by Level 3 (Test-SEBChainIntegrity).
        $isIncremental = ($manifest.type -eq 'incremental')

        if ($isIncremental) {
            # Subset semantics: the archive must not contain MORE files than the manifest.
            if ($archiveCount -le $manifestCount) {
                $result.FileCountMatch = $true
            }
            else {
                $mismatches.Add("Incremental archive file count ($archiveCount) exceeds manifest ($manifestCount)")
            }
        }
        else {
            if ($manifestCount -eq $archiveCount) {
                $result.FileCountMatch = $true
            }
            else {
                $mismatches.Add("File count mismatch: manifest=$manifestCount, archive=$archiveCount")
            }

            # Full archive: every manifest file must exist in the archive.
            foreach ($mFile in $manifestFiles.Keys) {
                if (-not $archiveFiles.ContainsKey($mFile)) {
                    $mismatches.Add("Missing from archive: $mFile")
                }
            }
        }

        # Check for extra files in the archive not in the manifest (applies to both: any file
        # in the archive must be accounted for in the manifest's full file list).
        foreach ($aFile in $archiveFiles.Keys) {
            if (-not $manifestFiles.ContainsKey($aFile)) {
                $mismatches.Add("Extra file in archive (not in manifest): $aFile")
            }
        }

        # Size comparison for files present in both
        foreach ($mFile in $manifestFiles.Keys) {
            if ($archiveFiles.ContainsKey($mFile)) {
                $manifestSize = $manifestFiles[$mFile].size
                $archiveSize = if ($archiveFiles[$mFile].Size) { $archiveFiles[$mFile].Size } else { $null }

                if ($null -ne $manifestSize -and $null -ne $archiveSize) {
                    if ([long]$manifestSize -ne [long]$archiveSize) {
                        $mismatches.Add("Size mismatch for '$mFile': manifest=$manifestSize, archive=$archiveSize")
                    }
                }
            }
        }

        # --- Step 4: Verify archive SHA256 hash ---
        $expectedHash = $manifest.archive_sha256
        if ($expectedHash) {
            $actualHash = (Get-FileHash -Path $ArchivePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
            $expectedHashLower = $expectedHash.ToLower()

            if ($actualHash -eq $expectedHashLower) {
                $result.HashMatch = $true
            }
            else {
                $mismatches.Add("Archive SHA256 mismatch: expected=$expectedHashLower, actual=$actualHash")
            }
        }
        else {
            # No hash recorded in manifest -- skip hash check but note it
            Write-Verbose "IntegrityManager: No archive_sha256 in manifest, skipping hash verification."
            $result.HashMatch = $true  # Not applicable, treat as pass
        }

        # --- Determine overall pass/fail ---
        $result.Mismatches = $mismatches.ToArray()
        $result.Passed = ($result.FileCountMatch -and $result.HashMatch -and ($mismatches.Count -eq 0))

        if ($result.Passed) {
            Write-Verbose "IntegrityManager: Level 2 PASSED for '$ArchivePath'"
            if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
                Write-SEBLog -Message "Level 2 PASSED: $ArchivePath" -Level INFO -Context 'Integrity'
            }
        }
        else {
            Write-Verbose "IntegrityManager: Level 2 FAILED for '$ArchivePath' with $($mismatches.Count) issue(s)"
            if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
                Write-SEBLog -Message "Level 2 FAILED: $ArchivePath ($($mismatches.Count) issue(s))" -Level ERROR -Context 'Integrity'
                foreach ($m in $mismatches) {
                    Write-SEBLog -Message "  Mismatch: $m" -Level WARN -Context 'Integrity'
                }
            }
        }
    }
    catch {
        $result.ErrorMessage = "Level 2 check error: $_"

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Level 2 check error for '$ArchivePath': $_" -Level ERROR -Context 'Integrity'
        }
    }

    return $result
}
