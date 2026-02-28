function Get-SEBLatestManifest {
    <#
    .SYNOPSIS
        Finds and returns the most recent SEBackup manifest for a server instance.

    .DESCRIPTION
        Searches the manifest directory for the specified instance under the backup
        root, looking for JSON manifest files. Reads all manifests, optionally filters
        by type (full or incremental), and returns the one with the most recent
        timestamp.

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

    .EXAMPLE
        $latest = Get-SEBLatestManifest -InstanceName "Survival01" -BackupRoot "D:\Backups"
        if ($null -eq $latest) {
            Write-Host "No previous backups found. A full backup will be created."
        }

    .EXAMPLE
        $latestFull = Get-SEBLatestManifest -InstanceName "Survival01" -BackupRoot "D:\Backups" -Type "full"

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
        [string]$Type
    )

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

        # Parse timestamp and track the latest
        try {
            $timestamp = [datetime]::Parse($manifest['timestamp'])
        }
        catch {
            Write-Warning "Skipping manifest '$($file.Name)' with unparseable timestamp: '$($manifest['timestamp'])'."
            continue
        }

        if ($timestamp -gt $latestTimestamp) {
            $latestTimestamp = $timestamp
            $latestManifest = $manifest
        }
    }

    if ($null -eq $latestManifest) {
        Write-Verbose "No matching manifests found$(if ($Type) { " of type '$Type'" })."
        return $null
    }

    Write-Verbose "Latest manifest: '$($latestManifest['_source_filename'])', type=$($latestManifest['type']), timestamp=$($latestManifest['timestamp'])."

    return $latestManifest
}
