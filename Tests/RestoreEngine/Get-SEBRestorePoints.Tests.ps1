#Requires -Module Pester

# Get-SEBRestorePoints is the authoritative restore-point discovery used by Scripts\Invoke-Restore.ps1
# (issue #13: the script previously re-implemented discovery against the WRONG on-disk layout --
# {backupRoot}\{NodeName}\{InstanceName}\*.manifest.json -- and so found zero points against real
# backups). These tests construct the layout the backup engine actually writes and assert the
# contract the script depends on:
#
#   {backupRoot}\{InstanceName}\manifests\{Instance}_{FULL|INC}_{ts}.json   (manifest, v2 schema)
#   {backupRoot}\{InstanceName}\full\{Instance}_{FULL}_{ts}.7z              (full archive)
#   {backupRoot}\{InstanceName}\incremental\{Instance}_{INC}_{ts}.7z        (incremental archive)
#
# Verified against:
#   * Invoke-SEBBackup.ps1  (manifestFileName = "${InstanceName}_${typeLabel}_${timestamp}.json",
#     typeLabel FULL/INC, ccTypeDir = {root}\{Instance}\{full|incremental}, ccManifestDir =
#     {root}\{Instance}\manifests, _BAD rename of both archive and manifest on integrity failure)
#   * New-SEBManifest.ps1   (v2 manifest keys: version, type, chain_id, chain_sequence,
#     parent_manifest, timestamp (ISO 8601 'o'), files, deleted_files)
#   * Get-SEBRestorePoints.ps1 output object: ManifestFile, Timestamp, Type, ChainId,
#     ChainSequence, ArchiveFile, SizeBytes, ChainValid
#
# Get-SEBRestorePoints accepts -BackupRoot directly and -- for a fully-present chain -- does NOT
# call any integrity helpers, so these tests are self-contained on-disk fixtures with no mocks.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # Build a realistic engine-produced backup tree on disk and return the root + key paths.
    function New-BackupTree {
        param([string]$InstanceName)

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sebrp_" + [guid]::NewGuid().ToString('n'))
        $instDir   = Join-Path $root $InstanceName
        $manifests = Join-Path $instDir 'manifests'
        $fullDir   = Join-Path $instDir 'full'
        $incDir    = Join-Path $instDir 'incremental'
        New-Item -Path $manifests, $fullDir, $incDir -ItemType Directory -Force | Out-Null

        [PSCustomObject]@{
            Root      = $root
            Instance  = $InstanceName
            Manifests = $manifests
            Full      = $fullDir
            Inc       = $incDir
        }
    }

    # Write a v2 manifest matching New-SEBManifest's shape, plus the archive_path/size fields
    # Invoke-SEBBackup adds at write time.
    function New-EngineManifest {
        param(
            [string]$Dir,
            [string]$Name,
            [string]$Type,            # 'full' | 'incremental'
            [string]$ChainId,
            [int]$Seq,
            [string]$ArchiveName,
            [string]$Timestamp,
            # The engine (New-SEBManifest) sets parent_manifest to the PREVIOUS manifest's filename,
            # NOT a static 'parent.json'. Callers building an incremental must pass the actual prior
            # manifest's leaf name so the fixture matches engine-produced manifests. Fulls have no
            # parent ($null), matching New-SEBManifest.
            [string]$ParentManifest
        )
        if (-not $Timestamp) { $Timestamp = [datetime]::UtcNow.ToString('o') }
        $m = @{
            version            = 2
            type               = $Type
            chain_id           = $ChainId
            chain_sequence     = $Seq
            parent_manifest    = $(if ($Type -eq 'incremental') { $ParentManifest } else { $null })
            timestamp          = $Timestamp
            files              = @{ 'Sandbox.sbc' = @{ size = 1; sha256 = ('a' * 64); last_write = $Timestamp } }
            deleted_files      = @()
            archive_path       = $ArchiveName
            # archive_size_bytes is part of a real engine manifest, but Get-SEBRestorePoints derives
            # SizeBytes from the archive file's length on disk -- it never reads this field -- so the
            # value here is irrelevant to the tests and kept as a static placeholder.
            archive_size_bytes = 1024
            archive_sha256     = ('b' * 64)
        }
        $m | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Dir $Name)
    }

    function New-Archive {
        param([string]$Dir, [string]$Name, [string]$Content = 'archive-bytes')
        $path = Join-Path $Dir $Name
        Set-Content -LiteralPath $path -Value $Content -NoNewline
        return $path
    }
}

Describe 'Get-SEBRestorePoints discovers the engine-produced backup layout' {

    Context 'a full + two-incremental chain, all archives present' {
        BeforeAll {
            $script:tree = New-BackupTree -InstanceName 'PvPArena'
            $script:chainId = [guid]::NewGuid().ToString()

            $tsFull = '2026-02-27T10:00:00.0000000Z'
            $tsInc1 = '2026-02-27T11:00:00.0000000Z'
            $tsInc2 = '2026-02-27T12:00:00.0000000Z'

            New-Archive -Dir $tree.Full -Name 'PvPArena_FULL_20260227_100000.7z' | Out-Null
            New-Archive -Dir $tree.Inc  -Name 'PvPArena_INC_20260227_110000.7z'  | Out-Null
            New-Archive -Dir $tree.Inc  -Name 'PvPArena_INC_20260227_120000.7z'  | Out-Null

            # parent_manifest chains to the PREVIOUS manifest's leaf name (as New-SEBManifest writes):
            # seq 1 -> the full's manifest, seq 2 -> the seq-1 incremental's manifest.
            New-EngineManifest -Dir $tree.Manifests -Name 'PvPArena_FULL_20260227_100000.json' `
                -Type 'full' -ChainId $chainId -Seq 0 -ArchiveName 'PvPArena_FULL_20260227_100000.7z' -Timestamp $tsFull
            New-EngineManifest -Dir $tree.Manifests -Name 'PvPArena_INC_20260227_110000.json' `
                -Type 'incremental' -ChainId $chainId -Seq 1 -ArchiveName 'PvPArena_INC_20260227_110000.7z' -Timestamp $tsInc1 `
                -ParentManifest 'PvPArena_FULL_20260227_100000.json'
            New-EngineManifest -Dir $tree.Manifests -Name 'PvPArena_INC_20260227_120000.json' `
                -Type 'incremental' -ChainId $chainId -Seq 2 -ArchiveName 'PvPArena_INC_20260227_120000.7z' -Timestamp $tsInc2 `
                -ParentManifest 'PvPArena_INC_20260227_110000.json'
        }

        AfterAll {
            Remove-Item -LiteralPath $script:tree.Root -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'returns one restore point per manifest in the engine layout' {
            $points = Get-SEBRestorePoints -InstanceName 'PvPArena' -BackupRoot $tree.Root
            $points | Should -HaveCount 3
        }

        It 'exposes the documented output shape (ManifestFile/Timestamp/Type/ChainId/ChainSequence/ArchiveFile/SizeBytes/ChainValid)' {
            $points = Get-SEBRestorePoints -InstanceName 'PvPArena' -BackupRoot $tree.Root
            $p = $points | Select-Object -First 1
            foreach ($prop in 'ManifestFile','Timestamp','Type','ChainId','ChainSequence','ArchiveFile','SizeBytes','ChainValid') {
                $p.PSObject.Properties.Name | Should -Contain $prop
            }
        }

        It 'reports every point as ChainValid when the whole chain and its archives exist' {
            $points = Get-SEBRestorePoints -InstanceName 'PvPArena' -BackupRoot $tree.Root
            ($points | Where-Object { -not $_.ChainValid }) | Should -BeNullOrEmpty
        }

        It 'resolves the matching archive under full\ for the full backup' {
            $points = Get-SEBRestorePoints -InstanceName 'PvPArena' -BackupRoot $tree.Root
            $full = $points | Where-Object { $_.Type -eq 'full' }
            $full.ArchiveFile | Should -Not -BeNullOrEmpty
            (Split-Path -Path $full.ArchiveFile -Leaf) | Should -Be 'PvPArena_FULL_20260227_100000.7z'
            (Split-Path -Path (Split-Path -Path $full.ArchiveFile -Parent) -Leaf) | Should -Be 'full'
        }

        It 'resolves incrementals to archives under incremental\ with correct chain sequence' {
            $points = Get-SEBRestorePoints -InstanceName 'PvPArena' -BackupRoot $tree.Root
            $inc2 = $points | Where-Object { $_.ChainSequence -eq 2 }
            $inc2.Type | Should -Be 'incremental'
            (Split-Path -Path $inc2.ArchiveFile -Leaf) | Should -Be 'PvPArena_INC_20260227_120000.7z'
        }

        It 'yields manifest leaf names that are valid -RestorePoint values for Invoke-SEBRestore' {
            # This is the exact value Invoke-Restore.ps1 passes to Invoke-SEBRestore -RestorePoint:
            # the leaf of ManifestFile. Test-SEBRestoreChain resolves it as a filename in the
            # manifests dir, so it must exist there verbatim.
            $points = Get-SEBRestorePoints -InstanceName 'PvPArena' -BackupRoot $tree.Root
            foreach ($p in $points) {
                $leaf = Split-Path -Path $p.ManifestFile -Leaf
                Test-Path -LiteralPath (Join-Path $tree.Manifests $leaf) -PathType Leaf | Should -BeTrue
            }
        }

        It 'reports the archive size in SizeBytes' {
            $points = Get-SEBRestorePoints -InstanceName 'PvPArena' -BackupRoot $tree.Root
            $full = $points | Where-Object { $_.Type -eq 'full' }
            $full.SizeBytes | Should -BeGreaterThan 0
            $full.SizeBytes | Should -Be (Get-Item -LiteralPath $full.ArchiveFile).Length
        }
    }

    Context "excludes '_BAD' artifacts (failed-integrity backups must never be offered)" {
        BeforeAll {
            $script:tree = New-BackupTree -InstanceName 'Creative'
            $script:chainId = [guid]::NewGuid().ToString()

            # One good full, one failed full renamed by the engine to _BAD (both manifest+archive).
            New-Archive -Dir $tree.Full -Name 'Creative_FULL_20260101_000000.7z'     | Out-Null
            New-Archive -Dir $tree.Full -Name 'Creative_FULL_20260102_000000_BAD.7z' | Out-Null

            New-EngineManifest -Dir $tree.Manifests -Name 'Creative_FULL_20260101_000000.json' `
                -Type 'full' -ChainId $chainId -Seq 0 -ArchiveName 'Creative_FULL_20260101_000000.7z'
            New-EngineManifest -Dir $tree.Manifests -Name 'Creative_FULL_20260102_000000_BAD.json' `
                -Type 'full' -ChainId ([guid]::NewGuid().ToString()) -Seq 0 -ArchiveName 'Creative_FULL_20260102_000000_BAD.7z'
        }

        AfterAll {
            Remove-Item -LiteralPath $script:tree.Root -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'returns only the good restore point and never the _BAD one' {
            $points = Get-SEBRestorePoints -InstanceName 'Creative' -BackupRoot $tree.Root
            $points | Should -HaveCount 1
            (Split-Path -Path $points[0].ManifestFile -Leaf) | Should -Be 'Creative_FULL_20260101_000000.json'
            ($points | Where-Object { (Split-Path $_.ManifestFile -Leaf) -match '_BAD' }) | Should -BeNullOrEmpty
        }
    }

    Context 'a broken chain (missing incremental archive) is reported but not valid' {
        BeforeAll {
            $script:tree = New-BackupTree -InstanceName 'Survival'
            $script:chainId = [guid]::NewGuid().ToString()

            # Full + its archive present; incremental manifest present but its archive is MISSING.
            New-Archive -Dir $tree.Full -Name 'Survival_FULL_20260301_000000.7z' | Out-Null

            New-EngineManifest -Dir $tree.Manifests -Name 'Survival_FULL_20260301_000000.json' `
                -Type 'full' -ChainId $chainId -Seq 0 -ArchiveName 'Survival_FULL_20260301_000000.7z'
            # parent_manifest is the full's manifest leaf, as the engine would write; the chain is
            # broken only because the incremental's ARCHIVE is missing, not its parent linkage.
            New-EngineManifest -Dir $tree.Manifests -Name 'Survival_INC_20260301_010000.json' `
                -Type 'incremental' -ChainId $chainId -Seq 1 -ArchiveName 'Survival_INC_20260301_010000.7z' `
                -ParentManifest 'Survival_FULL_20260301_000000.json'
        }

        AfterAll {
            Remove-Item -LiteralPath $script:tree.Root -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'still lists the incremental point but marks it ChainValid = $false' {
            $points = Get-SEBRestorePoints -InstanceName 'Survival' -BackupRoot $tree.Root
            $points | Should -HaveCount 2
            $inc = $points | Where-Object { $_.Type -eq 'incremental' }
            $inc.ChainValid | Should -BeFalse
            # The full is self-contained and remains valid.
            ($points | Where-Object { $_.Type -eq 'full' }).ChainValid | Should -BeTrue
        }
    }

    Context 'no backups for the instance' {
        It 'returns an empty result when the manifests directory does not exist' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sebrp_" + [guid]::NewGuid().ToString('n'))
            New-Item -Path $root -ItemType Directory -Force | Out-Null
            try {
                $points = Get-SEBRestorePoints -InstanceName 'NoSuchInstance' -BackupRoot $root
                @($points) | Should -HaveCount 0
            }
            finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'InstanceName guard rejects traversal but allows valid names (security)' {
        # $InstanceName is concatenated into the backup path (Join-Path $BackupRoot $InstanceName).
        # The guard delegates to the shared Test-SEBSafeName validator (issue #28 consolidation): it
        # rejects path separators, '..' traversal, rooted paths, wildcards, and invalid filename chars,
        # but ALLOWS legitimate names containing '.' or spaces (config and New-SEBLockFile accept
        # those). The guard runs in the function BODY with the -Throw style (NOT a binding-time
        # [ValidateScript], which would fail for every value if the Logger module that exports
        # Test-SEBSafeName were not yet loaded), so a rejected value still raises a terminating error
        # and the call throws -- exactly the behaviour these assertions depend on.
        It 'throws on a traversal value like ..\evil' {
            { Get-SEBRestorePoints -InstanceName '..\evil' -BackupRoot 'C:\Backups' } | Should -Throw
        }

        It 'throws on a forward-slash traversal value' {
            { Get-SEBRestorePoints -InstanceName '../evil' -BackupRoot 'C:\Backups' } | Should -Throw
        }

        It 'throws on a bare forward-slash path segment (a/b)' {
            { Get-SEBRestorePoints -InstanceName 'a/b' -BackupRoot 'C:\Backups' } | Should -Throw
        }

        It 'throws on an absolute-path-like value' {
            { Get-SEBRestorePoints -InstanceName 'C:\Windows' -BackupRoot 'C:\Backups' } | Should -Throw
        }

        It 'throws on a rooted value like C:\x' {
            { Get-SEBRestorePoints -InstanceName 'C:\x' -BackupRoot 'C:\Backups' } | Should -Throw
        }

        It 'ACCEPTS a name containing a dot (e.g. PvP.Arena) -- the relaxed guard no longer over-rejects' {
            # 'PvP.Arena' has no separators/traversal/wildcards/rooting, so it is a legitimate
            # instance name. The previous '^[A-Za-z0-9_-]+$' pattern wrongly rejected it; the
            # New-SEBLockFile-aligned guard must accept it. No backups under this fresh root, so the
            # function returns an empty set rather than throwing.
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sebrp_" + [guid]::NewGuid().ToString('n'))
            New-Item -Path $root -ItemType Directory -Force | Out-Null
            try {
                { Get-SEBRestorePoints -InstanceName 'PvP.Arena' -BackupRoot $root } | Should -Not -Throw
                @(Get-SEBRestorePoints -InstanceName 'PvP.Arena' -BackupRoot $root) | Should -HaveCount 0
            }
            finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'still accepts a normal hyphen/underscore instance name' {
            # A name with no disallowed characters must NOT be rejected by the validator. There are
            # no backups under this fresh root, so the function returns an empty set, not a throw.
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sebrp_" + [guid]::NewGuid().ToString('n'))
            New-Item -Path $root -ItemType Directory -Force | Out-Null
            try {
                { Get-SEBRestorePoints -InstanceName 'PvP_Arena-01' -BackupRoot $root } | Should -Not -Throw
                @(Get-SEBRestorePoints -InstanceName 'PvP_Arena-01' -BackupRoot $root) | Should -HaveCount 0
            }
            finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'archive resolution is an exact-stem match, not a wildcard glob (security)' {
        # Fix #4: archive lookups must match the manifest stem EXACTLY. A manifest filename can
        # legally contain PowerShell wildcard metacharacters; the previous `-Filter "${stem}.*"`
        # would treat them as a glob -- failing to find the real (literal) archive and potentially
        # matching an unrelated one. Here the manifest stem contains a '[x]' character class.
        BeforeAll {
            $script:tree = New-BackupTree -InstanceName 'GlobTest'
            $script:chainId = [guid]::NewGuid().ToString()

            # The real archive whose stem contains literal brackets. Under the old glob, the pattern
            # 'Decoy_FULL_a[x]b.*' would NOT match this literal file (the class '[x]' matches a bare
            # 'x'), so the old code would report no archive for its manifest.
            New-Archive -Dir $tree.Full -Name 'Decoy_FULL_a[x]b.7z' | Out-Null
            # A decoy whose name the OLD glob WOULD have matched (a[x]b -> axb). Exact-stem matching
            # must ignore it.
            New-Archive -Dir $tree.Full -Name 'Decoy_FULL_axb.7z' | Out-Null

            New-EngineManifest -Dir $tree.Manifests -Name 'Decoy_FULL_a[x]b.json' `
                -Type 'full' -ChainId $chainId -Seq 0 -ArchiveName 'Decoy_FULL_a[x]b.7z'
        }

        AfterAll {
            Remove-Item -LiteralPath $script:tree.Root -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'resolves the bracketed manifest to its exact-named archive and marks the chain valid' {
            $points = Get-SEBRestorePoints -InstanceName 'GlobTest' -BackupRoot $tree.Root
            $points | Should -HaveCount 1
            $points[0].ArchiveFile | Should -Not -BeNullOrEmpty
            (Split-Path -Path $points[0].ArchiveFile -Leaf) | Should -Be 'Decoy_FULL_a[x]b.7z'
            $points[0].ChainValid | Should -BeTrue
        }
    }
}
