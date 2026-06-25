function Get-SEBLatestManifest {
    <#
    .SYNOPSIS
        Finds and returns the most recent SEBackup manifest for a server instance.

    .DESCRIPTION
        Searches the manifest directory for the specified instance under the backup
        root, looking for JSON manifest files. Reads all manifests, optionally filters
        by type (full or incremental) and/or chain id, and returns the most recent
        match.

        When -ChainId is supplied the search is restricted to that chain and the head
        of the chain is returned (highest chain_sequence, ties broken by the most
        recent timestamp). Otherwise the latest manifest is chosen purely by timestamp.

        The manifest directory is expected at:
        {BackupRoot}\{InstanceName}\manifests\

        Returns $null if no manifests are found for the instance, allowing callers
        to detect a first-run scenario and create a full backup.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance to find the latest manifest for.

    .PARAMETER BackupRoot
        The root path of the backup storage directory.

    .PARAMETER Type
        Optional filter: "full" to return only the latest full backup manifest,
        "incremental" to return only the latest incremental. When omitted, returns
        the latest manifest of any type.

    .PARAMETER ChainId
        Optional filter restricting the search to a single backup chain. When supplied,
        only manifests whose chain_id matches are considered and the head of that chain
        is returned (highest chain_sequence, ties broken by timestamp).

    .EXAMPLE
        $latest = Get-SEBLatestManifest -InstanceName "Survival01" -BackupRoot "D:\Backups"
        if ($null -eq $latest) {
            Write-Host "No previous backups found. A full backup will be created."
        }

    .EXAMPLE
        $latestFull = Get-SEBLatestManifest -InstanceName "Survival01" -BackupRoot "D:\Backups" -Type "full"

    .EXAMPLE
        $head = Get-SEBLatestManifest -InstanceName "Survival01" -BackupRoot "D:\Backups" -ChainId "chain_20260201_020000"

    .OUTPUTS
        System.Collections.Hashtable or $null
        The most recent manifest as a hashtable, or $null if none found.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [string]$BackupRoot,

        [Parameter()]
        [ValidateSet('full', 'incremental')]
        [string]$Type,

        [Parameter()]
        [string]$ChainId
    )

    # $InstanceName becomes a directory segment ({BackupRoot}\{InstanceName}\manifests). Guard it
    # through the shared Test-SEBSafeName validator (issue #28) so a crafted name cannot redirect the
    # manifest scan outside the backup root; $null on rejection matches this function's "no manifest
    # found" contract.
    if (-not (Test-SEBSafeName -Name $InstanceName)) {
        Write-Error "Invalid InstanceName '$InstanceName': path separators, traversal, rooted paths, wildcards, and invalid filename characters are not allowed."
        return $null
    }

    $manifestDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName | Join-Path -ChildPath 'manifests'

    if (-not (Test-Path -Path $manifestDir -PathType Container)) {
        Write-Verbose "Manifest directory does not exist: '$manifestDir'. No previous backups found."
        return $null
    }

    $manifestFiles = Get-ChildItem -Path $manifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue

    if (-not $manifestFiles -or $manifestFiles.Count -eq 0) {
        Write-Verbose "No manifest files found in '$manifestDir'."
        return $null
    }

    Write-Verbose "Found $($manifestFiles.Count) manifest file(s) in '$manifestDir'."

    $latestManifest = $null
    $latestTimestamp = [datetime]::MinValue
    # Only meaningful when -ChainId restricts the search: pick the chain head by highest
    # chain_sequence, breaking ties with the most recent timestamp.
    $latestSequence = -1

    foreach ($file in $manifestFiles) {
        try {
            $manifest = Read-SEBManifest -Path $file.FullName
        }
        catch {
            Write-Warning "Skipping unreadable manifest '$($file.Name)': $_"
            continue
        }

        # Apply type filter if specified
        if ($Type -and $manifest['type'] -ne $Type) {
            continue
        }

        # Apply chain filter if specified
        if (-not [string]::IsNullOrWhiteSpace($ChainId) -and $manifest['chain_id'] -ne $ChainId) {
            continue
        }

        # Parse timestamp and track the latest
        try {
            $timestamp = [datetime]::Parse($manifest['timestamp'])
        }
        catch {
            Write-Warning "Skipping manifest '$($file.Name)' with unparseable timestamp: '$($manifest['timestamp'])'."
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($ChainId)) {
            # Chain-scoped: order by chain_sequence first, then timestamp as a tie-breaker.
            $sequence = try { [int]$manifest['chain_sequence'] } catch { -1 }
            if ($sequence -gt $latestSequence -or
                ($sequence -eq $latestSequence -and $timestamp -gt $latestTimestamp)) {
                $latestSequence = $sequence
                $latestTimestamp = $timestamp
                $latestManifest = $manifest
            }
        }
        elseif ($timestamp -gt $latestTimestamp) {
            $latestTimestamp = $timestamp
            $latestManifest = $manifest
        }
    }

    if ($null -eq $latestManifest) {
        $filterDesc = @(
            $(if ($Type) { "of type '$Type'" })
            $(if (-not [string]::IsNullOrWhiteSpace($ChainId)) { "in chain '$ChainId'" })
        ) | Where-Object { $_ }
        Write-Verbose "No matching manifests found$(if ($filterDesc) { ' ' + ($filterDesc -join ' ') })."
        return $null
    }

    Write-Verbose "Latest manifest: '$($latestManifest['_source_filename'])', type=$($latestManifest['type']), timestamp=$($latestManifest['timestamp'])."

    return $latestManifest
}
