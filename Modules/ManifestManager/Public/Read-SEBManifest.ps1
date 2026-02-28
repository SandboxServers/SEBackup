function Read-SEBManifest {
    <#
    .SYNOPSIS
        Reads an SEBackup manifest JSON file and returns it as a validated hashtable.

    .DESCRIPTION
        Loads a manifest file from disk, parses the JSON content into a PowerShell
        hashtable, and validates the version field. Adds a '_source_filename' metadata
        key containing the original filename (without path), which is used by other
        ManifestManager functions to track parent references during chain traversal.

        Throws a terminating error if the file does not exist, cannot be parsed as
        JSON, or has an unsupported version number.

    .PARAMETER Path
        The full path to the manifest JSON file to read.

    .EXAMPLE
        $manifest = Read-SEBManifest -Path "D:\Backups\Survival01\manifests\20260227_full.json"
        $manifest['type']    # "full"
        $manifest['files']   # hashtable of file entries

    .OUTPUTS
        System.Collections.Hashtable
        The manifest data as a hashtable, with an additional '_source_filename' key.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Manifest file not found: '$Path'."
    }

    try {
        $jsonContent = Get-Content -Path $Path -Raw -ErrorAction Stop
        $manifest = $jsonContent | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "Failed to read or parse manifest file '$Path': $_"
    }

    if ($manifest -isnot [hashtable]) {
        throw "Manifest file '$Path' did not deserialize to a hashtable. Got type: $($manifest.GetType().Name)."
    }

    # Validate version
    if (-not $manifest.ContainsKey('version')) {
        throw "Manifest file '$Path' is missing the required 'version' field."
    }

    if ([int]$manifest['version'] -ne 2) {
        throw "Unsupported manifest version '$($manifest['version'])' in file '$Path'. Expected version 2."
    }

    # Attach source filename metadata for chain traversal
    $manifest['_source_filename'] = Split-Path -Path $Path -Leaf

    Write-Verbose "Read manifest '$Path': type=$($manifest['type']), files=$($manifest['files'].Count), chain_seq=$($manifest['chain_sequence'])."

    return $manifest
}
