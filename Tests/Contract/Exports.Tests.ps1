#Requires -Module Pester

# Export contract: every Public/ function across the sub-modules must be listed in the
# root manifest's FunctionsToExport. A function that exists but is not exported is
# invisible to anyone importing the SEBackup module (and to callers that depend on it),
# which is how the RestoreEngine and MetricsCollector functions ended up dead.

BeforeDiscovery {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:publicFunctions = Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.ps1' |
        Where-Object { $_.FullName -match '[\\/]Public[\\/]' } |
        ForEach-Object { @{ Name = $_.BaseName } }
}

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $manifest = Import-PowerShellDataFile -Path "$repoRoot/SEBackup.psd1"
    $script:exported = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$manifest.FunctionsToExport, [System.StringComparer]::OrdinalIgnoreCase)
}

Describe 'Root manifest exports every public sub-module function' {
    It 'exports <Name>' -ForEach $script:publicFunctions {
        $script:exported.Contains($Name) | Should -BeTrue -Because "$Name is a Public/ function and must be in SEBackup.psd1 FunctionsToExport"
    }
}
