function Write-SEBManifest {
    <#
    .SYNOPSIS
        Writes an SEBackup manifest hashtable to a JSON file on disk.

    .DESCRIPTION
        Serializes a manifest hashtable to JSON and writes it to the specified path.
        Before writing, validates the manifest against the schema using
        Test-SEBManifestSchema to ensure data integrity.

        If the manifest contains 'archive_path' metadata, the function will look up
        the archive file and populate 'archive_sha256' and 'archive_size_bytes' fields
        in the written manifest. These fields enable integrity verification of the
        backup archive during restore.

        Internal metadata keys (prefixed with '_') are stripped from the output to
        keep the JSON file clean.

        Creates the parent directory if it does not exist.

    .PARAMETER Manifest
        The manifest hashtable to write. Must conform to the SEBackup manifest v2
        schema (use New-SEBManifest to generate a valid manifest).

    .PARAMETER Path
        The full path where the manifest JSON file should be written. The parent
        directory will be created if it does not exist.

    .EXAMPLE
        $manifest = New-SEBManifest -SourcePath "E:\Shadow\Instance1" -Session $session
        Write-SEBManifest -Manifest $manifest -Path "D:\Backups\Survival01\manifests\20260227_full.json"

    .OUTPUTS
        None. Writes the manifest file to disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Manifest,

        [Parameter(Mandatory)]
        [string]$Path
    )

    # Validate the manifest schema before writing
    Test-SEBManifestSchema -Manifest $Manifest | Out-Null

    # Create a clean copy without internal metadata keys (those starting with '_')
    $cleanManifest = @{}
    foreach ($key in $Manifest.Keys) {
        if (-not $key.StartsWith('_')) {
            $cleanManifest[$key] = $Manifest[$key]
        }
    }

    # If an archive file path is referenced, compute its hash and size
    if ($Manifest.ContainsKey('_archive_path') -and (Test-Path -Path $Manifest['_archive_path'] -PathType Leaf)) {
        $archivePath = $Manifest['_archive_path']
        try {
            $archiveHash = (Get-FileHash -Path $archivePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
            $archiveSize = (Get-Item -Path $archivePath -ErrorAction Stop).Length

            $cleanManifest['archive_sha256']     = $archiveHash
            $cleanManifest['archive_size_bytes']  = $archiveSize

            Write-Verbose "Archive metadata added: SHA256=$archiveHash, Size=$archiveSize bytes."
        }
        catch {
            Write-Warning "Failed to compute archive metadata for '$archivePath': $_"
        }
    }

    # Ensure the parent directory exists
    $parentDir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -Path $parentDir -PathType Container)) {
        New-Item -Path $parentDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Write-Verbose "Created manifest directory: '$parentDir'."
    }

    # Serialize to JSON with sufficient depth for nested file entries
    try {
        $jsonContent = $cleanManifest | ConvertTo-Json -Depth 10 -ErrorAction Stop
        Set-Content -Path $Path -Value $jsonContent -Encoding UTF8 -ErrorAction Stop

        Write-Verbose "Manifest written to '$Path' ($($cleanManifest['files'].Count) files)."
    }
    catch {
        throw "Failed to write manifest to '$Path': $_"
    }
}
