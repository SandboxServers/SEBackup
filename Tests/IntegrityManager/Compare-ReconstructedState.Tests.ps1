#Requires -Module Pester

# Compare-ReconstructedState is the decisive Level-3 check: does a reconstructed world
# match the last manifest? It must read the manifest's path-keyed 'files' hashtable
# (v2 schema) and compare against the on-disk files using normalized forward-slash keys.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . "$repoRoot/Modules/IntegrityManager/Private/Compare-ReconstructedState.ps1"

    function New-TestWorld {
        param([hashtable]$Files)  # relativePath (forward slash) -> content
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("sebtest_" + [guid]::NewGuid().ToString('n'))
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        foreach ($rel in $Files.Keys) {
            $full = Join-Path $dir ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $parent = Split-Path $full -Parent
            if (-not (Test-Path $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
            Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
        }
        return $dir
    }

    function New-ManifestFor {
        param([string]$Dir)  # build a v2-style path-keyed files hashtable from a directory
        $files = @{}
        Get-ChildItem -Path $Dir -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($Dir.Length).TrimStart('\', '/').Replace('\', '/')
            $files[$rel] = @{
                size       = $_.Length
                sha256     = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()
                last_write = $_.LastWriteTimeUtc.ToString('o')
            }
        }
        return @{ files = $files }
    }
}

Describe 'Compare-ReconstructedState' {
    It 'validates a directory that matches the manifest' {
        $dir = New-TestWorld -Files @{ 'Sandbox.sbc' = 'world'; 'sub/SANDBOX_0_0_0_.sbs' = 'sector' }
        try {
            $manifest = New-ManifestFor -Dir $dir
            $r = Compare-ReconstructedState -ReconstructedPath $dir -Manifest $manifest
            $r.IsValid | Should -BeTrue -Because "every file is present with a matching hash"
            $r.Mismatches.Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'detects a tampered file (hash mismatch)' {
        $dir = New-TestWorld -Files @{ 'Sandbox.sbc' = 'world' }
        try {
            $manifest = New-ManifestFor -Dir $dir
            Set-Content -LiteralPath (Join-Path $dir 'Sandbox.sbc') -Value 'TAMPERED' -NoNewline
            $r = Compare-ReconstructedState -ReconstructedPath $dir -Manifest $manifest
            $r.IsValid | Should -BeFalse -Because "the file content changed after the manifest was built"
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'detects a missing file' {
        $dir = New-TestWorld -Files @{ 'Sandbox.sbc' = 'world'; 'extra.dat' = 'x' }
        try {
            $manifest = New-ManifestFor -Dir $dir
            Remove-Item -LiteralPath (Join-Path $dir 'extra.dat') -Force
            $r = Compare-ReconstructedState -ReconstructedPath $dir -Manifest $manifest
            $r.IsValid | Should -BeFalse -Because "a file expected by the manifest is gone"
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
