#Requires -Module Pester

# Issue #19 -- unit coverage for the manifest-building logic in New-SEBManifest that runs on the
# C&C side (NOT the remote scan block, which is node-local and exercised by RemoteScriptBlock
# contract tests). The remote file-hash boundary is the ONLY thing mocked: Invoke-SEBRemoteCommand
# is stubbed to return a canned scan result (@{ Files; HashedCount; SkippedCount }), so no real node
# is needed. With that fixed, the deterministic C&C logic is asserted:
#   * deleted-file detection (present in previous, absent in current);
#   * incremental vs full chain metadata (type, chain_id continuity, chain_sequence increment,
#     parent_manifest);
#   * a full (no PreviousManifest) manifest gets a fresh chain_id, sequence 0, null parent.
#
# The mock returns the SAME shape the real remote block returns, so the C&C-side merge/metadata
# code under test runs exactly as in production.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # An uninitialized PSSession satisfies the [PSSession] cast on -Session without a live
    # connection (the type has no public constructor). Invoke-SEBRemoteCommand is mocked, so it is
    # never actually used to talk to a node.
    $script:fakeSession = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
        [System.Management.Automation.Runspaces.PSSession])

    # New-FileEntry (the shared manifest 'files' entry factory) lives in one place so it cannot
    # drift between this suite and Compare-SEBManifest.Tests.ps1.
    . "$PSScriptRoot/_ManifestTestHelpers.ps1"
}

Describe 'New-SEBManifest (remote scan mocked)' {

    Context 'full manifest (no previous)' {
        BeforeAll {
            Mock Invoke-SEBRemoteCommand -ModuleName ManifestManager {
                @{
                    Files = @{
                        'world.sbs' = @{ size = 100; sha256 = 'aaaa'; last_write = '2026-01-01T00:00:00.0000000Z' }
                        'config.xml' = @{ size = 20; sha256 = 'bbbb'; last_write = '2026-01-01T00:00:00.0000000Z' }
                    }
                    HashedCount  = 2
                    SkippedCount = 0
                }
            }
        }

        It 'returns a v2 full manifest with a fresh chain and null parent' {
            $m = New-SEBManifest -SourcePath 'E:\Shadow\Inst' -Session $script:fakeSession

            $m['version']        | Should -Be 2
            $m['type']           | Should -Be 'full'
            $m['chain_sequence'] | Should -Be 0
            $m['parent_manifest'] | Should -BeNullOrEmpty
            $m['chain_id']       | Should -Not -BeNullOrEmpty
            # No previous -> nothing can be deleted.
            @($m['deleted_files']).Count | Should -Be 0
        }

        It 'carries the scanned files through from the (mocked) remote result' {
            $m = New-SEBManifest -SourcePath 'E:\Shadow\Inst' -Session $script:fakeSession
            $m['files'].Keys | Should -Contain 'world.sbs'
            $m['files'].Keys | Should -Contain 'config.xml'
            $m['files']['world.sbs']['sha256'] | Should -Be 'aaaa'
        }

        It 'generates a unique chain_id per full manifest' {
            $a = New-SEBManifest -SourcePath 'E:\Shadow\Inst' -Session $script:fakeSession
            $b = New-SEBManifest -SourcePath 'E:\Shadow\Inst' -Session $script:fakeSession
            $a['chain_id'] | Should -Not -Be $b['chain_id']
        }
    }

    Context 'incremental manifest (with a previous)' {
        BeforeAll {
            # Current scan: 'world.sbs' present (changed hash), 'new.vx2' added, 'old.tmp' GONE.
            Mock Invoke-SEBRemoteCommand -ModuleName ManifestManager {
                @{
                    Files = @{
                        'world.sbs' = @{ size = 150; sha256 = 'newhash'; last_write = '2026-02-01T00:00:00.0000000Z' }
                        'new.vx2'   = @{ size = 500; sha256 = 'addhash'; last_write = '2026-02-01T00:00:00.0000000Z' }
                    }
                    HashedCount  = 2
                    SkippedCount = 0
                }
            }

            $script:previous = @{
                version          = 2
                type             = 'full'
                chain_id         = 'CHAIN-AAA'
                chain_sequence   = 3
                parent_manifest  = $null
                _source_filename = 'FULL_20260101_020000.json'
                files            = @{
                    'world.sbs' = New-FileEntry -Size 100 -Sha256 'oldhash'
                    'old.tmp'   = New-FileEntry -Size 10  -Sha256 'tmphash'
                }
            }
        }

        It 'marks it incremental and continues the previous chain' {
            $m = New-SEBManifest -SourcePath 'E:\Shadow\Inst' -PreviousManifest $script:previous -Session $script:fakeSession
            $m['type']     | Should -Be 'incremental'
            $m['chain_id'] | Should -Be 'CHAIN-AAA' -Because 'an incremental stays in its parent chain'
        }

        It 'increments chain_sequence by one over the previous' {
            $m = New-SEBManifest -SourcePath 'E:\Shadow\Inst' -PreviousManifest $script:previous -Session $script:fakeSession
            $m['chain_sequence'] | Should -Be 4 -Because 'previous was sequence 3'
        }

        It 'sets parent_manifest to the previous manifest filename' {
            $m = New-SEBManifest -SourcePath 'E:\Shadow\Inst' -PreviousManifest $script:previous -Session $script:fakeSession
            $m['parent_manifest'] | Should -Be 'FULL_20260101_020000.json'
        }

        It 'detects a deleted file (in previous, absent from the current scan)' {
            $m = New-SEBManifest -SourcePath 'E:\Shadow\Inst' -PreviousManifest $script:previous -Session $script:fakeSession
            $m['deleted_files'] | Should -Contain 'old.tmp'
            # Files still present (even if changed/added) are NOT in deleted_files.
            $m['deleted_files'] | Should -Not -Contain 'world.sbs'
            $m['deleted_files'] | Should -Not -Contain 'new.vx2'
        }

        It 'warns and nulls parent_manifest when the previous lacks _source_filename' {
            $prevNoFilename = @{
                version        = 2; type = 'full'; chain_id = 'CHAIN-BBB'; chain_sequence = 0
                files          = @{ 'a.cfg' = New-FileEntry -Size 1 -Sha256 'x' }
            }
            $m = New-SEBManifest -SourcePath 'E:\Shadow\Inst' -PreviousManifest $prevNoFilename -Session $script:fakeSession -WarningAction SilentlyContinue
            $m['parent_manifest'] | Should -BeNullOrEmpty
            $m['chain_id']        | Should -Be 'CHAIN-BBB'
            $m['chain_sequence']  | Should -Be 1
        }
    }

    Context 'incremental with no deletions' {
        BeforeAll {
            Mock Invoke-SEBRemoteCommand -ModuleName ManifestManager {
                @{
                    Files = @{
                        'keep.cfg' = @{ size = 1; sha256 = 'same'; last_write = '2026-01-01T00:00:00.0000000Z' }
                    }
                    HashedCount  = 0
                    SkippedCount = 1
                }
            }
        }

        It 'produces an empty deleted_files list when every previous file still exists' {
            $previous = @{
                version = 2; type = 'full'; chain_id = 'C'; chain_sequence = 0; _source_filename = 'p.json'
                files   = @{ 'keep.cfg' = New-FileEntry -Size 1 -Sha256 'same' }
            }
            $m = New-SEBManifest -SourcePath 'E:\Shadow\Inst' -PreviousManifest $previous -Session $script:fakeSession
            @($m['deleted_files']).Count | Should -Be 0
        }
    }
}

# The headline incremental optimization -- reuse a previous SHA256 instead of recomputing it when a
# file's size AND last_write are both unchanged -- runs INSIDE the remote scan script block, on the
# node. The "remote scan mocked" tests above mock Invoke-SEBRemoteCommand wholesale and so never
# exercise that decision. The contract test (Tests/Contract/RemoteScriptBlock.Tests.ps1) forbids the
# remote block from calling any *-SEB* helper (none is imported on the node) or capturing C&C vars,
# so the decision cannot be extracted into an SEB helper the block calls -- doing so would break
# production AND fail that contract test. Instead we pin the REAL decision by lifting the actual
# script block out of New-SEBManifest.ps1 via the AST and invoking its body against a temp file set.
# This runs the production code, not a copy: flip the size/last_write '-eq' guard in the source and
# these assertions go red.
Describe 'New-SEBManifest remote scan -- hash-reuse optimization (real script block over temp files)' {

    BeforeAll {
        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $src = Join-Path $repoRoot 'Modules/ManifestManager/Public/New-SEBManifest.ps1'

        # Lift the literal script block passed to Invoke-SEBRemoteCommand straight out of the source.
        $tokens = $null; $parseErrors = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$parseErrors)
        $invokeCall = $fileAst.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-SEBRemoteCommand' },
            $true) | Select-Object -First 1
        $sbExpr = $invokeCall.CommandElements |
            Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } |
            Select-Object -First 1
        # GetScriptBlock() yields a real, invokable [scriptblock] from the AST node.
        $script:scanBlock = $sbExpr.ScriptBlock.GetScriptBlock()

        # A scan root with three files exercising each branch.
        $script:scanRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sebhashreuse_" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:scanRoot -Force | Out-Null

        $script:reuseFile   = Join-Path $script:scanRoot 'unchanged.sbs'   # size+last_write match -> reuse
        $script:rehashFile  = Join-Path $script:scanRoot 'touched.cfg'     # same size, changed mtime -> re-hash
        $script:newFile     = Join-Path $script:scanRoot 'brandnew.vx2'    # absent in previous -> hash
        Set-Content -Path $script:reuseFile  -Value 'unchanged-content' -NoNewline
        Set-Content -Path $script:rehashFile -Value 'samesize-content!' -NoNewline   # 17 chars, matches prev size below
        Set-Content -Path $script:newFile    -Value 'new-content-here' -NoNewline

        $reuseInfo  = [System.IO.FileInfo]::new($script:reuseFile)
        $rehashInfo = [System.IO.FileInfo]::new($script:rehashFile)

        # Previous manifest 'files' map fed to the block. A sentinel sha256 on each previous entry
        # lets us tell "reused the previous hash" from "freshly computed a real one" by inspection.
        $script:prevFiles = @{
            # Exact size + last_write match -> the block MUST reuse this sha256 and skip Get-FileHash.
            'unchanged.sbs' = @{
                size       = $reuseInfo.Length
                sha256     = 'sentinel_reused_hash'
                last_write = $reuseInfo.LastWriteTimeUtc.ToString('o')
            }
            # SAME size but a deliberately wrong last_write -> the block MUST re-hash (sentinel discarded).
            'touched.cfg'   = @{
                size       = $rehashInfo.Length
                sha256     = 'sentinel_stale_hash'
                last_write = '2000-01-01T00:00:00.0000000Z'
            }
            # 'brandnew.vx2' is intentionally absent from the previous map.
        }

        $script:scan = & $script:scanBlock -ScanPath $script:scanRoot -Excludes @() -PrevFiles $script:prevFiles
    }

    AfterAll {
        if ($script:scanRoot -and (Test-Path $script:scanRoot)) {
            Remove-Item -Recurse -Force $script:scanRoot -ErrorAction SilentlyContinue
        }
    }

    It 'reuses the previous sha256 (no re-hash) when size AND last_write are unchanged' {
        $script:scan.Files['unchanged.sbs'].sha256 | Should -Be 'sentinel_reused_hash' `
            -Because 'an unchanged file must carry the cached hash through verbatim'
    }

    It 'counts a reused file as Skipped, not Hashed' {
        # exactly one file (unchanged.sbs) qualifies for reuse
        $script:scan.SkippedCount | Should -Be 1
    }

    It 're-hashes a file whose size matches but whose last_write changed' {
        $entry = $script:scan.Files['touched.cfg']
        $entry.sha256 | Should -Not -Be 'sentinel_stale_hash' -Because 'a changed mtime must invalidate the cached hash'
        $entry.sha256 | Should -Match '^[0-9a-f]{64}$' -Because 'a freshly computed SHA256 is 64 lowercase hex chars'
    }

    It 'always hashes a file that was absent from the previous manifest' {
        $script:scan.Files.Keys | Should -Contain 'brandnew.vx2'
        $script:scan.Files['brandnew.vx2'].sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'counts both the re-hashed and the new file as Hashed' {
        # touched.cfg (re-hash) + brandnew.vx2 (new) = 2 hashed; unchanged.sbs is the only skip.
        $script:scan.HashedCount | Should -Be 2
    }

    It 'records every scanned file with the real on-disk size' {
        $script:scan.Files['unchanged.sbs'].size | Should -Be ([System.IO.FileInfo]::new($script:reuseFile).Length)
        $script:scan.Files['touched.cfg'].size   | Should -Be ([System.IO.FileInfo]::new($script:rehashFile).Length)
    }
}
