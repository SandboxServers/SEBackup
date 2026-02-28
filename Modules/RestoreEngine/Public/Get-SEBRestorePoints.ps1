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

    $manifestFiles = Get-ChildItem -Path $manifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Descending

    if (-not $manifestFiles -or $manifestFiles.Count -eq 0) {
        Write-Verbose "No manifest files found for '$InstanceName'."
        return @()
    }

    # Build a lookup of all manifests by chain_id for chain validation
    $allManifests = @{}
    foreach ($mf in $manifestFiles) {
        try {
            $content = Get-Content -Path $mf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $content['_source_filename'] = $mf.Name
            $content['_full_path'] = $mf.FullName
            $allManifests[$mf.Name] = $content
        }
        catch {
            Write-Warning "Failed to read manifest '$($mf.Name)': $_"
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

        # Find the archive file
        $archiveFile = $null
        $archiveSizeBytes = 0

        $searchDir = if ($manifestType -eq 'full') { $fullDir } else { $incDir }
        $baseName = $mf.BaseName

        if (Test-Path -Path $searchDir -PathType Container) {
            $candidates = Get-ChildItem -Path $searchDir -Filter "${baseName}.*" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '\.json$' }
            if ($candidates) {
                $archiveItem = $candidates | Select-Object -First 1
                $archiveFile = $archiveItem.FullName
                $archiveSizeBytes = $archiveItem.Length
            }
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
                        $member = $chainMembers | Where-Object { [int]$_['chain_sequence'] -eq $i }
                        if (-not $member) {
                            $chainValid = $false
                            break
                        }

                        # Check that the member's archive exists
                        $memberName = $member['_source_filename']
                        $memberBaseName = [System.IO.Path]::GetFileNameWithoutExtension($memberName)
                        $memberType = $member['type']
                        $memberSearchDir = if ($memberType -eq 'full') { $fullDir } else { $incDir }

                        if (Test-Path -Path $memberSearchDir -PathType Container) {
                            $memberArchives = Get-ChildItem -Path $memberSearchDir -Filter "${memberBaseName}.*" -File -ErrorAction SilentlyContinue |
                                Where-Object { $_.Name -notmatch '\.json$' }
                            if (-not $memberArchives) {
                                $chainValid = $false
                                break
                            }
                        }
                        else {
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
