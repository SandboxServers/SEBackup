#Requires -Module Pester

# Get-SEBBackupType must pick the newest manifest by TIMESTAMP, not by filename. The
# filename embeds the type label (_FULL_/_INC_) before the timestamp, so a plain name
# sort can rank a newer full behind an older incremental (because 'I' > 'F'), making the
# engine attach a new incremental to the wrong baseline.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . "$repoRoot/Modules/BackupEngine/Private/Get-SEBBackupType.ps1"

    function New-ManifestFile {
        param([string]$Dir, [string]$Name, [string]$Type, [string]$Stamp, [int]$Seq, [string]$ChainId)
        $m = @{
            version         = 2
            type            = $Type
            chain_id        = $ChainId
            chain_sequence  = $Seq
            parent_manifest = $null
            timestamp       = $Stamp
            files           = @{ 'Sandbox.sbc' = @{ size = 1; sha256 = ('a' * 64); last_write = $Stamp } }
            deleted_files   = @()
        }
        $m | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Dir $Name)
    }

    $script:cfg = @{ schedule = @{ full_backup_interval_hours = 24; max_incremental_chain_length = 10 } }
}

Describe 'Get-SEBBackupType latest-manifest selection' {
    It 'selects the newest manifest by timestamp even when the name sort disagrees' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sebbt_" + [guid]::NewGuid().ToString('n'))
        $mdir = Join-Path $root 'Survival' | Join-Path -ChildPath 'manifests'
        New-Item -Path $mdir -ItemType Directory -Force | Out-Null
        try {
            $cid = [guid]::NewGuid().ToString()
            # Older incremental (name starts _INC_), NEWER full (name starts _FULL_).
            # Name-sort descending puts _INC_ first ('I' > 'F') -> wrong "latest".
            New-ManifestFile -Dir $mdir -Name 'Survival_INC_20260101_120000.json'  -Type 'incremental' -Stamp '2026-01-01T12:00:00.0000000Z' -Seq 1 -ChainId $cid
            New-ManifestFile -Dir $mdir -Name 'Survival_FULL_20260102_020000.json' -Type 'full'        -Stamp '2026-01-02T02:00:00.0000000Z' -Seq 0 -ChainId $cid

            $d = Get-SEBBackupType -InstanceName 'Survival' -GlobalConfig $script:cfg -BackupRoot $root

            $d.LastManifest['type'] | Should -Be 'full' -Because "the full at 2026-01-02 is newer than the incremental at 2026-01-01"
            $d.LastManifest['_source_filename'] | Should -Be 'Survival_FULL_20260102_020000.json'
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
