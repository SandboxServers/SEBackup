#Requires -Module Pester

# Resolve-SEBChainArchivePath turns a manifest's attacker-controllable 'archive_path' (and 'type')
# into an on-disk path that Test-SEBChainIntegrity / restore then EXTRACT. Issue #28 consolidated its
# hand-rolled denylist into the shared Test-SEBSafeName validator. These tests pin that the shared
# validator still rejects every unsafe archive_path shape (separators, '..' traversal, rooted paths,
# wildcard metacharacters, invalid filename chars) -- returning $null per the helper's
# "unsafe -> $null (archive not found)" contract -- while a legitimate engine-style bare filename
# resolves under <InstanceDir>/<type>/. The helper is private to IntegrityManager, so it is exercised
# via InModuleScope (Test-SEBSafeName resolves from the session because Logger loads first).

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null
}

Describe 'Resolve-SEBChainArchivePath uses the shared Test-SEBSafeName validator (issue #28)' {

    Context 'rejects unsafe archive_path values (returns $null)' {
        It "rejects archive_path '<Bad>' (<Why>)" -ForEach @(
            @{ Bad = '..\evil.7z';        Why = 'back-slash traversal' }
            @{ Bad = '../evil.7z';        Why = 'forward-slash traversal' }
            @{ Bad = 'sub\evil.7z';       Why = 'back-slash separator' }
            @{ Bad = 'sub/evil.7z';       Why = 'forward-slash separator' }
            @{ Bad = 'C:\evil.7z';        Why = 'drive-rooted path' }
            @{ Bad = '\\srv\share\e.7z';  Why = 'UNC root' }
            @{ Bad = '*.7z';              Why = 'star wildcard (Test-Path pattern)' }
            @{ Bad = 'evil?.7z';          Why = 'question wildcard' }
            @{ Bad = 'a[x].7z';           Why = 'bracket character class' }
            @{ Bad = 'foo..bar.7z';       Why = "embedded '..' sequence" }
            @{ Bad = 'evil<.7z';          Why = 'invalid filename char <' }
        ) {
            $bad = $Bad
            InModuleScope IntegrityManager -Parameters @{ bad = $bad } {
                param($bad)
                $manifest = [PSCustomObject]@{ type = 'full'; archive_path = $bad; _source_filename = 'X_FULL_1.json' }
                # InstanceDir need not exist on disk: an unsafe archive_path is rejected before any
                # filesystem access, so the result is $null.
                $result = Resolve-SEBChainArchivePath -Manifest $manifest -InstanceDir 'C:\SEBackup\Backups\Inst'
                $result | Should -BeNullOrEmpty -Because "an unsafe archive_path must resolve to `$null"
            }
        }

        It 'rejects an invalid type (not full/incremental) before touching archive_path' {
            InModuleScope IntegrityManager {
                $manifest = [PSCustomObject]@{ type = '..'; archive_path = 'X_FULL_1.7z'; _source_filename = 'X_FULL_1.json' }
                Resolve-SEBChainArchivePath -Manifest $manifest -InstanceDir 'C:\SEBackup\Backups\Inst' | Should -BeNullOrEmpty
            }
        }
    }

    Context 'accepts a legitimate bare archive filename' {
        It 'resolves a normal engine-style archive_path under <type>/ (and ACCEPTS a dotted name)' {
            $instDir = Join-Path ([System.IO.Path]::GetTempPath()) ("sebres_" + [guid]::NewGuid().ToString('n'))
            $fullDir = Join-Path $instDir 'full'
            New-Item -Path $fullDir -ItemType Directory -Force | Out-Null
            try {
                InModuleScope IntegrityManager -Parameters @{ instDir = $instDir; fullDir = $fullDir } {
                    param($instDir, $fullDir)
                    # A '.' in the name is filename-legal and must be allowed (the shared validator only
                    # rejects the '..' SEQUENCE, separators, rooting, wildcards, invalid chars).
                    $manifest = [PSCustomObject]@{ type = 'full'; archive_path = 'Inst.PvP_FULL_20260201_020000.7z'; _source_filename = 'Inst.PvP_FULL_20260201_020000.json' }
                    $resolved = Resolve-SEBChainArchivePath -Manifest $manifest -InstanceDir $instDir
                    $resolved | Should -Not -BeNullOrEmpty
                    (Split-Path -Path $resolved -Leaf) | Should -Be 'Inst.PvP_FULL_20260201_020000.7z'
                    (Split-Path -Path (Split-Path -Path $resolved -Parent) -Leaf) | Should -Be 'full'
                }
            }
            finally {
                Remove-Item -LiteralPath $instDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
