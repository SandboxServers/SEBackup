function Remove-SEBExpiredBackups {
    <#
    .SYNOPSIS
        Removes expired backups according to the three-tier retention policy.

    .DESCRIPTION
        Implements three-tier retention cleanup for a specific Space Engineers
        Torch server instance:

        Tier 1 (Node): Only the latest full backup is kept on the node staging
        area. All older fulls and incrementals are removed. This cleanup is
        handled during the backup process itself, not here.

        Tier 2 (C&C): Retains the most recent cc_full_count full backups and
        their associated incremental chains. Older full backups and their
        chains are deleted.

        Tier 3 (NAS): Retains all backups within nas_retention_days. Backups
        older than the retention window are deleted.

        Also cleans up orphaned manifests (manifests without corresponding
        archive files).

    .PARAMETER InstanceName
        The name of the Space Engineers server instance whose expired backups
        to remove.

    .PARAMETER GlobalConfig
        The global configuration hashtable (from Get-SEBGlobalConfig). Must
        include retention settings (cc_full_count, nas_retention_days) and
        storage paths.

    .EXAMPLE
        $config = Get-SEBGlobalConfig
        Remove-SEBExpiredBackups -InstanceName 'PvPArena' -GlobalConfig $config

    .EXAMPLE
        # Called automatically at the end of Invoke-SEBBackup
        Remove-SEBExpiredBackups -InstanceName $instanceName -GlobalConfig $globalConfig

    .OUTPUTS
        PSCustomObject
        An object with properties: RemovedCC (int), RemovedNAS (int),
        OrphanedManifestsRemoved (int), Errors (string[]).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [hashtable]$GlobalConfig
    )

    $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue
    $removedCC = 0
    $removedNAS = 0
    $orphansRemoved = 0
    $errors = [System.Collections.Generic.List[string]]::new()

    $ccBackupRoot = $GlobalConfig.storage.cc_backup_root
    $nasPath = $GlobalConfig.storage.nas_backup_path
    $ccFullCount = [int]$GlobalConfig.retention.cc_full_count
    $nasRetentionDays = [int]$GlobalConfig.retention.nas_retention_days

    # =========================================================================
    # TIER 2: C&C Retention
    # =========================================================================
    $ccInstanceDir = Join-Path -Path $ccBackupRoot -ChildPath $InstanceName
    $ccFullDir = Join-Path -Path $ccInstanceDir -ChildPath 'full'
    $ccIncDir = Join-Path -Path $ccInstanceDir -ChildPath 'incremental'
    $ccManifestDir = Join-Path -Path $ccInstanceDir -ChildPath 'manifests'

    # Build the NAS chain map (archive base name -> chain_id) NOW, before Tier 2 deletes any
    # C&C manifests. Tier 3's chain-aware NAS retention relies on this map; if it were built
    # after Tier 2, an expired chain's manifests would already be gone, the NAS archives would
    # fall into the per-file "singleton" bucket, and an old full could be aged out while a newer
    # dependent incremental survives -- the exact orphaning chain-awareness is meant to prevent.
    $chainOf = @{}
    if (Test-Path -Path $ccManifestDir -PathType Container) {
        foreach ($mf in (Get-ChildItem -Path $ccManifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try {
                $mc = Get-Content -Path $mf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if ($mc['chain_id']) { $chainOf[$mf.BaseName] = $mc['chain_id'] }
            }
            catch {
                # Per CLAUDE.md, never silently swallow: a manifest we cannot read leaves its NAS
                # archives unmapped (treated as standalone), so record why.
                $errors.Add("Failed to read manifest '$($mf.Name)' for NAS chain map: $_")
                if ($hasLogger) {
                    Write-SEBLog -Message "Failed to read manifest '$($mf.Name)' for NAS chain map: $_" -Level WARN -Context $InstanceName
                }
            }
        }
    }

    if (Test-Path -Path $ccFullDir -PathType Container) {
        try {
            # Get all full backup archives sorted by name (timestamp) descending
            $fullArchives = Get-ChildItem -Path $ccFullDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '_FULL_' } |
                Sort-Object -Property Name -Descending

            if ($fullArchives -and $fullArchives.Count -gt $ccFullCount) {
                # Archives to remove: everything beyond the keep count
                $expiredFulls = $fullArchives | Select-Object -Skip $ccFullCount

                foreach ($expiredFull in $expiredFulls) {
                    try {
                        # Extract the timestamp portion to find matching incrementals
                        # Archive name format: {InstanceName}_FULL_{yyyyMMdd_HHmmss}.{ext}
                        if ($expiredFull.Name -match '_FULL_(\d{8}_\d{6})') {
                            $fullTimestamp = $Matches[1]
                        }

                        # Find the chain_id from the corresponding manifest
                        $fullManifestName = "${InstanceName}_FULL_${fullTimestamp}.json"
                        $fullManifestPath = Join-Path -Path $ccManifestDir -ChildPath $fullManifestName

                        $chainId = $null
                        if (Test-Path -Path $fullManifestPath -PathType Leaf) {
                            try {
                                $manifestContent = Get-Content -Path $fullManifestPath -Raw | ConvertFrom-Json -AsHashtable
                                $chainId = $manifestContent['chain_id']
                            }
                            catch {
                                $errors.Add("Failed to read manifest for chain cleanup: $_")
                            }
                        }

                        # Remove the full archive
                        Remove-Item -Path $expiredFull.FullName -Force -ErrorAction Stop
                        $removedCC++

                        if ($hasLogger) {
                            Write-SEBLog -Message "Removed expired C&C full archive: $($expiredFull.Name)" -Level INFO -Context $InstanceName
                        }

                        # Remove associated incremental chain
                        if (-not [string]::IsNullOrWhiteSpace($chainId) -and (Test-Path -Path $ccIncDir)) {
                            # Find all manifests with this chain_id
                            $chainManifests = Get-ChildItem -Path $ccManifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue
                            foreach ($cm in $chainManifests) {
                                try {
                                    $cmContent = Get-Content -Path $cm.FullName -Raw | ConvertFrom-Json -AsHashtable
                                    if ($cmContent['chain_id'] -eq $chainId -and $cmContent['type'] -eq 'incremental') {
                                        # Find and remove the matching incremental archive
                                        $incBaseName = $cm.BaseName
                                        $incArchives = Get-ChildItem -Path $ccIncDir -Filter "${incBaseName}.*" -File -ErrorAction SilentlyContinue
                                        foreach ($incArch in $incArchives) {
                                            Remove-Item -Path $incArch.FullName -Force -ErrorAction Stop
                                            $removedCC++
                                            if ($hasLogger) {
                                                Write-SEBLog -Message "Removed expired C&C incremental archive: $($incArch.Name)" -Level INFO -Context $InstanceName
                                            }
                                        }

                                        # Remove the incremental manifest
                                        Remove-Item -Path $cm.FullName -Force -ErrorAction Stop
                                        $orphansRemoved++
                                    }
                                }
                                catch {
                                    $errors.Add("Failed to clean incremental chain member '$($cm.Name)': $_")
                                }
                            }
                        }

                        # Remove the full manifest
                        if (Test-Path -Path $fullManifestPath -PathType Leaf) {
                            Remove-Item -Path $fullManifestPath -Force -ErrorAction Stop
                            $orphansRemoved++
                        }
                    }
                    catch {
                        $errors.Add("Failed to remove expired C&C archive '$($expiredFull.Name)': $_")
                    }
                }
            }
        }
        catch {
            $errors.Add("C&C retention cleanup error: $_")
        }
    }

    # =========================================================================
    # TIER 3: NAS Retention
    # =========================================================================
    if (-not [string]::IsNullOrWhiteSpace($nasPath)) {
        $nasInstanceDir = Join-Path -Path $nasPath -ChildPath $InstanceName
        if (Test-Path -Path $nasInstanceDir -PathType Container) {
            try {
                $cutoffDate = (Get-Date).AddDays(-$nasRetentionDays)

                # NAS retention must be CHAIN-AWARE: deleting a full (or an early incremental)
                # while a newer dependent incremental survives makes the survivors unrestorable.
                # NAS holds only archives, so group them into chains using the C&C manifests
                # (archive base name -> chain_id) and keep an entire chain while ANY member is
                # still within the retention window. Archives we cannot map (e.g. their manifest
                # was already pruned) are treated as standalone and aged out individually.
                # $chainOf was built at the top of this function, BEFORE Tier 2 removed manifests.
                $nasArchivesAll = Get-ChildItem -Path $nasInstanceDir -Recurse -File -ErrorAction SilentlyContinue

                # Group by chain; unmapped archives become their own singleton "chain".
                $chainGroups = @{}
                foreach ($a in $nasArchivesAll) {
                    $key = if ($chainOf.ContainsKey($a.BaseName)) { $chainOf[$a.BaseName] } else { "__single__$($a.Name)" }
                    if (-not $chainGroups.ContainsKey($key)) {
                        $chainGroups[$key] = [System.Collections.Generic.List[object]]::new()
                    }
                    $chainGroups[$key].Add($a)
                }

                $nasArchives = foreach ($key in $chainGroups.Keys) {
                    $members = $chainGroups[$key]
                    $newest = ($members | Measure-Object -Property LastWriteTime -Maximum).Maximum
                    # Only expire a chain once its NEWEST member is older than the cutoff.
                    if ($newest -lt $cutoffDate) { $members }
                }

                foreach ($nasArchive in $nasArchives) {
                    try {
                        Remove-Item -Path $nasArchive.FullName -Force -ErrorAction Stop
                        $removedNAS++

                        if ($hasLogger) {
                            Write-SEBLog -Message "Removed expired NAS archive: $($nasArchive.FullName)" -Level INFO -Context $InstanceName
                        }
                    }
                    catch {
                        $errors.Add("Failed to remove NAS archive '$($nasArchive.FullName)': $_")
                    }
                }

                # Clean up empty subdirectories on NAS
                $emptyDirs = Get-ChildItem -Path $nasInstanceDir -Recurse -Directory -ErrorAction SilentlyContinue |
                    Where-Object { (Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 } |
                    Sort-Object -Property { $_.FullName.Length } -Descending

                foreach ($emptyDir in $emptyDirs) {
                    Remove-Item -Path $emptyDir.FullName -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
                $errors.Add("NAS retention cleanup error: $_")
            }
        }
    }

    # =========================================================================
    # ORPHANED MANIFEST CLEANUP
    # =========================================================================
    if (Test-Path -Path $ccManifestDir -PathType Container) {
        try {
            $remainingManifests = Get-ChildItem -Path $ccManifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue

            foreach ($manifest in $remainingManifests) {
                $baseName = $manifest.BaseName
                $archiveFound = $false

                # Check both full and incremental directories for a matching archive
                foreach ($archiveDir in @($ccFullDir, $ccIncDir)) {
                    if (Test-Path -Path $archiveDir -PathType Container) {
                        $matchingArchives = Get-ChildItem -Path $archiveDir -Filter "${baseName}.*" -File -ErrorAction SilentlyContinue
                        if ($matchingArchives -and $matchingArchives.Count -gt 0) {
                            $archiveFound = $true
                            break
                        }
                    }
                }

                if (-not $archiveFound) {
                    try {
                        Remove-Item -Path $manifest.FullName -Force -ErrorAction Stop
                        $orphansRemoved++
                        if ($hasLogger) {
                            Write-SEBLog -Message "Removed orphaned manifest: $($manifest.Name)" -Level INFO -Context $InstanceName
                        }
                    }
                    catch {
                        $errors.Add("Failed to remove orphaned manifest '$($manifest.Name)': $_")
                    }
                }
            }
        }
        catch {
            $errors.Add("Orphaned manifest cleanup error: $_")
        }
    }

    if ($hasLogger) {
        Write-SEBLog -Message "Retention cleanup for '$InstanceName': removed $removedCC C&C, $removedNAS NAS, $orphansRemoved orphaned manifests. Errors: $($errors.Count)" -Level $(if ($errors.Count -gt 0) { 'WARN' } else { 'INFO' }) -Context $InstanceName
    }

    return [PSCustomObject]@{
        RemovedCC               = $removedCC
        RemovedNAS              = $removedNAS
        OrphanedManifestsRemoved = $orphansRemoved
        Errors                  = $errors.ToArray()
    }
}
