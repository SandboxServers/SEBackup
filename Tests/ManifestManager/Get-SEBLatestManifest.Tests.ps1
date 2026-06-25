#Requires -Module Pester

# Coverage for Get-SEBLatestManifest's -ChainId filter (issue #6 review follow-up).
#
# Test-SEBChainIntegrity delegates its -ChainId resolution to Get-SEBLatestManifest, so the
# selection contract has to hold here: with -ChainId the function returns the HEAD of the
# requested chain (highest chain_sequence, ties broken by timestamp) and ignores manifests
# belonging to any other chain -- even if another chain has a newer absolute timestamp.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # Write a v2 manifest JSON to the instance's manifests directory and return its filename.
    function New-ManifestOnDisk {
        param(
            [string]$ManifestDir,
            [string]$Name,
            [string]$Type,
            [string]$ChainId,
            [int]$Sequence,
            [string]$Parent,
            [string]$Timestamp
        )
        $manifest = @{
            version         = 2
            type            = $Type
            chain_id        = $ChainId
            chain_sequence  = $Sequence
            parent_manifest = $Parent
            timestamp       = $Timestamp
            archive_path    = ($Name -replace '\.json$', '.zip')
            files           = @{}
            deleted_files   = @()
        }
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ManifestDir $Name) -Encoding UTF8
        return $Name
    }

    # Build two distinct chains for one instance. Chain A is OLDER in absolute time but has a
    # taller sequence; Chain B is NEWER in absolute time. This lets each test assert the
    # filter respects chain membership (and head-by-sequence) rather than just global recency.
    function New-TwoChainsOnDisk {
        $backupRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("seblm_" + [guid]::NewGuid().ToString('n'))
        $instance = 'Survival01'
        $manifestDir = Join-Path (Join-Path $backupRoot $instance) 'manifests'
        New-Item -Path $manifestDir -ItemType Directory -Force | Out-Null

        $chainA = [guid]::NewGuid().ToString()
        $chainB = [guid]::NewGuid().ToString()

        # Chain A: full (seq 0) + two incrementals (seq 1, seq 2 = head).
        $aFull = New-ManifestOnDisk -ManifestDir $manifestDir -Name 'A_FULL_20260201_020000.json' `
            -Type 'full' -ChainId $chainA -Sequence 0 -Parent $null -Timestamp '2026-02-01T02:00:00.0000000Z'
        $aInc1 = New-ManifestOnDisk -ManifestDir $manifestDir -Name 'A_INC_20260202_020000.json' `
            -Type 'incremental' -ChainId $chainA -Sequence 1 -Parent $aFull -Timestamp '2026-02-02T02:00:00.0000000Z'
        $aHead = New-ManifestOnDisk -ManifestDir $manifestDir -Name 'A_INC_20260203_020000.json' `
            -Type 'incremental' -ChainId $chainA -Sequence 2 -Parent $aInc1 -Timestamp '2026-02-03T02:00:00.0000000Z'

        # Chain B: full (seq 0) + one incremental (seq 1 = head). Newer in absolute time than chain A.
        $bFull = New-ManifestOnDisk -ManifestDir $manifestDir -Name 'B_FULL_20260301_020000.json' `
            -Type 'full' -ChainId $chainB -Sequence 0 -Parent $null -Timestamp '2026-03-01T02:00:00.0000000Z'
        $bHead = New-ManifestOnDisk -ManifestDir $manifestDir -Name 'B_INC_20260302_020000.json' `
            -Type 'incremental' -ChainId $chainB -Sequence 1 -Parent $bFull -Timestamp '2026-03-02T02:00:00.0000000Z'

        return [PSCustomObject]@{
            BackupRoot   = $backupRoot
            InstanceName = $instance
            ChainAId     = $chainA
            ChainBId     = $chainB
            ChainAHead   = $aHead
            ChainBHead   = $bHead
        }
    }
}

Describe 'Get-SEBLatestManifest -ChainId (issue #6)' {

    It 'returns the head of the requested chain (highest chain_sequence)' {
        $c = New-TwoChainsOnDisk
        try {
            $m = Get-SEBLatestManifest -InstanceName $c.InstanceName -BackupRoot $c.BackupRoot -ChainId $c.ChainAId
            $m | Should -Not -BeNullOrEmpty
            $m['chain_id'] | Should -Be $c.ChainAId
            $m['chain_sequence'] | Should -Be 2
            $m['_source_filename'] | Should -Be $c.ChainAHead -Because "chain A's head is its seq-2 incremental"
        }
        finally { Remove-Item -LiteralPath $c.BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'ignores a newer manifest that belongs to a different chain' {
        # Without -ChainId the latest-by-timestamp manifest is chain B's head. With -ChainId set
        # to chain A, the newer chain B manifests must be excluded entirely.
        $c = New-TwoChainsOnDisk
        try {
            $bare = Get-SEBLatestManifest -InstanceName $c.InstanceName -BackupRoot $c.BackupRoot
            $bare['_source_filename'] | Should -Be $c.ChainBHead -Because "chain B is newest overall by timestamp"

            $a = Get-SEBLatestManifest -InstanceName $c.InstanceName -BackupRoot $c.BackupRoot -ChainId $c.ChainAId
            $a['chain_id'] | Should -Be $c.ChainAId -Because "the filter must not leak chain B manifests"
            $a['_source_filename'] | Should -Be $c.ChainAHead
        }
        finally { Remove-Item -LiteralPath $c.BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns the head of chain B when targeted by its ChainId' {
        $c = New-TwoChainsOnDisk
        try {
            $b = Get-SEBLatestManifest -InstanceName $c.InstanceName -BackupRoot $c.BackupRoot -ChainId $c.ChainBId
            $b['chain_id'] | Should -Be $c.ChainBId
            $b['chain_sequence'] | Should -Be 1
            $b['_source_filename'] | Should -Be $c.ChainBHead
        }
        finally { Remove-Item -LiteralPath $c.BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns $null for a chain id that matches no manifest' {
        $c = New-TwoChainsOnDisk
        try {
            $none = Get-SEBLatestManifest -InstanceName $c.InstanceName -BackupRoot $c.BackupRoot -ChainId 'does-not-exist'
            $none | Should -BeNullOrEmpty
        }
        finally { Remove-Item -LiteralPath $c.BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
