function Get-SEBManifestChain {
    <#
    .SYNOPSIS
        Walks the parent_manifest chain to reconstruct the full backup chain from a
        full backup through all incrementals up to the target manifest.

    .DESCRIPTION
        Starting from the specified target manifest file, reads each manifest and
        follows the parent_manifest reference backwards until it reaches the full
        backup (where parent_manifest is null). Returns the chain as an ordered array
        from the full backup to the target.

        Validates that every manifest file in the chain exists on disk. Throws a
        terminating error if any link in the chain is missing (broken chain), which
        prevents an incomplete restore from proceeding.

        The chain is essential for incremental restores: the restore engine must apply
        the full backup first, then each incremental in sequence.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance whose backup chain to resolve.
        Used to locate the manifests directory under the backup root.

    .PARAMETER TargetManifest
        The filename (not full path) of the manifest to start from. This is typically
        the most recent incremental or the specific backup to restore.

    .PARAMETER BackupRoot
        The root path of the backup storage. Manifests are expected at:
        {BackupRoot}\{InstanceName}\manifests\

    .EXAMPLE
        $chain = Get-SEBManifestChain -InstanceName "Survival01" -TargetManifest "20260227_inc_003.json" -BackupRoot "D:\Backups"
        # Returns: @( {full manifest}, {inc_001 manifest}, {inc_002 manifest}, {inc_003 manifest} )

    .OUTPUTS
        System.Collections.Hashtable[]
        An ordered array of manifest hashtables from the full backup to the target.
        Each hashtable includes a '_source_filename' key with the manifest filename.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [string]$TargetManifest,

        [Parameter(Mandatory)]
        [string]$BackupRoot
    )

    $manifestDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName | Join-Path -ChildPath 'manifests'

    if (-not (Test-Path -Path $manifestDir -PathType Container)) {
        throw "Manifest directory not found: '$manifestDir'."
    }

    # Walk backwards from target to full, collecting manifests
    $chain = [System.Collections.Generic.List[hashtable]]::new()
    $currentFilename = $TargetManifest
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    while ($null -ne $currentFilename -and $currentFilename -ne '') {
        # Circular reference protection
        if (-not $visited.Add($currentFilename)) {
            throw "Circular reference detected in manifest chain at '$currentFilename'."
        }

        $manifestPath = Join-Path -Path $manifestDir -ChildPath $currentFilename

        if (-not (Test-Path -Path $manifestPath -PathType Leaf)) {
            throw "Broken manifest chain: file '$currentFilename' not found in '$manifestDir'. The backup chain is incomplete and cannot be used for restore."
        }

        $manifest = Read-SEBManifest -Path $manifestPath
        $chain.Add($manifest)

        # Follow the parent_manifest reference
        $currentFilename = $manifest['parent_manifest']
    }

    if ($chain.Count -eq 0) {
        throw "No manifests found in chain starting from '$TargetManifest'."
    }

    # Validate the first manifest in the reversed chain is a full backup
    $chain.Reverse()

    $firstManifest = $chain[0]
    if ($firstManifest['type'] -ne 'full') {
        throw "Manifest chain does not start with a full backup. The root manifest '$($firstManifest['_source_filename'])' has type '$($firstManifest['type'])'. The chain is broken or incomplete."
    }

    # Validate chain_sequence ordering
    for ($i = 0; $i -lt $chain.Count; $i++) {
        $expected = $i
        $actual = [int]$chain[$i]['chain_sequence']
        if ($actual -ne $expected) {
            Write-Warning "Chain sequence mismatch at position $i: expected $expected, got $actual in manifest '$($chain[$i]['_source_filename'])'."
        }
    }

    Write-Verbose "Resolved manifest chain with $($chain.Count) manifest(s): $( ($chain | ForEach-Object { $_['_source_filename'] }) -join ' -> ' )"

    return $chain.ToArray()
}
