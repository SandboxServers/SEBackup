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

Describe 'Remove-SEBExpiredBackups Tier-2 unparseable full name (#8)' {
    # Regression for issue #8: in the Tier-2 C&C loop, $fullTimestamp was only assigned on a
    # regex match with no else, so a full whose name lacked a valid timestamp reused the PREVIOUS
    # iteration's timestamp and pruned the WRONG chain's manifest + incrementals. A non-matching
    # name must be skipped, never mis-attributed to another chain.
    It 'does not prune another chain when an unparseable full name is processed among valid fulls' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sebret_" + [guid]::NewGuid().ToString('n'))
        $cc = Join-Path $root 'cc'
        $inst = 'Survival'
        $ccDir = Join-Path $cc $inst
        $ccFull = Join-Path $ccDir 'full'
        $ccInc = Join-Path $ccDir 'incremental'
        $ccManifests = Join-Path $ccDir 'manifests'
        New-Item -Path $ccFull, $ccInc, $ccManifests -ItemType Directory -Force | Out-Null
        try {
            # Two distinct chains, each with a full + a dependent incremental. With cc_full_count=0
            # below, BOTH chains legitimately expire; A/B just label newest vs oldest valid full so
            # we can assert each is pruned by its OWN timestamp and never via a stale one.
            $chainA = [guid]::NewGuid().ToString()   # newest valid full
            $chainB = [guid]::NewGuid().ToString()   # oldest valid full

            # Manifests (archive base name -> chain_id) for both chains.
            New-Manifest -Dir $ccManifests -Name 'Survival_FULL_20260301_000000.json' -Type 'full'        -ChainId $chainA -Seq 0
            New-Manifest -Dir $ccManifests -Name 'Survival_INC_20260302_000000.json'  -Type 'incremental' -ChainId $chainA -Seq 1
            New-Manifest -Dir $ccManifests -Name 'Survival_FULL_20260101_000000.json' -Type 'full'        -ChainId $chainB -Seq 0
            New-Manifest -Dir $ccManifests -Name 'Survival_INC_20260102_000000.json'  -Type 'incremental' -ChainId $chainB -Seq 1

            # Full archives. Sorted by name DESC the loop sees (letters sort after digits):
            #   Survival_FULL_corrupt.7z      (matches '_FULL_' filter, NO valid timestamp)
            #   Survival_FULL_20260301_000000 (chain A, newest valid)
            #   Survival_FULL_20260101_000000 (chain B, oldest valid)
            $fullA       = Join-Path $ccFull 'Survival_FULL_20260301_000000.7z'
            $fullB       = Join-Path $ccFull 'Survival_FULL_20260101_000000.7z'
            $fullCorrupt = Join-Path $ccFull 'Survival_FULL_corrupt.7z'  # letters > digits, so sorts FIRST (descending)
            Set-Content -LiteralPath $fullA       -Value 'a' -NoNewline
            Set-Content -LiteralPath $fullB       -Value 'b' -NoNewline
            Set-Content -LiteralPath $fullCorrupt -Value 'x' -NoNewline

            # Incremental archives for both chains.
            $incA = Join-Path $ccInc 'Survival_INC_20260302_000000.7z'
            $incB = Join-Path $ccInc 'Survival_INC_20260102_000000.7z'
            Set-Content -LiteralPath $incA -Value 'a' -NoNewline
            Set-Content -LiteralPath $incB -Value 'b' -NoNewline

            # Keep 0 fulls so ALL three are expired and run through the deletion loop.
            # Sorted DESC: [corrupt, 20260301(A), 20260101(B)]. The corrupt name is processed
            # FIRST: under the #8 bug $fullTimestamp would be unset (or carry a stale value from a
            # prior call) and could target the wrong/no manifest; under the fix it is skipped, and
            # each dated full then prunes ONLY its own chain by its own timestamp.
            $config = @{
                storage   = @{ cc_backup_root = $cc; nas_backup_path = $null }
                retention = @{ cc_full_count = 0; nas_retention_days = 30 }
            }

            $result = Remove-SEBExpiredBackups -InstanceName $inst -GlobalConfig $config

            # The corrupt full sorts FIRST (descending) and is processed before the dated fulls.
            # With the bug it would reuse a later iteration's timestamp and double-prune; with the fix it is
            # skipped. Both valid chains are legitimately expired (keep=0), so BOTH manifests/
            # incrementals are gone -- but each must be removed by its OWN matching full, exactly
            # once, never via the stale-timestamp path. The decisive assertion: the skip was
            # recorded and the corrupt archive itself was NOT removed as a chain member.
            ($result.Errors -join "`n") | Should -Match 'unparseable'
            # The corrupt archive is not a valid full; the loop must skip it (continue), so it is
            # never removed by Remove-Item in the full-archive path.
            Test-Path -LiteralPath $fullCorrupt | Should -BeTrue -Because "an unparseable full name is skipped, not removed via a stale chain"

            # Both legitimate chains are fully pruned (keep=0) by their own matching fulls.
            Test-Path -LiteralPath $fullA | Should -BeFalse
            Test-Path -LiteralPath $fullB | Should -BeFalse
            Test-Path -LiteralPath $incA  | Should -BeFalse
            Test-Path -LiteralPath $incB  | Should -BeFalse
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'prunes only the matching chain and leaves an unrelated chain intact when an unparseable name is present' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sebret_" + [guid]::NewGuid().ToString('n'))
        $cc = Join-Path $root 'cc'
        $inst = 'Survival'
        $ccDir = Join-Path $cc $inst
        $ccFull = Join-Path $ccDir 'full'
        $ccInc = Join-Path $ccDir 'incremental'
        $ccManifests = Join-Path $ccDir 'manifests'
        New-Item -Path $ccFull, $ccInc, $ccManifests -ItemType Directory -Force | Out-Null
        try {
            $chainKeep = [guid]::NewGuid().ToString()    # newest valid full -> kept
            $chainExp  = [guid]::NewGuid().ToString()    # oldest valid full -> expired

            New-Manifest -Dir $ccManifests -Name 'Survival_FULL_20260301_000000.json' -Type 'full'        -ChainId $chainKeep -Seq 0
            New-Manifest -Dir $ccManifests -Name 'Survival_INC_20260302_000000.json'  -Type 'incremental' -ChainId $chainKeep -Seq 1
            New-Manifest -Dir $ccManifests -Name 'Survival_FULL_20260101_000000.json' -Type 'full'        -ChainId $chainExp  -Seq 0
            New-Manifest -Dir $ccManifests -Name 'Survival_INC_20260102_000000.json'  -Type 'incremental' -ChainId $chainExp  -Seq 1

            $keepFull   = Join-Path $ccFull 'Survival_FULL_20260301_000000.7z'
            $expFull     = Join-Path $ccFull 'Survival_FULL_20260101_000000.7z'
            # A stray name that passes the '_FULL_' filter but has no valid timestamp, and which
            # sorts (DESC) BETWEEN the two dated fulls so it is processed mid-loop. '20260201...'
            # would parse; use a non-numeric tail that still sorts between them.
            $strayFull   = Join-Path $ccFull 'Survival_FULL_20260201_xxxxxx.7z'
            Set-Content -LiteralPath $keepFull -Value 'k' -NoNewline
            Set-Content -LiteralPath $expFull  -Value 'e' -NoNewline
            Set-Content -LiteralPath $strayFull -Value 's' -NoNewline

            $keepInc = Join-Path $ccInc 'Survival_INC_20260302_000000.7z'
            $expInc  = Join-Path $ccInc 'Survival_INC_20260102_000000.7z'
            Set-Content -LiteralPath $keepInc -Value 'k' -NoNewline
            Set-Content -LiteralPath $expInc  -Value 'e' -NoNewline

            $keepManifest = Join-Path $ccManifests 'Survival_FULL_20260301_000000.json'
            $keepIncMan   = Join-Path $ccManifests 'Survival_INC_20260302_000000.json'

            # Keep the newest valid full only. DESC order: [keep(20260301), stray(20260201_xxxxxx), exp(20260101)].
            # Keep=1 retains 'keep'; expired set = [stray, exp]. The stray is processed FIRST in the
            # expired loop -- under the bug $fullTimestamp would be unset/stale and could target the
            # wrong manifest; under the fix it is skipped, then 'exp' prunes ONLY chainExp.
            $config = @{
                storage   = @{ cc_backup_root = $cc; nas_backup_path = $null }
                retention = @{ cc_full_count = 1; nas_retention_days = 30 }
            }

            $result = Remove-SEBExpiredBackups -InstanceName $inst -GlobalConfig $config

            ($result.Errors -join "`n") | Should -Match 'unparseable'

            # The kept chain (newest valid full) and its members must survive untouched.
            Test-Path -LiteralPath $keepFull     | Should -BeTrue  -Because "it is within the keep count"
            Test-Path -LiteralPath $keepInc      | Should -BeTrue  -Because "the unparseable name must NOT prune the kept chain"
            Test-Path -LiteralPath $keepManifest | Should -BeTrue  -Because "the kept chain's full manifest must survive"
            Test-Path -LiteralPath $keepIncMan   | Should -BeTrue  -Because "the kept chain's incremental manifest must survive"

            # The stray archive is skipped (not removed via a stale chain path).
            Test-Path -LiteralPath $strayFull | Should -BeTrue -Because "an unparseable full name is skipped, not removed"

            # The legitimately expired chain is pruned by its own matching full.
            Test-Path -LiteralPath $expFull | Should -BeFalse
            Test-Path -LiteralPath $expInc  | Should -BeFalse
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
