#Requires -Module Pester

# Export contract: every Public/ function across the sub-modules must be listed in the
# root manifest's FunctionsToExport. A function that exists but is not exported is
# invisible to anyone importing the SEBackup module (and to callers that depend on it),
# which is how the RestoreEngine and MetricsCollector functions ended up dead.
#
# This file also enforces the REVERSE direction and the wider export wiring (issue #21):
#   - reverse-export: every root FunctionsToExport entry has a backing Public/*.ps1 file;
#   - the root manifest's export set equals the union of every sub-module manifest's exports;
#   - every module directory on disk (one carrying a matching <Name>.psd1/.psm1 -- see below) is
#     listed in the root SEBackup.psm1 $Modules array.

BeforeDiscovery {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:publicFunctions = Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.ps1' |
        Where-Object { $_.FullName -match '[\\/]Public[\\/]' } |
        ForEach-Object { @{ Name = $_.BaseName } }
}

BeforeAll {
    . "$PSScriptRoot/_ContractAst.ps1"   # memoized Get-ContractAst (shared parse cache)
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path

    $manifest = Import-PowerShellDataFile -Path "$repoRoot/SEBackup.psd1"
    $script:exported = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$manifest.FunctionsToExport, [System.StringComparer]::OrdinalIgnoreCase)

    # Basenames of every Public/*.ps1 across the sub-modules (the set of functions that SHOULD
    # be exported). Used by the reverse-export check.
    $script:publicBasenames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.ps1' |
        Where-Object { $_.FullName -match '[\\/]Public[\\/]' } |
        ForEach-Object { [void]$script:publicBasenames.Add($_.BaseName) }

    # Union of every sub-module manifest's FunctionsToExport.
    $script:moduleExportUnion = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($mm in @(Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.psd1')) {
        $md = Import-PowerShellDataFile -Path $mm.FullName
        foreach ($fn in [string[]]$md.FunctionsToExport) { if ($fn) { [void]$script:moduleExportUnion.Add($fn) } }
    }

    # The $Modules array from the root SEBackup.psm1, read via AST (not by executing the module).
    $psm1Ast = (Get-ContractAst -Path "$repoRoot/SEBackup.psm1").Ast
    $assign = @($psm1Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
        Where-Object { $_.Left.Extent.Text -eq '$Modules' }) | Select-Object -First 1
    $script:listedModules = @()
    if ($assign) {
        $script:listedModules = @($assign.Right.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true).Value)
    }

    # A directory under Modules/ counts as a MODULE only if it carries a matching manifest/module
    # file (<Name>.psd1 or <Name>.psm1), exactly as SEBackup.psm1 imports them
    # (Modules\<Name>\<Name>.psm1). This deliberately IGNORES non-module directories that can appear
    # under Modules/ -- e.g. the gitignored Modules/Credentials/ that the DPAPI credential resolver
    # may create at runtime (.gitignore), or a leftover test fixture. Treating ANY subdirectory as a
    # module made the "every module dir is listed" rule FAIL on such a stray dir and block every PR.
    $script:moduleDirs = @(
        Get-ChildItem -Path "$repoRoot/Modules" -Directory | Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName "$($_.Name).psd1")) -or
            (Test-Path -LiteralPath (Join-Path $_.FullName "$($_.Name).psm1"))
        } | Select-Object -ExpandProperty Name
    )
}

Describe 'Root manifest exports every public sub-module function' {
    It 'exports <Name>' -ForEach $script:publicFunctions {
        $script:exported.Contains($Name) | Should -BeTrue -Because "$Name is a Public/ function and must be in SEBackup.psd1 FunctionsToExport"
    }
}

Describe 'Export wiring is internally consistent' {

    It 'every FunctionsToExport entry has a backing Public/*.ps1 (reverse-export)' {
        $orphans = @($script:exported | Where-Object { -not $script:publicBasenames.Contains($_) })
        $orphans -join ', ' | Should -BeNullOrEmpty -Because "each exported name needs a matching Public/ file; orphaned exports: $($orphans -join ', ')"
    }

    It 'root FunctionsToExport equals the union of all sub-module manifest exports' {
        $inRootOnly = @($script:exported | Where-Object { -not $script:moduleExportUnion.Contains($_) })
        $inModuleOnly = @($script:moduleExportUnion | Where-Object { -not $script:exported.Contains($_) })
        $inRootOnly -join ', ' | Should -BeNullOrEmpty -Because "root exports a name no sub-module manifest exports: $($inRootOnly -join ', ')"
        $inModuleOnly -join ', ' | Should -BeNullOrEmpty -Because "a sub-module exports a name the root manifest omits: $($inModuleOnly -join ', ')"
    }

    It 'every module directory is listed in the root SEBackup.psm1 $Modules array' {
        $script:listedModules.Count | Should -BeGreaterThan 0 -Because "the $Modules array must be parseable from SEBackup.psm1"
        $missing = @($script:moduleDirs | Where-Object { $_ -notin $script:listedModules })
        $missing -join ', ' | Should -BeNullOrEmpty -Because "module dir(s) not imported by SEBackup.psm1: $($missing -join ', ')"
    }

    It 'every $Modules entry maps to a module directory on disk' {
        $dangling = @($script:listedModules | Where-Object { $_ -notin $script:moduleDirs })
        $dangling -join ', ' | Should -BeNullOrEmpty -Because "SEBackup.psm1 lists module(s) with no directory: $($dangling -join ', ')"
    }
}
