#Requires -Module Pester

# Manifest GUID contract: every module manifest (.psd1) must carry a GUID that parses
# as a valid [guid], and no two manifests may share a GUID. A malformed GUID (e.g. a
# non-hex character from a typo) or a duplicated GUID (e.g. copy-paste between modules)
# can make strict tooling such as Test-ModuleManifest fail and breaks module identity,
# so this is enforced as a hard contract across all manifests including the root.

BeforeDiscovery {
    # Enumerate and parse every manifest exactly once here. The resulting list feeds both
    # the per-manifest validity test (via -ForEach) and the uniqueness test below, so the
    # filesystem is walked and each manifest is read a single time.
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:manifests = @(
        @(Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.psd1')
        Get-Item -Path "$repoRoot/SEBackup.psd1"
    ) | ForEach-Object {
        $data = Import-PowerShellDataFile -Path $_.FullName
        $hasGuid = $data.ContainsKey('GUID')
        @{
            Path        = $_.FullName
            Name        = $_.FullName.Replace($repoRoot, '').TrimStart('\', '/')
            HasGuid     = $hasGuid
            # Raw declared GUID (may be $null/absent); the validity test asserts it parses.
            Guid        = if ($hasGuid) { [string]$data.GUID } else { $null }
        }
    }
}

Describe 'Module manifest GUIDs' {

    Context 'Each manifest has a valid GUID' {
        It 'has a parseable [guid] in <Name>' -ForEach $script:manifests {
            $HasGuid | Should -BeTrue -Because "$Name must declare a GUID"

            [guid]$parsed = [guid]::Empty
            [guid]::TryParse($Guid, [ref]$parsed) |
                Should -BeTrue -Because "the GUID '$Guid' in $Name must be a valid GUID"
        }
    }

    Context 'GUIDs are unique across all manifests' {
        It 'has no two manifests sharing a GUID' {
            # Reuse the single enumeration captured in BeforeDiscovery; do not re-walk the
            # filesystem or re-parse the manifests. Canonicalize each GUID to a [guid] so two
            # different textual representations of the same value still count as a collision.
            $byGuid = $script:manifests | ForEach-Object {
                [guid]$canonical = [guid]::Empty
                $parsed = [guid]::TryParse([string]$_.Guid, [ref]$canonical)
                [pscustomobject]@{
                    Name = $_.Name
                    # 'D' is the canonical 8-4-4-4-12 form; fall back to the raw value if a
                    # GUID is unparseable (the validity test already flags that separately).
                    Guid = if ($parsed) { $canonical.ToString('D') } else { [string]$_.Guid }
                }
            } | Group-Object -Property Guid | Where-Object { $_.Count -gt 1 }

            $collisions = ($byGuid | ForEach-Object {
                "GUID $($_.Name) shared by: " + (($_.Group.Name) -join ', ')
            }) -join "`n"

            $byGuid.Count | Should -Be 0 -Because "every manifest must have a unique GUID:`n$collisions"
        }
    }
}
