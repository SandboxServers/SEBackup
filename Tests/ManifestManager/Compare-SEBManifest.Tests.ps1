#Requires -Module Pester

# Issue #19 -- unit coverage for the manifest diff that drives incremental backups.
#
# Compare-SEBManifest classifies every file in (current vs previous) into Added / Modified /
# Deleted / Unchanged by SHA256, and reports the counts the backup engine uses to decide what
# goes into the incremental archive. This is pure hashtable-in / object-out, so it is exercised
# with in-memory manifest hashtables -- no remote node, no mocks.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # Build a manifest 'files' entry the way New-SEBManifest records it.
    function New-FileEntry {
        param([long]$Size, [string]$Sha256, [string]$LastWrite = '2026-01-01T00:00:00.0000000Z')
        @{ size = $Size; sha256 = $Sha256; last_write = $LastWrite }
    }

    # Wrap a files hashtable in a minimal v2 manifest shell.
    function New-ManifestFromFiles {
        param([hashtable]$Files)
        @{
            version        = 2
            type           = 'full'
            chain_id       = 'chain-1'
            chain_sequence = 0
            files          = $Files
            deleted_files  = @()
        }
    }
}

Describe 'Compare-SEBManifest' {

    It 'classifies unchanged / modified / added / deleted in one pass' {
        $previous = New-ManifestFromFiles @{
            'unchanged.cfg' = New-FileEntry -Size 10 -Sha256 'aaaa'
            'modified.sbs'  = New-FileEntry -Size 20 -Sha256 'bbbb'
            'gone.tmp'      = New-FileEntry -Size 30 -Sha256 'cccc'
        }
        $current = New-ManifestFromFiles @{
            'unchanged.cfg' = New-FileEntry -Size 10 -Sha256 'aaaa'         # same hash -> unchanged
            'modified.sbs'  = New-FileEntry -Size 25 -Sha256 'dddd'         # hash differs -> modified
            'new.vx2'       = New-FileEntry -Size 40 -Sha256 'eeee'         # only in current -> added
            # 'gone.tmp' absent in current -> deleted
        }

        $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous

        $diff.Unchanged | Should -Be @('unchanged.cfg')
        $diff.Modified  | Should -Be @('modified.sbs')
        $diff.Added     | Should -Be @('new.vx2')
        $diff.Deleted   | Should -Be @('gone.tmp')
    }

    It 'reports a content change as Modified when only the hash differs' {
        # Size/last_write are irrelevant to the diff -- classification is purely by SHA256.
        $previous = New-ManifestFromFiles @{ 'world.sbs' = New-FileEntry -Size 100 -Sha256 'oldhash' -LastWrite '2026-01-01T00:00:00.0000000Z' }
        $current  = New-ManifestFromFiles @{ 'world.sbs' = New-FileEntry -Size 100 -Sha256 'newhash' -LastWrite '2026-01-01T00:00:00.0000000Z' }

        $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous
        $diff.ModifiedCount  | Should -Be 1
        $diff.UnchangedCount | Should -Be 0
        $diff.Modified       | Should -Contain 'world.sbs'
    }

    It 'treats identical manifests as fully unchanged with zero total changes' {
        $files = @{
            'a.cfg' = New-FileEntry -Size 1 -Sha256 '1111'
            'b.cfg' = New-FileEntry -Size 2 -Sha256 '2222'
        }
        $diff = Compare-SEBManifest -CurrentManifest (New-ManifestFromFiles $files) -PreviousManifest (New-ManifestFromFiles $files)

        $diff.UnchangedCount | Should -Be 2
        $diff.AddedCount     | Should -Be 0
        $diff.ModifiedCount  | Should -Be 0
        $diff.DeletedCount   | Should -Be 0
        $diff.TotalChanges   | Should -Be 0 -Because 'TotalChanges = added + modified + deleted only'
    }

    It 'counts every current file as Added when the previous manifest is empty' {
        $current = New-ManifestFromFiles @{
            'a.cfg' = New-FileEntry -Size 1 -Sha256 '1111'
            'b.cfg' = New-FileEntry -Size 2 -Sha256 '2222'
        }
        $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest (New-ManifestFromFiles @{})

        $diff.AddedCount     | Should -Be 2
        $diff.DeletedCount   | Should -Be 0
        $diff.UnchangedCount | Should -Be 0
        $diff.TotalChanges   | Should -Be 2
    }

    It 'counts every previous file as Deleted when the current manifest is empty' {
        $previous = New-ManifestFromFiles @{
            'a.cfg' = New-FileEntry -Size 1 -Sha256 '1111'
            'b.cfg' = New-FileEntry -Size 2 -Sha256 '2222'
        }
        $diff = Compare-SEBManifest -CurrentManifest (New-ManifestFromFiles @{}) -PreviousManifest $previous

        $diff.DeletedCount   | Should -Be 2
        $diff.AddedCount     | Should -Be 0
        $diff.UnchangedCount | Should -Be 0
        $diff.TotalChanges   | Should -Be 2
    }

    It 'tolerates a manifest with no files key by treating it as empty' {
        # Compare-SEBManifest defaults a missing 'files' key to @{}; a manifest without it must not throw.
        $previous = @{ version = 2; type = 'full' }   # no 'files'
        $current  = New-ManifestFromFiles @{ 'new.cfg' = New-FileEntry -Size 1 -Sha256 'ffff' }

        $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous
        $diff.AddedCount   | Should -Be 1
        $diff.DeletedCount | Should -Be 0
    }

    It 'returns count properties that agree with the array lengths' {
        $previous = New-ManifestFromFiles @{
            'keep.cfg' = New-FileEntry -Size 1 -Sha256 'same'
            'edit.sbs' = New-FileEntry -Size 2 -Sha256 'old'
            'drop.tmp' = New-FileEntry -Size 3 -Sha256 'bye'
        }
        $current = New-ManifestFromFiles @{
            'keep.cfg' = New-FileEntry -Size 1 -Sha256 'same'
            'edit.sbs' = New-FileEntry -Size 2 -Sha256 'new'
            'add.vx2'  = New-FileEntry -Size 4 -Sha256 'hi'
        }

        $diff = Compare-SEBManifest -CurrentManifest $current -PreviousManifest $previous

        $diff.AddedCount     | Should -Be $diff.Added.Count
        $diff.ModifiedCount  | Should -Be $diff.Modified.Count
        $diff.DeletedCount   | Should -Be $diff.Deleted.Count
        $diff.UnchangedCount | Should -Be $diff.Unchanged.Count
        $diff.TotalChanges   | Should -Be ($diff.AddedCount + $diff.ModifiedCount + $diff.DeletedCount)
    }
}
