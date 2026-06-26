#Requires -Module Pester

# Parse-integrity contract: every PowerShell source file in the project must parse
# with zero errors. A parse error in a Public/ function silently prevents that
# function from being dot-sourced (the module .psm1 import loop catches and skips it),
# so a single bad string interpolation can make an exported command vanish at runtime.

BeforeDiscovery {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:sourceFiles = Get-ChildItem -Path $repoRoot -Recurse -Include '*.ps1', '*.psm1' |
        Where-Object { $_.FullName -notmatch '[\\/](Tests|\.git)[\\/]' } |
        ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Replace($repoRoot, '').TrimStart('\', '/') } }
}

BeforeAll {
    . "$PSScriptRoot/_ContractAst.ps1"   # memoized Get-ContractAst (caches AST + parse errors)
}

Describe 'Source files parse without errors' {
    It 'parses <Name> with no syntax errors' -ForEach $script:sourceFiles {
        $errors = @((Get-ContractAst -Path $Path).Errors)
        $messages = ($errors | ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n"
        $errors.Count | Should -Be 0 -Because "the file must parse cleanly:`n$messages"
    }
}
