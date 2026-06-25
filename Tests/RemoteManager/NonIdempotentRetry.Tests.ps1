#Requires -Module Pester

# Static guard for issue #22: every NON-IDEMPOTENT remote call routed through
# Invoke-SEBRemoteCommand must pass -RetryCount 0, so a transport drop AFTER the node mutated is
# NOT silently re-run by the wrapper's default RetryCount=1 (which would double-execute the
# mutation: e.g. a second world rename, a second VSS Create, a second service stop). The retry is
# correct ONLY for idempotent reads.
#
# This file has TWO layers:
#   1. A DRIFT-RESISTANT guard (the important one): it AST-enumerates EVERY Invoke-SEBRemoteCommand
#      call across Modules/ and Scripts/ (the same enumeration approach as
#      Tests/Contract/RemoteScriptBlock.Tests.ps1), classifies each by whether its script-block text
#      contains a MUTATING verb, and FAILS if a mutating call lacks -RetryCount 0. A developer who
#      adds a new mutating remote call and forgets -RetryCount 0 turns a silent data-corruption
#      regression into a RED test, instead of shipping green. New sites need no hand-maintenance.
#   2. A small set of per-site positive assertions that pin specific known mutating blocks by a
#      unique marker, giving a readable, intention-revealing failure if one ever drops -RetryCount 0.
#
# Invoke-SEBWithShadowCopy is intentionally NOT subject to the -RetryCount 0 rule: it does not take
# a -RetryCount and never retries (it runs the user block via a single raw Invoke-Command), so a
# mutating block handed to it is not a wrapper-double-execution hazard. Only Invoke-SEBRemoteCommand
# retries, so it is the only call the guard polices.

BeforeAll {
    # Resolve at run time (BeforeDiscovery-scoped vars do not survive into the run phase).
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
}

BeforeDiscovery {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path

    # --- Mutating-verb classifier ------------------------------------------------------------
    # If a remote block's text contains any of these, it mutates node state and (unless it is a
    # justified idempotent-by-construction exception, below) MUST carry -RetryCount 0.
    $script:mutatingPatterns = @(
        'Remove-Item', 'New-Item', 'Rename-Item', 'Move-Item',
        'Start-Service', 'Stop-Service', 'robocopy', 'mklink',
        'Win32_ShadowCopy', 'Remove-CimInstance'
    )
    # 'rd ' (the cmd.exe rmdir builtin used for symlink teardown) handled separately so it does not
    # match substrings like 'Record ' or 'Standard '.
    $script:rdPattern = '(?m)(^|\s|/c\s+)rd\s'

    # --- Justified exceptions ----------------------------------------------------------------
    # Calls whose block text trips the mutating classifier but are SAFE to re-run by construction,
    # so default retry is intentional (not a bug). Each must be justified. A NEW mutating call will
    # NOT be in this list and therefore still fails the guard unless it adds -RetryCount 0.
    #   { File; Marker } -- Marker is a substring unique to that call's block.
    $script:retryExceptions = @(
        @{ File = 'Modules/VSSManager/Private/Test-SEBVSSService.ps1'
           Marker = 'Attempt to create a test shadow copy'
           Why = 'creates a test shadow copy and immediately removes it in the same block; re-running just re-probes VSS health (any failure => "not functional"), so it is idempotent.' }
        @{ File = 'Modules/VSSManager/Public/Clear-SEBOrphanShadowCopies.ps1'
           Marker = 'orphaned mount point symlinks'
           Why = 'scans for and deletes the CURRENTLY-orphaned shadow copies/mounts; re-running re-scans the then-current state, which is exactly the orphan-cleanup contract.' }
    )

    # --- AST enumeration of every Invoke-SEBRemoteCommand call --------------------------------
    function script:Test-BlockIsMutating([string]$text) {
        foreach ($p in $script:mutatingPatterns) {
            if ($text -match [regex]::Escape($p)) { return $true }
        }
        if ($text -match $script:rdPattern) { return $true }
        return $false
    }

    function script:Test-IsRetryException([string]$relFile, [string]$blockText) {
        $relNorm = $relFile -replace '\\', '/'
        foreach ($ex in $script:retryExceptions) {
            $exNorm = $ex.File -replace '\\', '/'
            if ($relNorm -eq $exNorm -and $blockText -match [regex]::Escape($ex.Marker)) { return $true }
        }
        return $false
    }

    $files = Get-ChildItem -Path "$repoRoot/Modules", "$repoRoot/Scripts" -Recurse -File -Filter '*.ps1'
    $allCalls = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        if ($errors) { continue }  # parse errors are caught by the dedicated Parse contract test
        $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Where-Object { $_.GetCommandName() -eq 'Invoke-SEBRemoteCommand' }
        foreach ($call in $calls) {
            $sb = $call.CommandElements |
                Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } |
                Select-Object -First 1
            $sbText = if ($sb) { $sb.Extent.Text } else { '' }
            $relFile = $f.FullName.Replace($repoRoot, '').TrimStart('\', '/')

            # Extract -RetryCount value (attached to the parameter ast or the next element).
            $retryValue = $null
            $els = $call.CommandElements
            for ($i = 0; $i -lt $els.Count; $i++) {
                $el = $els[$i]
                if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $el.ParameterName -eq 'RetryCount') {
                    if ($null -ne $el.Argument) { $retryValue = $el.Argument.Extent.Text }
                    elseif ($i + 1 -lt $els.Count) { $retryValue = $els[$i + 1].Extent.Text }
                    break
                }
            }

            $allCalls.Add(@{
                File       = $relFile
                Line       = $call.Extent.StartLineNumber
                IsMutating = (script:Test-BlockIsMutating $sbText)
                IsException= (script:Test-IsRetryException $relFile $sbText)
                RetryValue = $retryValue
            })
        }
    }

    # Cases the drift guard iterates: every mutating call that is NOT a justified exception.
    $script:mutatingCalls = @(
        $allCalls | Where-Object { $_.IsMutating -and -not $_.IsException } |
            ForEach-Object { @{ File = $_.File; Line = $_.Line; RetryValue = $_.RetryValue } }
    )
    # Sanity case fed by value (discovery-phase $script: vars do not survive into the run phase, so
    # the count is captured here and passed through -ForEach rather than re-read at run time).
    $script:guardSanity = @(@{ MutatingCount = @($script:mutatingCalls).Count })

    # --- Per-site positive markers (readable, intention-revealing pins for known mutating sites).
    # These overlap with the drift guard above but give a named failure per critical site, including
    # the three previously-unguarded cleanup/temp sites.
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
        # The three sites the previous hand-maintained list missed (now also covered by the drift guard):
        @{ File = 'Modules/RestoreEngine/Public/Invoke-SEBRestore.ps1';        Marker = 'New-Item -Path $tempDir'; Why = 'restore temp-dir remove+recreate' }
        @{ File = 'Modules/RestoreEngine/Public/Invoke-SEBRestore.ps1';        Marker = "clean up the restore_temp parent if empty"; Why = 'STEP 11 restore temp cleanup' }
        @{ File = 'Modules/BackupEngine/Public/Invoke-SEBBackup.ps1';          Marker = 'Remove the staging directory'; Why = 'STEP 17 backup staging cleanup' }
    )
}

Describe 'Non-idempotent remote calls pass -RetryCount 0 (drift-resistant guard)' {
    It 'every mutating Invoke-SEBRemoteCommand call carries -RetryCount 0 (<File>:<Line>)' -ForEach $script:mutatingCalls {
        # $RetryValue is the literal text of the -RetryCount argument, or $null if absent.
        $RetryValue | Should -Be '0' -Because @"
$File line $Line routes a MUTATING remote block through Invoke-SEBRemoteCommand without -RetryCount 0.
The default RetryCount=1 would RE-RUN the mutation on a post-mutation transport drop (data corruption).
Add -RetryCount 0, or -- if the block is genuinely safe to re-run -- add a justified entry to
`$script:retryExceptions in this test (BeforeDiscovery) explaining why.
"@
    }

    It 'finds at least the known mutating call sites (guard is actually enumerating)' -ForEach $script:guardSanity {
        # Sanity: if this drops low the enumeration broke (e.g. a path/glob change) and the guard
        # would silently pass everything. The repo has well over a dozen guarded mutating sites.
        $MutatingCount | Should -BeGreaterThan 8
    }
}

Describe 'Non-idempotent remote calls pass -RetryCount 0 (named per-site pins)' {
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
