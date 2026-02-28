function New-SEBManifest {
    <#
    .SYNOPSIS
        Scans a source path and generates an SEBackup manifest with SHA256 hashes.

    .DESCRIPTION
        Generates a manifest hashtable by scanning all files under the specified source
        path on a remote node. For each file, records the relative path, file size,
        last write time (ISO 8601), and SHA256 hash.

        OPTIMIZATION: When a PreviousManifest is provided, files whose size AND
        last_write timestamp are unchanged will reuse the previous SHA256 hash,
        skipping the expensive hash computation. This is critical for large .vx2
        voxel files that can exceed 500MB.

        The scan runs via Invoke-Command on the supplied PSSession so that all file
        I/O and hash computation happen on the remote node, avoiding network transfer
        of file contents.

        Returns a hashtable matching the SEBackup manifest v2 JSON schema, suitable
        for passing to Write-SEBManifest or Compare-SEBManifest.

    .PARAMETER SourcePath
        The path to scan on the remote node (typically a VSS shadow copy mount point).
        All files under this path are included in the manifest unless excluded.

    .PARAMETER ExcludePatterns
        An optional array of wildcard patterns for files to exclude from the manifest.
        For example, @("*.log", "*.tmp") will skip log and temp files.

    .PARAMETER PreviousManifest
        An optional hashtable from a previous manifest. When provided, files with
        unchanged size and last_write will reuse the cached SHA256 hash rather than
        recomputing it. Pass $null or omit for full hash computation on all files.

    .PARAMETER Session
        A PSSession connected to the remote node where the source path resides.
        All file enumeration and hashing runs on this session.

    .EXAMPLE
        $session = New-PSSession -ComputerName "GameNode01"
        $manifest = New-SEBManifest -SourcePath "E:\ShadowCopy\Instance1" -Session $session
        Write-SEBManifest -Manifest $manifest -Path "C:\Backups\Instance1\manifests\20260227_full.json"

    .EXAMPLE
        # Incremental with optimization
        $prev = Read-SEBManifest -Path "C:\Backups\Instance1\manifests\20260226_full.json"
        $manifest = New-SEBManifest -SourcePath "E:\ShadowCopy\Instance1" -PreviousManifest $prev -Session $session

    .OUTPUTS
        System.Collections.Hashtable
        A manifest hashtable with keys: version, type, chain_id, chain_sequence,
        parent_manifest, timestamp, files, deleted_files.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter()]
        [string[]]$ExcludePatterns,

        [Parameter()]
        [hashtable]$PreviousManifest,

        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $isIncremental = $null -ne $PreviousManifest

    Write-Verbose "Generating $(if ($isIncremental) { 'incremental' } else { 'full' }) manifest for '$SourcePath'."

    # Build the previous files lookup to send to the remote session
    $previousFiles = @{}
    if ($isIncremental -and $PreviousManifest.ContainsKey('files')) {
        $previousFiles = $PreviousManifest['files']
    }

    # Remote scan and hash computation
    $remoteResult = Invoke-Command -Session $Session -ScriptBlock {
        param(
            [string]$ScanPath,
            [string[]]$Excludes,
            [hashtable]$PrevFiles
        )

        $files = @{}
        $skippedCount = 0
        $hashedCount = 0

        # Normalize the scan path for consistent relative path computation
        $normalizedScanPath = $ScanPath.TrimEnd('\', '/')

        # Enumerate all files recursively
        $allFiles = Get-ChildItem -Path $ScanPath -Recurse -File -ErrorAction SilentlyContinue

        foreach ($file in $allFiles) {
            # Compute relative path
            $relativePath = $file.FullName.Substring($normalizedScanPath.Length + 1)
            # Normalize to forward slashes for cross-platform consistency
            $relativePath = $relativePath.Replace('\', '/')

            # Check exclusion patterns
            $excluded = $false
            foreach ($pattern in $Excludes) {
                if ($file.Name -like $pattern) {
                    $excluded = $true
                    break
                }
            }
            if ($excluded) { continue }

            $fileSize = $file.Length
            $lastWrite = $file.LastWriteTimeUtc.ToString('o')

            # Optimization: reuse previous hash if size and last_write are unchanged
            $sha256 = $null
            if ($PrevFiles.ContainsKey($relativePath)) {
                $prevEntry = $PrevFiles[$relativePath]
                if ($prevEntry['size'] -eq $fileSize -and $prevEntry['last_write'] -eq $lastWrite) {
                    $sha256 = $prevEntry['sha256']
                    $skippedCount++
                }
            }

            # Compute hash if we could not reuse the previous one
            if ($null -eq $sha256) {
                $hashResult = Get-FileHash -Path $file.FullName -Algorithm SHA256 -ErrorAction Stop
                $sha256 = $hashResult.Hash.ToLower()
                $hashedCount++
            }

            $files[$relativePath] = @{
                size       = $fileSize
                sha256     = $sha256
                last_write = $lastWrite
            }
        }

        return @{
            Files        = $files
            HashedCount  = $hashedCount
            SkippedCount = $skippedCount
        }
    } -ArgumentList $SourcePath, $ExcludePatterns, $previousFiles -ErrorAction Stop

    Write-Verbose "Scanned $($remoteResult.HashedCount + $remoteResult.SkippedCount) files: $($remoteResult.HashedCount) hashed, $($remoteResult.SkippedCount) reused from previous manifest."

    # Determine deleted files (in previous but not in current)
    $deletedFiles = @()
    if ($isIncremental -and $PreviousManifest.ContainsKey('files')) {
        foreach ($prevPath in $PreviousManifest['files'].Keys) {
            if (-not $remoteResult.Files.ContainsKey($prevPath)) {
                $deletedFiles += $prevPath
            }
        }
    }

    # Build the chain metadata
    if ($isIncremental) {
        $chainId = $PreviousManifest['chain_id']
        $chainSequence = [int]$PreviousManifest['chain_sequence'] + 1
        $parentManifest = $PreviousManifest['_source_filename']
        if ([string]::IsNullOrWhiteSpace($parentManifest)) {
            # Fallback: caller should have set _source_filename on read, but handle gracefully
            $parentManifest = $null
            Write-Warning "PreviousManifest does not contain '_source_filename'. The parent_manifest field will be null."
        }
    }
    else {
        $chainId = [guid]::NewGuid().ToString()
        $chainSequence = 0
        $parentManifest = $null
    }

    $manifest = @{
        version          = [int]2
        type             = if ($isIncremental) { 'incremental' } else { 'full' }
        chain_id         = $chainId
        chain_sequence   = [int]$chainSequence
        parent_manifest  = $parentManifest
        timestamp        = [datetime]::UtcNow.ToString('o')
        files            = $remoteResult.Files
        deleted_files    = $deletedFiles
    }

    return $manifest
}
