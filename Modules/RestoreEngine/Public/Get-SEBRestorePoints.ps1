function Get-SEBRestorePoints {
    <#
    .SYNOPSIS
        Returns all available restore points for a Space Engineers Torch server instance.

    .DESCRIPTION
        Scans the manifest directory for the specified instance and returns all
        available restore points. Each restore point represents a moment in time
        to which the world save can be restored.

        For each restore point, validates that the required archive file exists
        and checks whether the full backup chain (from the full backup through
        the restore point) is complete.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance.

    .PARAMETER BackupRoot
        The root backup directory on the C&C server. If not specified, reads
        from the global config (storage.cc_backup_root).

    .EXAMPLE
        $points = Get-SEBRestorePoints -InstanceName 'PvPArena'
        $points | Format-Table Timestamp, Type, ChainSequence, ChainValid

    .EXAMPLE
        $points = Get-SEBRestorePoints -InstanceName 'Creative' -BackupRoot 'D:\Backups'
        $validPoints = $points | Where-Object { $_.ChainValid }

    .OUTPUTS
        PSCustomObject[]
        An array of restore point objects with properties: ManifestFile,
        Timestamp, Type, ChainId, ChainSequence, ArchiveFile, SizeBytes,
        ChainValid.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        # $InstanceName is concatenated into a filesystem path (Join-Path $BackupRoot $InstanceName).
        # Without this guard, a value like '..\..\x' would escape $BackupRoot and let discovery walk
        # arbitrary directories. Validation is delegated to the shared Test-SEBSafeName (issue #28)
        # so every name->path boundary stays consistent: it rejects path separators, '..' traversal,
        # rooted paths, wildcard metacharacters, and any invalid filename characters -- but ALLOWS
        # legitimate names that contain '.', spaces, etc. The -Throw style makes a rejected value a
        # terminating parameter-binding error, preserving this call site's original throwing
        # behaviour.
        [ValidateScript({ Test-SEBSafeName -Name $_ -Throw })]
        [string]$InstanceName,

        [Parameter()]
        [string]$BackupRoot
    )

    # Resolve the backup root
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $globalConfig = Get-SEBGlobalConfig
        if ($null -eq $globalConfig) {
            Write-Error 'Failed to load global config and no BackupRoot specified.'
            return @()
        }
        $BackupRoot = $globalConfig.storage.cc_backup_root
    }

    $manifestDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName -AdditionalChildPath 'manifests'
    $fullDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName -AdditionalChildPath 'full'
    $incDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName -AdditionalChildPath 'incremental'

    if (-not (Test-Path -Path $manifestDir -PathType Container)) {
        Write-Verbose "No manifest directory found for '$InstanceName' at '$manifestDir'."
        return @()
    }

    # Exclude '_BAD' manifests: Invoke-SEBBackup renames the manifest/archive to '..._BAD.json' /
    # '..._BAD.7z' when a backup fails integrity. Offering a known-corrupt backup as a restore
    # point would let an operator deploy it over the live world.
    $manifestFiles = Get-ChildItem -Path $manifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '_BAD\.' } |
        Sort-Object -Property Name -Descending

    if (-not $manifestFiles -or $manifestFiles.Count -eq 0) {
        Write-Verbose "No manifest files found for '$InstanceName'."
        return @()
    }

    # Build a lookup of all manifests by chain_id for chain validation
    $allManifests = @{}
    foreach ($mf in $manifestFiles) {
        try {
            # -LiteralPath: a manifest filename can legitimately contain PowerShell wildcard
            # metacharacters ('[', ']', etc.); -Path would interpret them as a glob and fail to read
            # the real file. This pairs with the exact-stem archive matching below.
            $content = Get-Content -LiteralPath $mf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $content['_source_filename'] = $mf.Name
            $content['_full_path'] = $mf.FullName
            $allManifests[$mf.Name] = $content
        }
        catch {
            Write-Warning "Failed to read manifest '$($mf.Name)': $_"
        }
    }

    # Build an O(1) lookup of every real archive under full\ and incremental\ ONCE, up front, keyed
    # by the archive's stem. 'Stem' = the file's BaseName (filename without its final extension),
    # which is what links an archive back to its manifest ('{name}.json' <-> '{name}.7z'). Mapping
    # stem -> FileInfo (rather than just a presence set) lets the restore-point lookup below recover
    # the archive's FullName and Length for the output object, while the chain-validation loop only
    # needs an O(1) ContainsKey existence test. This single up-front scan fixes two issues with the
    # previous per-manifest `Get-ChildItem -Filter "${baseName}.*"`:
    #   1. (security) a '*' or '?' in a manifest-derived stem would be treated as a wildcard by
    #      -Filter and could glob to an unintended archive. Exact-string keying cannot glob.
    #   2. (efficiency) the chain-validation inner loop re-scanned the archive dirs for every chain
    #      member, which is O(N^2) over a chain. The pre-built map makes each test O(1).
    # We honour the same exclusions as before: '.json' is not an archive, and '_BAD' artifacts are
    # failed-integrity backups that must never be offered. If two archives share a stem (should not
    # happen in the engine layout), the first one scanned wins -- matching the prior
    # `Select-Object -First 1` behaviour.
    $archivesByStem = [System.Collections.Generic.Dictionary[string, System.IO.FileInfo]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($archiveDir in @($fullDir, $incDir)) {
        # -LiteralPath: $archiveDir derives from cc_backup_root (config), which could contain
        # wildcard metacharacters ([ ] etc.); -Path would treat them as globs.
        if (-not (Test-Path -LiteralPath $archiveDir -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $archiveDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '\.json$' -and $_.Name -notmatch '_BAD\.' } |
            ForEach-Object {
                if (-not $archivesByStem.ContainsKey($_.BaseName)) {
                    $archivesByStem[$_.BaseName] = $_
                }
            }
    }

    $restorePoints = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($mf in $manifestFiles) {
        if (-not $allManifests.ContainsKey($mf.Name)) { continue }

        $manifest = $allManifests[$mf.Name]
        $manifestType = $manifest['type']
        $chainId = $manifest['chain_id']
        $chainSequence = [int]$manifest['chain_sequence']
        $timestamp = $manifest['timestamp']

        # Find the archive file via the pre-built exact-stem map (the manifest stem == the archive
        # stem). This is an exact-string match, so a wildcard char in the manifest name can never
        # glob to an unintended archive.
        $archiveFile = $null
        $archiveSizeBytes = 0

        $baseName = $mf.BaseName
        $archiveItem = $null
        if ($archivesByStem.TryGetValue($baseName, [ref]$archiveItem)) {
            $archiveFile = $archiveItem.FullName
            $archiveSizeBytes = $archiveItem.Length
        }

        # Validate the chain: every manifest from the full (seq 0) to this one must exist
        $chainValid = $true

        if ($manifestType -eq 'full') {
            # Full backups just need their own archive
            $chainValid = ($null -ne $archiveFile)
        }
        else {
            # Incremental: trace back to the full
            $chainValid = ($null -ne $archiveFile)

            if ($chainValid) {
                # Check that all chain members from 0 to this sequence exist
                $chainMembers = $allManifests.Values |
                    Where-Object { $_['chain_id'] -eq $chainId } |
                    Sort-Object -Property { [int]$_['chain_sequence'] }

                # Verify we have sequence 0 (the full)
                $hasFull = $chainMembers | Where-Object { [int]$_['chain_sequence'] -eq 0 }
                if (-not $hasFull) {
                    $chainValid = $false
                }
                else {
                    # Verify sequential chain from 0 to this sequence
                    for ($i = 0; $i -le $chainSequence; $i++) {
                        $member = @($chainMembers | Where-Object { [int]$_['chain_sequence'] -eq $i })
                        # Exactly one manifest must own each sequence: zero = a gap in the chain;
                        # more than one = ambiguous/corrupt chain metadata. Either is not a valid
                        # restorable chain -- and treating the array as a scalar would make
                        # $member['_source_filename'] an array and throw below, aborting discovery.
                        if ($member.Count -ne 1) {
                            $chainValid = $false
                            break
                        }

                        # Check that the member's archive exists -- O(1) exact-stem lookup against
                        # the map built once above (no per-member directory scan, no globbing).
                        $memberName = $member[0]['_source_filename']
                        $memberBaseName = [System.IO.Path]::GetFileNameWithoutExtension($memberName)

                        if (-not $archivesByStem.ContainsKey($memberBaseName)) {
                            $chainValid = $false
                            break
                        }
                    }
                }
            }
        }

        $restorePoints.Add([PSCustomObject]@{
            ManifestFile  = $mf.FullName
            Timestamp     = $timestamp
            Type          = $manifestType
            ChainId       = $chainId
            ChainSequence = $chainSequence
            ArchiveFile   = $archiveFile
            SizeBytes     = $archiveSizeBytes
            ChainValid    = $chainValid
        })
    }

    return $restorePoints.ToArray()
}
