#Requires -Module Pester

# Manifest GUID contract: every module manifest (.psd1) must carry a GUID that parses
# as a valid [guid], and no two manifests may share a GUID. A malformed GUID (e.g. a
# non-hex character from a typo) or a duplicated GUID (e.g. copy-paste between modules)
# can make strict tooling such as Test-ModuleManifest fail and breaks module identity,
# so this is enforced as a hard contract across all manifests including the root.

BeforeDiscovery {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:manifests = @(
        @(Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.psd1')
        Get-Item -Path "$repoRoot/SEBackup.psd1"
    ) | ForEach-Object {
        @{
            Path = $_.FullName
            Name = $_.FullName.Replace($repoRoot, '').TrimStart('\', '/')
        }
    }
}

Describe 'Module manifest GUIDs' {

    Context 'Each manifest has a valid GUID' {
        It 'has a parseable [guid] in <Name>' -ForEach $script:manifests {
            $data = Import-PowerShellDataFile -Path $Path
            $data.ContainsKey('GUID') | Should -BeTrue -Because "$Name must declare a GUID"

            [guid]$parsed = [guid]::Empty
            [guid]::TryParse([string]$data.GUID, [ref]$parsed) |
                Should -BeTrue -Because "the GUID '$($data.GUID)' in $Name must be a valid GUID"
        }
    }

    Context 'GUIDs are unique across all manifests' {
        It 'has no two manifests sharing a GUID' {
            $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
            $files = @(
                @(Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.psd1')
                Get-Item -Path "$repoRoot/SEBackup.psd1"
            )

            $byGuid = $files | ForEach-Object {
                $data = Import-PowerShellDataFile -Path $_.FullName
                [pscustomobject]@{
                    Name = $_.FullName.Replace($repoRoot, '').TrimStart('\', '/')
                    Guid = ([string]$data.GUID).ToLowerInvariant()
                }
            } | Group-Object -Property Guid | Where-Object { $_.Count -gt 1 }

            $collisions = ($byGuid | ForEach-Object {
                "GUID $($_.Name) shared by: " + (($_.Group.Name) -join ', ')
            }) -join "`n"

            $byGuid.Count | Should -Be 0 -Because "every manifest must have a unique GUID:`n$collisions"
        }
    }
}
