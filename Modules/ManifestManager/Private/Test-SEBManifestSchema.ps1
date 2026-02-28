function Test-SEBManifestSchema {
    <#
    .SYNOPSIS
        Validates that a manifest hashtable contains all required fields with correct types.

    .DESCRIPTION
        Checks the structure of a manifest hashtable against the SEBackup manifest schema.
        Validates the presence and type of all required top-level fields:

        - version (int, must be 2)
        - type (string, "full" or "incremental")
        - chain_id (string, GUID format)
        - chain_sequence (int, >= 0)
        - parent_manifest (string or null)
        - timestamp (string, ISO 8601)
        - files (hashtable)
        - deleted_files (array)

        For each entry in the files hashtable, validates that it contains size (int),
        sha256 (string), and last_write (string) fields.

        Returns $true if the manifest passes all checks. Throws a terminating error
        with details about the first validation failure encountered.

    .PARAMETER Manifest
        The manifest hashtable to validate.

    .EXAMPLE
        $manifest = Read-SEBManifest -Path "C:\Backups\manifest.json"
        Test-SEBManifestSchema -Manifest $manifest

    .OUTPUTS
        System.Boolean
        Returns $true if validation passes. Throws on failure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Manifest
    )

    # Check required top-level fields
    $requiredFields = @(
        @{ Name = 'version';          Type = [int] }
        @{ Name = 'type';             Type = [string] }
        @{ Name = 'chain_id';         Type = [string] }
        @{ Name = 'chain_sequence';   Type = [int] }
        @{ Name = 'timestamp';        Type = [string] }
    )

    foreach ($field in $requiredFields) {
        if (-not $Manifest.ContainsKey($field.Name)) {
            throw "Manifest validation failed: missing required field '$($field.Name)'."
        }

        $value = $Manifest[$field.Name]
        if ($null -eq $value) {
            throw "Manifest validation failed: field '$($field.Name)' is null."
        }

        # Allow flexible numeric type matching for version and chain_sequence
        if ($field.Type -eq [int]) {
            if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [int64]) {
                throw "Manifest validation failed: field '$($field.Name)' must be an integer, got '$($value.GetType().Name)'."
            }
        }
        elseif ($value -isnot $field.Type) {
            throw "Manifest validation failed: field '$($field.Name)' must be type '$($field.Type.Name)', got '$($value.GetType().Name)'."
        }
    }

    # Validate version
    if ($Manifest['version'] -ne 2) {
        throw "Manifest validation failed: unsupported version '$($Manifest['version'])', expected 2."
    }

    # Validate type
    if ($Manifest['type'] -notin @('full', 'incremental')) {
        throw "Manifest validation failed: type must be 'full' or 'incremental', got '$($Manifest['type'])'."
    }

    # parent_manifest must be present (can be null for full backups)
    if (-not $Manifest.ContainsKey('parent_manifest')) {
        throw "Manifest validation failed: missing required field 'parent_manifest'."
    }

    # For incremental backups, parent_manifest must not be null
    if ($Manifest['type'] -eq 'incremental' -and [string]::IsNullOrWhiteSpace($Manifest['parent_manifest'])) {
        throw "Manifest validation failed: incremental manifest must have a non-null 'parent_manifest'."
    }

    # Validate files field
    if (-not $Manifest.ContainsKey('files')) {
        throw "Manifest validation failed: missing required field 'files'."
    }
    if ($Manifest['files'] -isnot [hashtable]) {
        throw "Manifest validation failed: 'files' must be a hashtable."
    }

    # Validate deleted_files field
    if (-not $Manifest.ContainsKey('deleted_files')) {
        throw "Manifest validation failed: missing required field 'deleted_files'."
    }
    if ($Manifest['deleted_files'] -isnot [array]) {
        throw "Manifest validation failed: 'deleted_files' must be an array."
    }

    # Validate individual file entries (spot-check structure)
    foreach ($relPath in $Manifest['files'].Keys) {
        $entry = $Manifest['files'][$relPath]

        if ($entry -isnot [hashtable]) {
            throw "Manifest validation failed: file entry '$relPath' must be a hashtable."
        }

        foreach ($requiredKey in @('size', 'sha256', 'last_write')) {
            if (-not $entry.ContainsKey($requiredKey)) {
                throw "Manifest validation failed: file entry '$relPath' is missing required key '$requiredKey'."
            }
        }

        if ($null -eq $entry['sha256'] -or $entry['sha256'] -isnot [string]) {
            throw "Manifest validation failed: file entry '$relPath' has invalid 'sha256' (must be a non-null string)."
        }

        if ($null -eq $entry['last_write'] -or $entry['last_write'] -isnot [string]) {
            throw "Manifest validation failed: file entry '$relPath' has invalid 'last_write' (must be a non-null string)."
        }
    }

    # Validate chain_id looks like a GUID
    $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($Manifest['chain_id'] -notmatch $guidPattern) {
        throw "Manifest validation failed: 'chain_id' does not appear to be a valid GUID: '$($Manifest['chain_id'])'."
    }

    # Validate timestamp looks like ISO 8601
    try {
        [datetime]::Parse($Manifest['timestamp']) | Out-Null
    }
    catch {
        throw "Manifest validation failed: 'timestamp' is not a valid ISO 8601 datetime: '$($Manifest['timestamp'])'."
    }

    return $true
}
