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

    function New-FileEntry {
        param([long]$Size, [string]$Sha256, [string]$LastWrite = '2026-01-01T00:00:00.0000000Z')
        @{ size = $Size; sha256 = $Sha256; last_write = $LastWrite }
    }
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
                    'world.sbs' = @{ size = 100; sha256 = 'oldhash'; last_write = '2026-01-01T00:00:00.0000000Z' }
                    'old.tmp'   = @{ size = 10;  sha256 = 'tmphash'; last_write = '2026-01-01T00:00:00.0000000Z' }
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
                files          = @{ 'a.cfg' = @{ size = 1; sha256 = 'x'; last_write = '2026-01-01T00:00:00.0000000Z' } }
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
                files   = @{ 'keep.cfg' = @{ size = 1; sha256 = 'same'; last_write = '2026-01-01T00:00:00.0000000Z' } }
            }
            $m = New-SEBManifest -SourcePath 'E:\Shadow\Inst' -PreviousManifest $previous -Session $script:fakeSession
            @($m['deleted_files']).Count | Should -Be 0
        }
    }
}
