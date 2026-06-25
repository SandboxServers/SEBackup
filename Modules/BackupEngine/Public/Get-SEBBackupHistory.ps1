function Get-SEBBackupHistory {
    <#
    .SYNOPSIS
        Retrieves the backup history for a Space Engineers Torch server instance.

    .DESCRIPTION
        Reads all manifest files from Data/backups/{InstanceName}/manifests/ and
        returns a sorted list of backup history entries. Each entry includes the
        timestamp, backup type, archive file name, size, file count, chain metadata,
        and integrity status.

        Results are sorted by timestamp in descending order (newest first) and
        limited to the specified count.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance whose backup history
        to retrieve.

    .PARAMETER Last
        The maximum number of history entries to return. Defaults to 50.

    .PARAMETER BackupRoot
        The root backup directory on the C&C server. If not specified, reads from
        the global config (storage.cc_backup_root).

    .EXAMPLE
        $history = Get-SEBBackupHistory -InstanceName 'PvPArena'
        $history | Format-Table Timestamp, Type, ArchiveFile, SizeBytes

    .EXAMPLE
        Get-SEBBackupHistory -InstanceName 'Creative' -Last 10

    .EXAMPLE
        Get-SEBBackupHistory -InstanceName 'PvPArena' -BackupRoot 'D:\Backups'

    .OUTPUTS
        PSCustomObject[]
        An array of history entries with properties: Timestamp, Type, ArchiveFile,
        SizeBytes, FileCount, ChainId, ChainSequence, IntegrityStatus, ManifestFile.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter()]
        [ValidateRange(1, 1000)]
        [int]$Last = 50,

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

    if (-not (Test-Path -Path $manifestDir -PathType Container)) {
        Write-Verbose "No manifest directory found for '$InstanceName' at '$manifestDir'."
        return @()
    }

    # Newest-first by the timestamp embedded in the filename (yyyyMMdd_HHmmss sorts
    # chronologically as text); a raw Name sort interleaves by the _FULL_/_INC_ label.
    $manifestFiles = Get-ChildItem -Path $manifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property @{ Expression = {
                if ($_.Name -match '_(\d{8}_\d{6})(?=\.[^.]+$)') { $Matches[1] } else { $_.Name }
            }
        } -Descending

    if (-not $manifestFiles -or $manifestFiles.Count -eq 0) {
        Write-Verbose "No manifest files found for '$InstanceName'."
        return @()
    }

    $history = [System.Collections.Generic.List[PSCustomObject]]::new()
    $count = 0

    foreach ($mf in $manifestFiles) {
        if ($count -ge $Last) { break }

        try {
            $content = Get-Content -Path $mf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop

            $manifestTimestamp = $content['timestamp']
            $manifestType = $content['type']
            $chainId = $content['chain_id']
            $chainSequence = [int]$content['chain_sequence']
            $fileCount = if ($content.ContainsKey('files')) { $content['files'].Count } else { 0 }

            # Derive the expected archive file name from manifest name
            $archiveBaseName = $mf.BaseName
            $fullDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName -AdditionalChildPath 'full'
            $incDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName -AdditionalChildPath 'incremental'

            # Search for matching archive
            $archiveFile = $null
            $archiveSizeBytes = 0
            $integrityStatus = 'Unknown'

            $searchDirs = @()
            if ($manifestType -eq 'full' -and (Test-Path -Path $fullDir)) { $searchDirs += $fullDir }
            if ($manifestType -eq 'incremental' -and (Test-Path -Path $incDir)) { $searchDirs += $incDir }
            # Also search both in case of misclassification
            if (Test-Path -Path $fullDir) { $searchDirs += $fullDir }
            if (Test-Path -Path $incDir) { $searchDirs += $incDir }
            $searchDirs = $searchDirs | Select-Object -Unique

            foreach ($searchDir in $searchDirs) {
                $candidates = Get-ChildItem -Path $searchDir -Filter "${archiveBaseName}.*" -File -ErrorAction SilentlyContinue
                if ($candidates) {
                    $archiveItem = $candidates | Select-Object -First 1
                    $archiveFile = $archiveItem.FullName
                    $archiveSizeBytes = $archiveItem.Length

                    if ($archiveItem.Name -match '_BAD') {
                        $integrityStatus = 'FAILED'
                    }
                    else {
                        $integrityStatus = 'Passed'
                    }
                    break
                }
            }

            if ($null -eq $archiveFile) {
                $integrityStatus = 'MissingArchive'
            }

            $history.Add([PSCustomObject]@{
                Timestamp       = $manifestTimestamp
                Type            = $manifestType
                ArchiveFile     = $archiveFile
                SizeBytes       = $archiveSizeBytes
                FileCount       = $fileCount
                ChainId         = $chainId
                ChainSequence   = $chainSequence
                IntegrityStatus = $integrityStatus
                ManifestFile    = $mf.FullName
            })

            $count++
        }
        catch {
            Write-Warning "Failed to read manifest '$($mf.Name)': $_"
        }
    }

    return $history.ToArray()
}
