#Requires -Module Pester

# Issue #6 regression + end-to-end coverage for Level-3 chain integrity.
#
# Test-SEBChainIntegrity previously called Get-SEBManifestChain with a nonexistent -ChainId
# and omitted the mandatory -TargetManifest, so every Level-3 run failed parameter binding
# and returned Passed=$false. These tests build a real full+incremental chain on disk (with
# matching .zip archives and v2 manifests) and exercise the function end-to-end:
#   - a good chain reconstructs and verifies (Passed=$true),
#   - a missing chain member fails,
#   - a corrupt archive fails.
# The .zip extension routes through the .NET (Compress-Archive) engine so no external 7-Zip
# is required, though it may be present.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    # Import the whole module so IntegrityManager can resolve the ManifestManager and
    # CompressionManager functions it depends on (Get-SEBManifestChain, Get-SEBLatestManifest,
    # Read-SEBManifest, Expand-SEBArchive, Get-SEBArchiveContents, Test-SEBArchive).
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # Compute a v2 'files' entry (size + lowercase sha256 + last_write) for one on-disk file.
    function New-FileEntry {
        param([string]$FullPath)
        $item = Get-Item -LiteralPath $FullPath
        return @{
            size       = $item.Length
            sha256     = (Get-FileHash -LiteralPath $FullPath -Algorithm SHA256).Hash.ToLower()
            last_write = $item.LastWriteTimeUtc.ToString('o')
        }
    }

    # Write a set of relative-path -> content files under $Root (forward-slash relative paths).
    function Set-WorldFiles {
        param([string]$Root, [hashtable]$Files)
        foreach ($rel in $Files.Keys) {
            $full = Join-Path $Root ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $parent = Split-Path -Path $full -Parent
            if (-not (Test-Path -Path $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
            Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
        }
    }

    # Build a complete instance backup tree (full + one incremental) with archives + manifests
    # under a fresh temp BackupRoot, and return the descriptors a test needs.
    function New-ChainOnDisk {
        $backupRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sebchain_" + [guid]::NewGuid().ToString('n'))
        $instance = 'Survival01'
        $instanceDir = Join-Path $backupRoot $instance
        $fullDir = Join-Path $instanceDir 'full'
        $incDir = Join-Path $instanceDir 'incremental'
        $manifestDir = Join-Path $instanceDir 'manifests'
        foreach ($d in @($fullDir, $incDir, $manifestDir)) {
            New-Item -Path $d -ItemType Directory -Force | Out-Null
        }

        $chainId = [guid]::NewGuid().ToString()

        # --- FULL backup: stage the world, archive it, build the full manifest ---
        $fullStage = Join-Path ([System.IO.Path]::GetTempPath()) ("sebstage_" + [guid]::NewGuid().ToString('n'))
        New-Item -Path $fullStage -ItemType Directory -Force | Out-Null
        $fullWorld = @{
            'Sandbox.sbc'            = 'full-v1'
            'keep.dat'               = 'keep-unchanged'
            'gone.dat'               = 'will-be-deleted'
            'sub/SANDBOX_0_0_0_.sbs' = 'sector-v1'
        }
        Set-WorldFiles -Root $fullStage -Files $fullWorld

        $fullArchiveName = 'Survival01_FULL_20260201_020000.zip'
        $fullArchivePath = Join-Path $fullDir $fullArchiveName
        Compress-Archive -Path (Join-Path $fullStage '*') -DestinationPath $fullArchivePath -Force

        $fullFiles = @{}
        foreach ($rel in $fullWorld.Keys) {
            $fullFiles[$rel] = New-FileEntry -FullPath (Join-Path $fullStage ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar))
        }

        $fullManifestName = 'Survival01_FULL_20260201_020000.json'
        $fullManifest = @{
            version            = 2
            type               = 'full'
            chain_id           = $chainId
            chain_sequence     = 0
            parent_manifest    = $null
            timestamp          = '2026-02-01T02:00:00.0000000Z'
            archive_path       = $fullArchiveName
            archive_sha256     = (Get-FileHash -LiteralPath $fullArchivePath -Algorithm SHA256).Hash.ToLower()
            archive_size_bytes = (Get-Item -LiteralPath $fullArchivePath).Length
            files              = $fullFiles
            deleted_files      = @()
        }
        $fullManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $manifestDir $fullManifestName) -Encoding UTF8

        # --- INCREMENTAL: modify Sandbox.sbc, add new.dat, delete gone.dat ---
        # The archive carries ONLY the delta (added + modified). The manifest 'files' map carries
        # the FULL final logical world state so Level-3 reconstruction can verify it.
        $incStage = Join-Path ([System.IO.Path]::GetTempPath()) ("sebstage_" + [guid]::NewGuid().ToString('n'))
        New-Item -Path $incStage -ItemType Directory -Force | Out-Null
        $incDelta = @{
            'Sandbox.sbc' = 'full-v2-modified'
            'new.dat'     = 'newly-added'
        }
        Set-WorldFiles -Root $incStage -Files $incDelta

        $incArchiveName = 'Survival01_INC_20260202_020000.zip'
        $incArchivePath = Join-Path $incDir $incArchiveName
        Compress-Archive -Path (Join-Path $incStage '*') -DestinationPath $incArchivePath -Force

        # Final logical world = full world, minus gone.dat, with Sandbox.sbc modified, plus new.dat.
        $finalWorld = @{
            'Sandbox.sbc'            = 'full-v2-modified'
            'keep.dat'               = 'keep-unchanged'
            'new.dat'                = 'newly-added'
            'sub/SANDBOX_0_0_0_.sbs' = 'sector-v1'
        }
        # Build the final-state file entries: reuse the full stage for unchanged files and the
        # inc stage for added/modified files so the recorded hashes match the actual bytes.
        $incFiles = @{}
        $incFiles['Sandbox.sbc']            = New-FileEntry -FullPath (Join-Path $incStage 'Sandbox.sbc')
        $incFiles['new.dat']                = New-FileEntry -FullPath (Join-Path $incStage 'new.dat')
        $incFiles['keep.dat']               = New-FileEntry -FullPath (Join-Path $fullStage 'keep.dat')
        $incFiles['sub/SANDBOX_0_0_0_.sbs'] = New-FileEntry -FullPath (Join-Path $fullStage 'sub\SANDBOX_0_0_0_.sbs')

        $incManifestName = 'Survival01_INC_20260202_020000.json'
        $incManifest = @{
            version            = 2
            type               = 'incremental'
            chain_id           = $chainId
            chain_sequence     = 1
            parent_manifest    = $fullManifestName
            timestamp          = '2026-02-02T02:00:00.0000000Z'
            archive_path       = $incArchiveName
            archive_sha256     = (Get-FileHash -LiteralPath $incArchivePath -Algorithm SHA256).Hash.ToLower()
            archive_size_bytes = (Get-Item -LiteralPath $incArchivePath).Length
            files              = $incFiles
            deleted_files      = @('gone.dat')
        }
        $incManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $manifestDir $incManifestName) -Encoding UTF8

        Remove-Item -LiteralPath $fullStage -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $incStage -Recurse -Force -ErrorAction SilentlyContinue

        return [PSCustomObject]@{
            BackupRoot      = $backupRoot
            InstanceName    = $instance
            ChainId         = $chainId
            FullArchivePath = $fullArchivePath
            IncArchivePath  = $incArchivePath
            IncManifestPath = Join-Path $manifestDir $incManifestName
            FinalWorld      = $finalWorld
        }
    }

    # Build an instance whose ONLY backup is a full (no incrementals) -- the brand-new-instance
    # case. Exercises the single-member chain path: Get-SEBManifestChain returns one element, which
    # must stay array-shaped so L3 can reconstruct and verify it.
    function New-FullOnlyChainOnDisk {
        $backupRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sebchain_" + [guid]::NewGuid().ToString('n'))
        $instance = 'Survival01'
        $instanceDir = Join-Path $backupRoot $instance
        $fullDir = Join-Path $instanceDir 'full'
        $manifestDir = Join-Path $instanceDir 'manifests'
        foreach ($d in @($fullDir, $manifestDir)) {
            New-Item -Path $d -ItemType Directory -Force | Out-Null
        }

        $fullStage = Join-Path ([System.IO.Path]::GetTempPath()) ("sebstage_" + [guid]::NewGuid().ToString('n'))
        New-Item -Path $fullStage -ItemType Directory -Force | Out-Null
        $fullWorld = @{
            'Sandbox.sbc'            = 'first-full'
            'sub/SANDBOX_0_0_0_.sbs' = 'sector-only'
        }
        Set-WorldFiles -Root $fullStage -Files $fullWorld

        $fullArchiveName = 'Survival01_FULL_20260301_020000.zip'
        $fullArchivePath = Join-Path $fullDir $fullArchiveName
        Compress-Archive -Path (Join-Path $fullStage '*') -DestinationPath $fullArchivePath -Force

        $fullFiles = @{}
        foreach ($rel in $fullWorld.Keys) {
            $fullFiles[$rel] = New-FileEntry -FullPath (Join-Path $fullStage ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar))
        }

        $fullManifest = @{
            version            = 2
            type               = 'full'
            chain_id           = [guid]::NewGuid().ToString()
            chain_sequence     = 0
            parent_manifest    = $null
            timestamp          = '2026-03-01T02:00:00.0000000Z'
            archive_path       = $fullArchiveName
            archive_sha256     = (Get-FileHash -LiteralPath $fullArchivePath -Algorithm SHA256).Hash.ToLower()
            archive_size_bytes = (Get-Item -LiteralPath $fullArchivePath).Length
            files              = $fullFiles
            deleted_files      = @()
        }
        $fullManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $manifestDir 'Survival01_FULL_20260301_020000.json') -Encoding UTF8

        Remove-Item -LiteralPath $fullStage -Recurse -Force -ErrorAction SilentlyContinue

        return [PSCustomObject]@{
            BackupRoot   = $backupRoot
            InstanceName = $instance
        }
    }
}

Describe 'Test-SEBChainIntegrity end-to-end (issue #6)' {

    It 'passes a valid full + incremental chain (latest)' {
        $c = New-ChainOnDisk
        try {
            $r = Test-SEBChainIntegrity -InstanceName $c.InstanceName -BackupRoot $c.BackupRoot
            $r.ErrorMessage | Should -BeNullOrEmpty -Because "a well-formed chain has nothing to report"
            $r.Passed | Should -BeTrue -Because "the full + incremental chain reconstructs the final world"
            $r.Level | Should -Be 3
            $r.ChainLength | Should -Be 2
            $r.ReconstructionValid | Should -BeTrue
        }
        finally { Remove-Item -LiteralPath $c.BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'passes the same chain when targeted by ChainId' {
        $c = New-ChainOnDisk
        try {
            $r = Test-SEBChainIntegrity -InstanceName $c.InstanceName -BackupRoot $c.BackupRoot -ChainId $c.ChainId
            $r.Passed | Should -BeTrue -Because "resolving the chain head by ChainId must reach the same target manifest"
            $r.ChainId | Should -Be $c.ChainId
            $r.ChainLength | Should -Be 2
        }
        finally { Remove-Item -LiteralPath $c.BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports a real error for an unknown ChainId instead of a binding failure' {
        $c = New-ChainOnDisk
        try {
            $r = Test-SEBChainIntegrity -InstanceName $c.InstanceName -BackupRoot $c.BackupRoot -ChainId 'does-not-exist'
            $r.Passed | Should -BeFalse
            $r.ErrorMessage | Should -Match 'No manifest chain found'
        }
        finally { Remove-Item -LiteralPath $c.BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails when a chain member archive is missing' {
        $c = New-ChainOnDisk
        try {
            Remove-Item -LiteralPath $c.IncArchivePath -Force
            $r = Test-SEBChainIntegrity -InstanceName $c.InstanceName -BackupRoot $c.BackupRoot
            $r.Passed | Should -BeFalse -Because "an incremental archive referenced by the chain is gone"
            $r.ErrorMessage | Should -Not -BeNullOrEmpty
        }
        finally { Remove-Item -LiteralPath $c.BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails when a chain member archive is corrupt' {
        $c = New-ChainOnDisk
        try {
            # Truncate/overwrite the incremental archive so its CRC and recorded SHA256 no longer hold.
            Set-Content -LiteralPath $c.IncArchivePath -Value 'CORRUPTED-NOT-A-ZIP' -NoNewline
            $r = Test-SEBChainIntegrity -InstanceName $c.InstanceName -BackupRoot $c.BackupRoot
            $r.Passed | Should -BeFalse -Because "the incremental archive bytes no longer match its manifest/CRC"
            $r.ErrorMessage | Should -Not -BeNullOrEmpty
        }
        finally { Remove-Item -LiteralPath $c.BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'passes a full-only chain (brand-new instance, single member)' {
        # Get-SEBManifestChain returns a one-element chain here; it must stay array-shaped so
        # $chain.Count is 1 (not the hashtable key count) and $chain[0] is the full manifest.
        $c = New-FullOnlyChainOnDisk
        try {
            $r = Test-SEBChainIntegrity -InstanceName $c.InstanceName -BackupRoot $c.BackupRoot
            $r.ErrorMessage | Should -BeNullOrEmpty -Because "a lone valid full backup is a complete, verifiable chain"
            $r.Passed | Should -BeTrue -Because "a brand-new instance with only a full backup must pass L3"
            $r.ChainLength | Should -Be 1
            $r.ReconstructionValid | Should -BeTrue
        }
        finally { Remove-Item -LiteralPath $c.BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
