#Requires -Module Pester

# Remote-scope contract: Invoke-SEBWithShadowCopy and Invoke-SEBRemoteCommand run their
# script block in the REMOTE node runspace (Invoke-Command -Session). A script block sent
# there cannot call C&C-only SEB module functions (they are not imported on the node) and
# cannot read C&C-local variables unless they are passed via -ArgumentList and declared as
# params. This test fails the exact bug where the backup's VSS block called New-SEBManifest /
# Compare-SEBManifest and referenced $session / $result inside the remote runspace.

BeforeDiscovery {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:callerFiles = Get-ChildItem -Path "$repoRoot/Modules", "$repoRoot/Scripts" -Recurse -File -Filter '*.ps1' |
        ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Replace($repoRoot, '').TrimStart('\', '/') } }
}

Describe 'Remote-executed script blocks stay node-local' {
    It 'remote blocks in <Name> call no SEB functions and reference no C&C vars' -ForEach $script:callerFiles {
        # C&C-local variables that must never be referenced directly inside a remote block.
        # (Anything the block needs must arrive through param()/-ArgumentList instead.)
        $forbiddenVars = @(
            'session', 'result', 'warnings', 'backupDecision', 'globalConfig',
            'instanceConfig', 'nodeConfig', 'manifest', 'manifestDiff', 'hasLogger'
        )
        $remoteWrappers = @('Invoke-SEBWithShadowCopy', 'Invoke-SEBRemoteCommand')

        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)

        $violations = [System.Collections.Generic.List[string]]::new()

        $allCalls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        $calls = $allCalls | Where-Object { $_.GetCommandName() -in $remoteWrappers }

        foreach ($call in $calls) {
            $sb = $call.CommandElements |
                Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } |
                Select-Object -First 1
            if (-not $sb) { continue }

            # Any *-SEB* command invoked inside the remote block is unavailable on the node.
            $sebCalls = $sb.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                Where-Object { $_.GetCommandName() -and $_.GetCommandName() -match '-SEB' }
            foreach ($c in $sebCalls) {
                $violations.Add("L$($c.Extent.StartLineNumber): remote block calls C&C function $($c.GetCommandName())")
            }

            # Any forbidden C&C-local variable referenced inside the remote block.
            $vars = $sb.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
                Where-Object { $_.VariablePath.UserPath -in $forbiddenVars }
            foreach ($v in $vars) {
                $violations.Add("L$($v.Extent.StartLineNumber): remote block references C&C variable `$$($v.VariablePath.UserPath)")
            }
        }

        $violations -join "`n" | Should -BeNullOrEmpty -Because "remote script blocks must be self-contained:`n$($violations -join "`n")"
    }
}
