#Requires -Module Pester

# API contract lint: statically verify that every call to an exported SEBackup
# function passes only parameters that function actually declares. This catches the
# "orchestration authored against an imagined interface" bug class, where a caller
# binds e.g. -Config / -VolumeLetter / -Metric / -ManifestPath that the callee never
# defines, which throws a ParameterBindingException at runtime before any work happens.
#
# Splatted calls (@params) cannot be resolved statically and are skipped.

BeforeDiscovery {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:callerFiles = Get-ChildItem -Path $repoRoot -Recurse -Include '*.ps1' |
        Where-Object {
            $_.FullName -notmatch '[\\/](Tests|\.git|GUI)[\\/]' -and
            $_.FullName -match '[\\/](Public|Private|Scripts)[\\/]'
        } |
        ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Replace($repoRoot, '').TrimStart('\', '/') } }
}

BeforeAll {
    . "$PSScriptRoot/_ContractAst.ps1"   # memoized Get-ContractAst (shared parse cache)
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    $commonParameters = @(
        'Verbose', 'Debug', 'ErrorAction', 'ErrorVariable', 'WarningAction', 'WarningVariable',
        'InformationAction', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable',
        'WhatIf', 'Confirm', 'ProgressAction'
    )

    # Build map: exported SEB command name -> set of valid parameter names (incl. aliases + common)
    $script:cmdParams = @{}
    foreach ($cmd in Get-Command -Module SEBackup -CommandType Function) {
        $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in $commonParameters) { [void]$names.Add($n) }
        foreach ($p in $cmd.Parameters.Values) {
            [void]$names.Add($p.Name)
            foreach ($a in $p.Aliases) { [void]$names.Add($a) }
        }
        $script:cmdParams[$cmd.Name] = $names
    }

    function Test-ParameterName {
        param([System.Collections.Generic.HashSet[string]]$Valid, [string]$Used)
        if ($Valid.Contains($Used)) { return $true }
        # PowerShell allows unambiguous parameter-name prefixes. (Name it $prefixMatches, not
        # $matches -- $Matches is a PowerShell automatic variable and assigning to it has side
        # effects.)
        $prefixMatches = @($Valid | Where-Object { $_.StartsWith($Used, [System.StringComparison]::OrdinalIgnoreCase) })
        return ($prefixMatches.Count -eq 1)
    }
}

Describe 'Exported SEBackup functions are called with valid parameters' {
    It 'all SEB-function calls in <Name> use declared parameters' -ForEach $script:callerFiles {
        $ast = (Get-ContractAst -Path $Path).Ast

        $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)

        $violations = [System.Collections.Generic.List[string]]::new()
        foreach ($call in $calls) {
            $cmdName = $call.GetCommandName()
            if (-not $cmdName -or -not $script:cmdParams.ContainsKey($cmdName)) { continue }

            $elements = $call.CommandElements
            # Skip splatted invocations: cannot resolve parameter names statically.
            $hasSplat = $elements | Where-Object {
                $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted
            }
            if ($hasSplat) { continue }

            $valid = $script:cmdParams[$cmdName]
            foreach ($el in $elements) {
                if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $used = $el.ParameterName
                    if (-not (Test-ParameterName -Valid $valid -Used $used)) {
                        $violations.Add("L$($el.Extent.StartLineNumber): $cmdName -$used")
                    }
                }
            }
        }

        $violations -join "`n" | Should -BeNullOrEmpty -Because "every parameter must exist on the target function:`n$($violations -join "`n")"
    }
}
