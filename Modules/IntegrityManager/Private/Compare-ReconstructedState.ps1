function Compare-ReconstructedState {
    <#
    .SYNOPSIS
        Compares a reconstructed directory against a manifest's expected file state.

    .DESCRIPTION
        Walks the reconstructed directory, computes SHA256 hashes for each file,
        and verifies that every file matches the corresponding entry in the
        manifest. Also checks that no expected files are missing and no unexpected
        files are present.

        This function is used internally by Test-SEBChainIntegrity as the final
        validation step of a Level 3 chain reconstruction check.

    .PARAMETER ReconstructedPath
        The root path of the reconstructed directory created by extracting and
        layering the backup chain.

    .PARAMETER Manifest
        The manifest object (from the last backup in the chain) containing the
        expected file list with relative_path (or path) and sha256 properties.

    .EXAMPLE
        $result = Compare-ReconstructedState -ReconstructedPath "C:\Temp\ChainVerify" -Manifest $lastManifest
        if ($result.IsValid) { Write-Host "Reconstruction matches manifest" }

    .OUTPUTS
        PSCustomObject
        An object with properties: IsValid (bool), Mismatches (string[]), ErrorMessage (string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ReconstructedPath,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Manifest
    )

    $compareResult = [PSCustomObject]@{
        IsValid      = $false
        Mismatches   = @()
        ErrorMessage = $null
    }

    try {
        $mismatches = [System.Collections.Generic.List[string]]::new()

        # Build expected file list from the manifest's path-keyed 'files' hashtable
        # (v2 schema: relativePath -> @{ size; sha256; last_write }). Keys are normalized
        # to forward slashes, so compare against forward-slash actual paths.
        $expectedFiles = @{}
        if ($Manifest.files) {
            foreach ($relativePath in $Manifest.files.Keys) {
                $expectedFiles[$relativePath] = $Manifest.files[$relativePath]
            }
        }

        # Get actual files in the reconstructed directory (normalize to forward slashes
        # so the keys line up with the manifest's forward-slash relative paths).
        $rootLen = $ReconstructedPath.TrimEnd('\', '/').Length
        $actualFiles = @{}
        $reconstructedItems = Get-ChildItem -Path $ReconstructedPath -Recurse -File -ErrorAction Stop
        foreach ($file in $reconstructedItems) {
            $relativePath = $file.FullName.Substring($rootLen).TrimStart('\', '/').Replace('\', '/')
            $actualFiles[$relativePath] = $file
        }

        # Check for missing files (in manifest but not reconstructed)
        foreach ($expectedPath in $expectedFiles.Keys) {
            if (-not $actualFiles.ContainsKey($expectedPath)) {
                $mismatches.Add("Missing file: $expectedPath (expected by manifest)")
            }
        }

        # Check for extra files (reconstructed but not in manifest)
        foreach ($actualPath in $actualFiles.Keys) {
            if (-not $expectedFiles.ContainsKey($actualPath)) {
                $mismatches.Add("Extra file: $actualPath (not in manifest)")
            }
        }

        # Verify SHA256 hashes for files present in both
        foreach ($expectedPath in $expectedFiles.Keys) {
            if ($actualFiles.ContainsKey($expectedPath)) {
                $expectedHash = $expectedFiles[$expectedPath].sha256
                if ($expectedHash) {
                    $actualFile = $actualFiles[$expectedPath]
                    $actualHash = (Get-FileHash -Path $actualFile.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
                    $expectedHashLower = $expectedHash.ToLower()

                    if ($actualHash -ne $expectedHashLower) {
                        $mismatches.Add("Hash mismatch for '$expectedPath': expected=$expectedHashLower, actual=$actualHash")
                    }
                }
            }
        }

        $compareResult.Mismatches = $mismatches.ToArray()
        $compareResult.IsValid = ($mismatches.Count -eq 0)

        if (-not $compareResult.IsValid) {
            $compareResult.ErrorMessage = "$($mismatches.Count) file(s) did not match the expected state."

            Write-Verbose "IntegrityManager: Reconstruction comparison found $($mismatches.Count) mismatch(es):"
            foreach ($m in $mismatches) {
                Write-Verbose "  - $m"
            }
        }
        else {
            Write-Verbose "IntegrityManager: Reconstruction matches manifest ($($expectedFiles.Count) files verified)"
        }
    }
    catch {
        $compareResult.ErrorMessage = "Comparison error: $_"

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Reconstruction comparison error: $_" -Level ERROR -Context 'Integrity'
        }
    }

    return $compareResult
}
