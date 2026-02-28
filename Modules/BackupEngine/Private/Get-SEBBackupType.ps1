function Get-SEBBackupType {
    <#
    .SYNOPSIS
        Determines whether the next backup should be full or incremental.

    .DESCRIPTION
        Applies the backup type decision logic based on configuration thresholds
        and backup history:

        1. No previous backup exists -> Full
        2. Hours since last full >= full_backup_interval_hours -> Full
        3. Current chain sequence >= max_incremental_chain_length -> Full
        4. Otherwise -> Incremental

        The ForceFull parameter always overrides the decision to force a full backup.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance.

    .PARAMETER GlobalConfig
        The global configuration hashtable (from Get-SEBGlobalConfig).

    .PARAMETER BackupRoot
        The root backup directory on the C&C server (e.g., C:\SEBackup\Backups).

    .PARAMETER ForceFull
        When specified, forces a full backup regardless of the decision logic.

    .EXAMPLE
        $decision = Get-SEBBackupType -InstanceName 'PvPArena' -GlobalConfig $config -BackupRoot 'C:\SEBackup\Backups'
        Write-Host "Backup type: $($decision.Type), Reason: $($decision.Reason)"

    .OUTPUTS
        PSCustomObject
        An object with properties: Type (string: 'full' or 'incremental'),
        Reason (string), LastFullManifest (hashtable or null),
        LastManifest (hashtable or null), ChainId (string or null),
        ChainSequence (int).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [hashtable]$GlobalConfig,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot,

        [Parameter()]
        [switch]$ForceFull
    )

    $fullIntervalHours = $GlobalConfig.schedule.full_backup_interval_hours
    $maxChainLength = $GlobalConfig.schedule.max_incremental_chain_length

    # Return early if forced
    if ($ForceFull) {
        return [PSCustomObject]@{
            Type             = 'full'
            Reason           = 'ForceFull parameter specified.'
            LastFullManifest = $null
            LastManifest     = $null
            ChainId          = $null
            ChainSequence    = 0
        }
    }

    # Find the latest manifest for this instance
    $manifestDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName -AdditionalChildPath 'manifests'

    if (-not (Test-Path -Path $manifestDir -PathType Container)) {
        return [PSCustomObject]@{
            Type             = 'full'
            Reason           = "No manifest directory found at '$manifestDir'. First backup for this instance."
            LastFullManifest = $null
            LastManifest     = $null
            ChainId          = $null
            ChainSequence    = 0
        }
    }

    # Get all manifest files sorted by name (which includes timestamp) descending
    $manifestFiles = Get-ChildItem -Path $manifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Descending

    if (-not $manifestFiles -or $manifestFiles.Count -eq 0) {
        return [PSCustomObject]@{
            Type             = 'full'
            Reason           = 'No manifests found. First backup for this instance.'
            LastFullManifest = $null
            LastManifest     = $null
            ChainId          = $null
            ChainSequence    = 0
        }
    }

    # Read the latest manifest
    $lastManifest = $null
    $lastFullManifest = $null

    foreach ($mf in $manifestFiles) {
        try {
            $content = Get-Content -Path $mf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $content['_source_filename'] = $mf.Name

            if ($null -eq $lastManifest) {
                $lastManifest = $content
            }

            if ($content['type'] -eq 'full') {
                $lastFullManifest = $content
                break
            }
        }
        catch {
            Write-Warning "Failed to read manifest '$($mf.Name)': $_"
            continue
        }
    }

    # Decision 1: No full backup found
    if ($null -eq $lastFullManifest) {
        return [PSCustomObject]@{
            Type             = 'full'
            Reason           = 'No previous full backup found in manifest history.'
            LastFullManifest = $null
            LastManifest     = $lastManifest
            ChainId          = $null
            ChainSequence    = 0
        }
    }

    # Decision 2: Hours since last full exceeds threshold
    try {
        $lastFullTimestamp = [datetime]::Parse($lastFullManifest['timestamp'])
        $hoursSinceLastFull = ([datetime]::UtcNow - $lastFullTimestamp).TotalHours
    }
    catch {
        Write-Warning "Could not parse timestamp from last full manifest. Defaulting to full backup."
        return [PSCustomObject]@{
            Type             = 'full'
            Reason           = "Could not parse last full backup timestamp. Defaulting to full."
            LastFullManifest = $lastFullManifest
            LastManifest     = $lastManifest
            ChainId          = $null
            ChainSequence    = 0
        }
    }

    if ($hoursSinceLastFull -ge $fullIntervalHours) {
        return [PSCustomObject]@{
            Type             = 'full'
            Reason           = "Hours since last full ($([math]::Round($hoursSinceLastFull, 1))h) >= threshold (${fullIntervalHours}h)."
            LastFullManifest = $lastFullManifest
            LastManifest     = $lastManifest
            ChainId          = $null
            ChainSequence    = 0
        }
    }

    # Decision 3: Chain length exceeds threshold
    $currentChainSequence = if ($lastManifest.ContainsKey('chain_sequence')) { [int]$lastManifest['chain_sequence'] } else { 0 }
    $currentChainId = if ($lastManifest.ContainsKey('chain_id')) { $lastManifest['chain_id'] } else { $null }

    if ($currentChainSequence -ge $maxChainLength) {
        return [PSCustomObject]@{
            Type             = 'full'
            Reason           = "Chain sequence ($currentChainSequence) >= max chain length ($maxChainLength)."
            LastFullManifest = $lastFullManifest
            LastManifest     = $lastManifest
            ChainId          = $null
            ChainSequence    = 0
        }
    }

    # Decision 4: Incremental
    return [PSCustomObject]@{
        Type             = 'incremental'
        Reason           = "Incremental backup. Last full $([math]::Round($hoursSinceLastFull, 1))h ago. Chain sequence: $currentChainSequence/$maxChainLength."
        LastFullManifest = $lastFullManifest
        LastManifest     = $lastManifest
        ChainId          = $currentChainId
        ChainSequence    = $currentChainSequence + 1
    }
}
