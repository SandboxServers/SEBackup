#Requires -Module Pester

# NAS retention must be chain-aware: an old full whose chain still has a recent incremental
# must NOT be deleted by age, or the surviving incrementals become unrestorable.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    function New-Manifest {
        param([string]$Dir, [string]$Name, [string]$Type, [string]$ChainId, [int]$Seq)
        $m = @{
            version = 2; type = $Type; chain_id = $ChainId; chain_sequence = $Seq
            parent_manifest = $(if ($Type -eq 'incremental') { 'parent.json' } else { $null })
            timestamp = [datetime]::UtcNow.ToString('o')
            files = @{ 'Sandbox.sbc' = @{ size = 1; sha256 = ('a' * 64); last_write = [datetime]::UtcNow.ToString('o') } }
            deleted_files = @()
        }
        $m | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Dir $Name)
    }
}

Describe 'Remove-SEBExpiredBackups NAS chain awareness' {
    It 'keeps an old full on NAS while its chain has an incremental within the retention window' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sebret_" + [guid]::NewGuid().ToString('n'))
        $cc = Join-Path $root 'cc'
        $nas = Join-Path $root 'nas'
        $inst = 'Survival'
        $ccManifests = Join-Path (Join-Path $cc $inst) 'manifests'
        $nasFull = Join-Path (Join-Path $nas $inst) 'full'
        $nasInc = Join-Path (Join-Path $nas $inst) 'incremental'
        New-Item -Path $ccManifests, $nasFull, $nasInc -ItemType Directory -Force | Out-Null
        try {
            $chainId = [guid]::NewGuid().ToString()
            # C&C manifests provide the archive -> chain_id mapping NAS relies on.
            New-Manifest -Dir $ccManifests -Name 'Survival_FULL_20260101_000000.json' -Type 'full'        -ChainId $chainId -Seq 0
            New-Manifest -Dir $ccManifests -Name 'Survival_INC_20260601_000000.json'  -Type 'incremental' -ChainId $chainId -Seq 1

            # NAS archives: full is old (beyond cutoff), incremental is recent (within window).
            $fullArchive = Join-Path $nasFull 'Survival_FULL_20260101_000000.7z'
            $incArchive  = Join-Path $nasInc  'Survival_INC_20260601_000000.7z'
            Set-Content -LiteralPath $fullArchive -Value 'full' -NoNewline
            Set-Content -LiteralPath $incArchive  -Value 'inc'  -NoNewline
            (Get-Item $fullArchive).LastWriteTime = (Get-Date).AddDays(-90)
            (Get-Item $incArchive).LastWriteTime  = (Get-Date).AddDays(-3)

            $config = @{
                storage   = @{ cc_backup_root = $cc; nas_backup_path = $nas }
                retention = @{ cc_full_count = 10; nas_retention_days = 30 }
            }

            Remove-SEBExpiredBackups -InstanceName $inst -GlobalConfig $config | Out-Null

            Test-Path -LiteralPath $fullArchive | Should -BeTrue -Because "its chain still has an incremental within the retention window"
            Test-Path -LiteralPath $incArchive  | Should -BeTrue -Because "the incremental is newer than the cutoff"
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'deletes a whole chain from NAS once its newest member is beyond the cutoff' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sebret_" + [guid]::NewGuid().ToString('n'))
        $cc = Join-Path $root 'cc'
        $nas = Join-Path $root 'nas'
        $inst = 'Survival'
        $ccManifests = Join-Path (Join-Path $cc $inst) 'manifests'
        $nasFull = Join-Path (Join-Path $nas $inst) 'full'
        New-Item -Path $ccManifests, $nasFull -ItemType Directory -Force | Out-Null
        try {
            $chainId = [guid]::NewGuid().ToString()
            New-Manifest -Dir $ccManifests -Name 'Survival_FULL_20250101_000000.json' -Type 'full' -ChainId $chainId -Seq 0
            $fullArchive = Join-Path $nasFull 'Survival_FULL_20250101_000000.7z'
            Set-Content -LiteralPath $fullArchive -Value 'full' -NoNewline
            (Get-Item $fullArchive).LastWriteTime = (Get-Date).AddDays(-120)

            $config = @{
                storage   = @{ cc_backup_root = $cc; nas_backup_path = $nas }
                retention = @{ cc_full_count = 10; nas_retention_days = 30 }
            }

            Remove-SEBExpiredBackups -InstanceName $inst -GlobalConfig $config | Out-Null
            Test-Path -LiteralPath $fullArchive | Should -BeFalse -Because "the entire chain is older than the retention window"
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
