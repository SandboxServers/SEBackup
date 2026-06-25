#Requires -Module Pester

# Write-SEBManifest must embed archive_sha256 / archive_size_bytes (so Level-2 integrity
# and restore-time verification have something to check), strip internal _-prefixed keys,
# and round-trip through Read-SEBManifest as a hashtable with a path-keyed 'files' map.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    function New-V2Manifest {
        @{
            version         = 2
            type            = 'full'
            chain_id        = [guid]::NewGuid().ToString()
            chain_sequence  = 0
            parent_manifest = $null
            timestamp       = [datetime]::UtcNow.ToString('o')
            files           = @{
                'Sandbox.sbc'             = @{ size = 5; sha256 = ('a' * 64); last_write = [datetime]::UtcNow.ToString('o') }
                'sub/SANDBOX_0_0_0_.sbs'  = @{ size = 6; sha256 = ('b' * 64); last_write = [datetime]::UtcNow.ToString('o') }
            }
            deleted_files   = @()
        }
    }
}

Describe 'Write-SEBManifest archive metadata + round-trip' {
    It 'embeds archive_sha256 and archive_size_bytes from _archive_path and strips the internal key' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sebmf_" + [guid]::NewGuid().ToString('n'))
        New-Item -Path $tmp -ItemType Directory -Force | Out-Null
        try {
            $archive = Join-Path $tmp 'backup_FULL.zip'
            Set-Content -LiteralPath $archive -Value 'ARCHIVE-BYTES' -NoNewline
            $expectedHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
            $expectedSize = (Get-Item -LiteralPath $archive).Length

            $manifest = New-V2Manifest
            $manifest['archive_path'] = 'backup_FULL.zip'
            $manifest['_archive_path'] = $archive

            $manifestPath = Join-Path $tmp 'm.json'
            Write-SEBManifest -Manifest $manifest -Path $manifestPath

            $raw = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
            $raw['archive_sha256']     | Should -Be $expectedHash
            $raw['archive_size_bytes'] | Should -Be $expectedSize
            $raw.ContainsKey('_archive_path') | Should -BeFalse -Because "internal _-prefixed keys are stripped from the JSON"
            $raw['archive_path']       | Should -Be 'backup_FULL.zip'
        }
        finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'round-trips through Read-SEBManifest with files as a path-keyed hashtable' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sebmf_" + [guid]::NewGuid().ToString('n'))
        New-Item -Path $tmp -ItemType Directory -Force | Out-Null
        try {
            $manifest = New-V2Manifest
            $manifestPath = Join-Path $tmp 'm.json'
            Write-SEBManifest -Manifest $manifest -Path $manifestPath

            $read = Read-SEBManifest -Path $manifestPath
            $read | Should -BeOfType [hashtable]
            $read['files'] | Should -BeOfType [hashtable]
            $read['files']['Sandbox.sbc']['sha256'] | Should -Be ('a' * 64)
            $read['_source_filename'] | Should -Be 'm.json'
        }
        finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
