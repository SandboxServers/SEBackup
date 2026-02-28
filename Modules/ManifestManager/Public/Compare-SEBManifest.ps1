function Compare-SEBManifest {
    <#
    .SYNOPSIS
        Compares two SEBackup manifests and returns a detailed diff of file changes.

    .DESCRIPTION
        Analyzes the differences between a current manifest and a previous manifest by
        comparing the SHA256 hashes of all files. Classifies every file into one of
        four categories:

        - Added:     Files present in the current manifest but not in the previous.
        - Modified:  Files present in both manifests but with different SHA256 hashes.
        - Deleted:   Files present in the previous manifest but not in the current.
        - Unchanged: Files present in both manifests with identical SHA256 hashes.

        Returns a PSCustomObject containing arrays for each category and summary counts,
        used by the backup engine to determine which files need to be included in an
        incremental archive.

    .PARAMETER CurrentManifest
        The manifest hashtable representing the current state of the backup source.

    .PARAMETER PreviousManifest
        The manifest hashtable representing the previous backup state to compare against.

    .EXAMPLE
        $current = New-SEBManifest -SourcePath "E:\Shadow\Instance1" -Session $session
        $previous = Read-SEBManifest -Path "C:\Backups\Instance1\manifests\20260226_full.json"
        $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous
        Write-Host "Added: $($diff.AddedCount), Modified: $($diff.ModifiedCount), Deleted: $($diff.DeletedCount)"

    .OUTPUTS
        PSCustomObject
        An object with properties: Added, Modified, Deleted, Unchanged (arrays of
        relative file paths), plus AddedCount, ModifiedCount, DeletedCount,
        UnchangedCount, and TotalChanges summary integers.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$CurrentManifest,

        [Parameter(Mandatory)]
        [hashtable]$PreviousManifest
    )

    $currentFiles  = if ($CurrentManifest.ContainsKey('files'))  { $CurrentManifest['files'] }  else { @{} }
    $previousFiles = if ($PreviousManifest.ContainsKey('files')) { $PreviousManifest['files'] } else { @{} }

    $added     = [System.Collections.Generic.List[string]]::new()
    $modified  = [System.Collections.Generic.List[string]]::new()
    $deleted   = [System.Collections.Generic.List[string]]::new()
    $unchanged = [System.Collections.Generic.List[string]]::new()

    # Check all files in the current manifest against the previous
    foreach ($relPath in $currentFiles.Keys) {
        if ($previousFiles.ContainsKey($relPath)) {
            $currentHash  = $currentFiles[$relPath]['sha256']
            $previousHash = $previousFiles[$relPath]['sha256']

            if ($currentHash -eq $previousHash) {
                $unchanged.Add($relPath)
            }
            else {
                $modified.Add($relPath)
            }
        }
        else {
            $added.Add($relPath)
        }
    }

    # Check for files that were in the previous manifest but not in the current
    foreach ($relPath in $previousFiles.Keys) {
        if (-not $currentFiles.ContainsKey($relPath)) {
            $deleted.Add($relPath)
        }
    }

    $result = [PSCustomObject]@{
        Added          = $added.ToArray()
        Modified       = $modified.ToArray()
        Deleted        = $deleted.ToArray()
        Unchanged      = $unchanged.ToArray()
        AddedCount     = $added.Count
        ModifiedCount  = $modified.Count
        DeletedCount   = $deleted.Count
        UnchangedCount = $unchanged.Count
        TotalChanges   = $added.Count + $modified.Count + $deleted.Count
    }

    Write-Verbose "Manifest comparison complete: $($result.AddedCount) added, $($result.ModifiedCount) modified, $($result.DeletedCount) deleted, $($result.UnchangedCount) unchanged."

    return $result
}
