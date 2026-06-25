#Requires -Module Pester

# Static guard for issue #22: every NON-IDEMPOTENT remote call routed through
# Invoke-SEBRemoteCommand must pass -RetryCount 0, so a transport drop AFTER the node mutated is
# NOT silently re-run by the wrapper's default RetryCount=1 (which would double-execute the
# mutation: e.g. a second world rename, a second VSS Create, a second service stop). The retry is
# correct ONLY for idempotent reads, so this test pins the classification at the call sites rather
# than trusting a comment.
#
# It parses each file, finds the Invoke-SEBRemoteCommand call whose script-block text contains the
# given marker (a string unique to that block), and asserts the call carries -RetryCount 0.

BeforeAll {
    # Resolve at run time (BeforeDiscovery-scoped vars do not survive into the run phase).
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
}

BeforeDiscovery {
    # file (relative) -> @{ Marker = <substring unique to the mutating block>; Why = ... }
    $script:mutatingSites = @(
        @{ File = 'Modules/RestoreEngine/Private/Deploy-SEBRestoredFiles.ps1'; Marker = 'prerestore'; Why = 'world rename + robocopy deploy' }
        @{ File = 'Modules/RestoreEngine/Public/Undo-SEBRestore.ps1';          Marker = 'postrestore'; Why = 'undo rename-back mutation' }
        @{ File = 'Modules/VSSManager/Public/New-SEBShadowCopy.ps1';           Marker = 'Win32_ShadowCopy'; Why = 'VSS snapshot Create' }
        @{ File = 'Modules/VSSManager/Public/Mount-SEBShadowCopy.ps1';         Marker = 'mklink'; Why = 'VSS mount symlink' }
        @{ File = 'Modules/VSSManager/Public/Dismount-SEBShadowCopy.ps1';      Marker = 'rd '; Why = 'VSS dismount' }
        @{ File = 'Modules/VSSManager/Public/Remove-SEBShadowCopy.ps1';        Marker = 'Remove-CimInstance'; Why = 'VSS remove' }
        @{ File = 'Modules/RestoreEngine/Private/Stop-SEBTorchServer.ps1';     Marker = 'Stop-Service'; Why = 'service stop' }
        @{ File = 'Modules/RestoreEngine/Private/Start-SEBTorchServer.ps1';    Marker = 'Start-Service'; Why = 'service start' }
        @{ File = 'Modules/BackupEngine/Public/Invoke-SEBBackup.ps1';          Marker = 'KeepRelative'; Why = 'incremental prune delete' }
        @{ File = 'Modules/RestoreEngine/Public/Invoke-SEBRestore.ps1';        Marker = '7z'; Why = 'archive extraction' }
    )
}

Describe 'Non-idempotent remote calls pass -RetryCount 0' {
    It 'in <File> the <Why> block is called with -RetryCount 0' -ForEach $script:mutatingSites {
        $path = Join-Path $script:repoRoot $File
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty -Because "the file must parse"

        $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Where-Object { $_.GetCommandName() -eq 'Invoke-SEBRemoteCommand' }

        # Pick the call whose script-block argument text contains the marker for this mutating block.
        $target = $null
        foreach ($call in $calls) {
            $sb = $call.CommandElements |
                Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } |
                Select-Object -First 1
            if ($sb -and $sb.Extent.Text -match [regex]::Escape($Marker)) { $target = $call; break }
        }
        $target | Should -Not -BeNullOrEmpty -Because "must find the Invoke-SEBRemoteCommand call whose block contains '$Marker'"

        # Find -RetryCount and assert its value argument is 0.
        $retryValue = $null
        $els = $target.CommandElements
        for ($i = 0; $i -lt $els.Count; $i++) {
            $el = $els[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                $el.ParameterName -eq 'RetryCount') {
                # Value may be attached to the parameter ast or be the next element.
                if ($null -ne $el.Argument) { $retryValue = $el.Argument.Extent.Text }
                elseif ($i + 1 -lt $els.Count) { $retryValue = $els[$i + 1].Extent.Text }
                break
            }
        }

        $retryValue | Should -Be '0' -Because "$Why mutates the node and must not be re-run by a retry"
    }
}
