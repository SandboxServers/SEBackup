function Resolve-SEBChainArchivePath {
    <#
    .SYNOPSIS
        Safely resolves the on-disk archive path for a chain manifest, with traversal guards.

    .DESCRIPTION
        A manifest's 'archive_path' and 'type' are data read from a JSON file in the C&C or NAS
        store. Test-SEBChainIntegrity (and, transitively, restore) extract whatever path they
        resolve to, so a tampered manifest could otherwise direct extraction to an arbitrary
        location (zip-slip-style path injection). This helper:

        - Rejects a 'type' that is not 'full' or 'incremental' (it becomes a directory segment).
        - Requires 'archive_path' to be a bare filename: no directory separators, no '..', not
          rooted. Anything else resolves to $null (treated as "archive not found").
        - Falls back, when 'archive_path' is absent (manifests written before that field existed),
          to locating the archive by the manifest's own base name under the type directory.

    .PARAMETER Manifest
        A chain manifest object (from Get-SEBManifestChain) exposing type, archive_path, and
        _source_filename.

    .PARAMETER InstanceDir
        The instance directory (<BackupRoot>/<InstanceName>) the archive lives under.

    .OUTPUTS
        System.String, or $null when the path cannot be resolved safely.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Manifest,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceDir
    )

    $type = $Manifest.type
    if ($type -notin @('full', 'incremental')) {
        Write-Verbose "Resolve-SEBChainArchivePath: rejecting manifest with invalid type '$type'."
        return $null
    }
    $typeDir = Join-Path -Path $InstanceDir -ChildPath $type

    $name = $Manifest.archive_path

    if ([string]::IsNullOrWhiteSpace($name)) {
        # Legacy fallback: archive_path predates this field. The manifest and its archive share a
        # base name (Instance_TYPE_timestamp), so locate the archive by that base name.
        $src = $Manifest._source_filename
        if ([string]::IsNullOrWhiteSpace($src)) { return $null }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($src)
        if (-not (Test-Path -Path $typeDir -PathType Container)) { return $null }
        $candidate = Get-ChildItem -Path $typeDir -Filter "${base}.*" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '\.json$' } |
            Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
        return $null
    }

    # archive_path must be a bare filename. Reject separators, traversal, and rooted paths.
    $leaf = Split-Path -Path $name -Leaf
    if ($name -ne $leaf -or $name -match '[\\/]' -or $name.Contains('..') -or [System.IO.Path]::IsPathRooted($name)) {
        Write-Verbose "Resolve-SEBChainArchivePath: rejecting unsafe archive_path '$name'."
        return $null
    }

    return Join-Path -Path $typeDir -ChildPath $name
}
