function Test-SEBRestoreChain {
    <#
    .SYNOPSIS
        Validates that a restore to a specific point is possible.

    .DESCRIPTION
        Tests whether a restore to the specified restore point can be performed
        by verifying:

        1. The target manifest exists and is readable.
        2. All manifests in the chain from the full backup (sequence 0) to the
           target restore point exist.
        3. All corresponding archive files exist.
        4. Level 1 integrity (archive CRC/hash) passes on each archive in the
           chain.
        5. Level 2 integrity (manifest cross-check) passes on each archive.

        Returns a validation result without actually performing the restore.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance.

    .PARAMETER RestorePoint
        The manifest filename (e.g., 'PvPArena_FULL_20260227_100000.json')
        identifying the target restore point.

    .PARAMETER BackupRoot
        The root backup directory on the C&C server. If not specified, reads
        from the global config.

    .EXAMPLE
        $validation = Test-SEBRestoreChain -InstanceName 'PvPArena' `
            -RestorePoint 'PvPArena_INC_20260227_120000.json'
        if ($validation.Valid) {
            Write-Host "Restore chain is valid. $($validation.ChainLength) archives in chain."
        } else {
            Write-Error "Chain invalid: $($validation.Errors -join '; ')"
        }

    .OUTPUTS
        PSCustomObject
        An object with: Valid (bool), ChainLength (int), ChainManifests (string[]),
        ChainArchives (string[]), Errors (string[]), Warnings (string[]).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RestorePoint,

        [Parameter()]
        [string]$BackupRoot
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $chainWarnings = [System.Collections.Generic.List[string]]::new()
    $chainManifests = [System.Collections.Generic.List[string]]::new()
    $chainArchives = [System.Collections.Generic.List[string]]::new()

    # Resolve the backup root
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $globalConfig = Get-SEBGlobalConfig
        if ($null -eq $globalConfig) {
            $errors.Add('Failed to load global config and no BackupRoot specified.')
            return [PSCustomObject]@{
                Valid          = $false
                ChainLength    = 0
                ChainManifests = @()
                ChainArchives  = @()
                Errors         = $errors.ToArray()
                Warnings       = @()
            }
        }
        $BackupRoot = $globalConfig.storage.cc_backup_root
    }

    $manifestDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName -AdditionalChildPath 'manifests'
    $fullDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName -AdditionalChildPath 'full'
    $incDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName -AdditionalChildPath 'incremental'

    # Read the target manifest
    $targetManifestPath = Join-Path -Path $manifestDir -ChildPath $RestorePoint

    if (-not (Test-Path -Path $targetManifestPath -PathType Leaf)) {
        $errors.Add("Target manifest not found: '$targetManifestPath'")
        return [PSCustomObject]@{
            Valid          = $false
            ChainLength    = 0
            ChainManifests = @()
            ChainArchives  = @()
            Errors         = $errors.ToArray()
            Warnings       = @()
        }
    }

    try {
        $targetManifest = Get-Content -Path $targetManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        $errors.Add("Failed to parse target manifest: $_")
        return [PSCustomObject]@{
            Valid          = $false
            ChainLength    = 0
            ChainManifests = @()
            ChainArchives  = @()
            Errors         = $errors.ToArray()
            Warnings       = @()
        }
    }

    $chainId = $targetManifest['chain_id']
    $targetSequence = [int]$targetManifest['chain_sequence']

    # Load all manifests for this chain
    $allManifestFiles = Get-ChildItem -Path $manifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue
    $chainMembers = @{}

    foreach ($mf in $allManifestFiles) {
        try {
            $content = Get-Content -Path $mf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($content['chain_id'] -eq $chainId) {
                $seq = [int]$content['chain_sequence']
                $chainMembers[$seq] = @{
                    Manifest     = $content
                    ManifestPath = $mf.FullName
                    ManifestName = $mf.Name
                }
            }
        }
        catch {
            $chainWarnings.Add("Could not parse manifest '$($mf.Name)': $_")
        }
    }

    # Verify we have every sequence from 0 to targetSequence
    for ($seq = 0; $seq -le $targetSequence; $seq++) {
        if (-not $chainMembers.ContainsKey($seq)) {
            $errors.Add("Missing chain member at sequence $seq (chain_id: $chainId).")
            continue
        }

        $member = $chainMembers[$seq]
        $memberManifest = $member.Manifest
        $memberType = $memberManifest['type']
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($member.ManifestName)

        $chainManifests.Add($member.ManifestPath)

        # Find the archive
        $searchDir = if ($memberType -eq 'full') { $fullDir } else { $incDir }
        $archivePath = $null

        if (Test-Path -Path $searchDir -PathType Container) {
            $candidates = Get-ChildItem -Path $searchDir -Filter "${baseName}.*" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '\.json$' }
            if ($candidates) {
                $archivePath = ($candidates | Select-Object -First 1).FullName
            }
        }

        if ($null -eq $archivePath) {
            $errors.Add("Archive not found for chain sequence $seq (manifest: $($member.ManifestName)).")
            continue
        }

        $chainArchives.Add($archivePath)

        # Level 1: Archive integrity
        try {
            $level1 = Test-SEBArchiveIntegrity -ArchivePath $archivePath
            if (-not $level1.Passed) {
                $errors.Add("Level 1 integrity FAILED for sequence $seq archive '$archivePath': $($level1.ErrorMessage)")
            }
        }
        catch {
            $errors.Add("Level 1 integrity check threw error for sequence ${seq}: $_")
        }

        # Level 2: Manifest integrity
        try {
            $level2 = Test-SEBManifestIntegrity -ManifestPath $member.ManifestPath -ArchivePath $archivePath
            if (-not $level2.Passed) {
                $errors.Add("Level 2 integrity FAILED for sequence ${seq}: $($level2.ErrorMessage)")
            }
        }
        catch {
            $chainWarnings.Add("Level 2 integrity check threw error for sequence $seq (non-fatal): $_")
        }
    }

    $isValid = ($errors.Count -eq 0)

    return [PSCustomObject]@{
        Valid          = $isValid
        ChainLength    = $chainArchives.Count
        ChainManifests = $chainManifests.ToArray()
        ChainArchives  = $chainArchives.ToArray()
        Errors         = $errors.ToArray()
        Warnings       = $chainWarnings.ToArray()
    }
}
