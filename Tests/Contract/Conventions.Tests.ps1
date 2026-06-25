#Requires -Module Pester

# Convention contract: a single layer that guards the CLAUDE.md authoring rules across the
# WHOLE codebase, so convention drift is caught once rather than per function. Each rule below
# corresponds to a section of CLAUDE.md (naming, comment-based help, [CmdletBinding]/[OutputType],
# one-function-per-file, approved verbs, no aliases, no Write-Host in module code).
#
# WHY allow-lists: some rules are already GREEN everywhere and are enforced strictly (no baseline).
# A few rules have *pre-existing* violations that pre-date this contract. Following the build.ps1
# PSScriptAnalyzer-baseline pattern, those are captured as small DOCUMENTED allow-lists so the
# contract is GREEN now yet still fails on any NEW drift. Shrink the allow-lists as code is fixed.

BeforeDiscovery {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path

    # -- Shared AST helper ---------------------------------------------------------------------
    function script:Get-ContractFunctionInfo {
        # Returns one hashtable per function definition found in $Path, with the metadata each
        # convention test needs. TopLevel=$true means the function is at file scope (not nested
        # inside another function) -- used by the one-function-per-file rule.
        param([string]$Path)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $topLevel = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
        $all = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        foreach ($fn in $all) {
            $attrs = @()
            if ($fn.Body.ParamBlock) { $attrs = @($fn.Body.ParamBlock.Attributes.TypeName.FullName) }
            $help = $fn.GetHelpContent()
            @{
                Name           = $fn.Name
                IsTopLevel     = ($topLevel -contains $fn)
                HasCmdletBind  = ($attrs -contains 'CmdletBinding')
                HasOutputType  = ($attrs -contains 'OutputType')
                HasSynopsis    = ($help -and -not [string]::IsNullOrWhiteSpace($help.Synopsis))
                HasDescription = ($help -and -not [string]::IsNullOrWhiteSpace($help.Description))
                HasExample     = ($help -and $help.Examples -and $help.Examples.Count -gt 0)
            }
        }
    }

    # -- Which functions are actually exported -------------------------------------------------
    # Source of truth = every sub-module manifest's FunctionsToExport (no module import needed at
    # discovery time). A Public/ function whose name is in this set is "public/exported".
    $script:exportedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($mm in @(Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.psd1')) {
        $md = Import-PowerShellDataFile -Path $mm.FullName
        foreach ($fn in [string[]]$md.FunctionsToExport) { if ($fn) { [void]$script:exportedNames.Add($fn) } }
    }

    # -- File enumerations ---------------------------------------------------------------------
    $publicFiles = @(Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.ps1' |
        Where-Object { $_.FullName -match '[\\/]Public[\\/]' })
    $privateFiles = @(Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.ps1' |
        Where-Object { $_.FullName -match '[\\/]Private[\\/]' })
    $moduleSourceFiles = @(Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Include '*.ps1', '*.psm1')

    $rel = { param($p) $p.Replace($repoRoot, '').TrimStart('\', '/').Replace('\', '/') }

    # Per-EXPORTED-function cases (help + CmdletBinding + OutputType apply to the exported function
    # in each Public file, NOT to inline/nested helpers).
    $script:exportedFunctionCases = foreach ($f in $publicFiles) {
        foreach ($info in (Get-ContractFunctionInfo -Path $f.FullName)) {
            if (-not $script:exportedNames.Contains($info.Name)) { continue }
            @{
                Name          = $info.Name
                File          = (& $rel $f.FullName)
                HasCmdletBind = $info.HasCmdletBind
                HasOutputType = $info.HasOutputType
                HasSynopsis   = $info.HasSynopsis
                HasDescription= $info.HasDescription
                HasExample    = $info.HasExample
            }
        }
    }
    $script:exportedFunctionCases = @($script:exportedFunctionCases)

    # Per-Public-FILE cases (one-function-per-file rule; counts TOP-LEVEL functions).
    $script:publicFileCases = foreach ($f in @($publicFiles + $privateFiles)) {
        $infos = @(Get-ContractFunctionInfo -Path $f.FullName)
        $topNames = @($infos | Where-Object { $_.IsTopLevel } | ForEach-Object { $_.Name })
        @{
            File          = (& $rel $f.FullName)
            BaseName      = $f.BaseName
            TopLevelNames = $topNames
            TopLevelCount = $topNames.Count
        }
    }
    $script:publicFileCases = @($script:publicFileCases)

    # Per-function-NAME cases for naming rules (SEB-prefix both ways, approved verbs). Marks each
    # function as exported or private so the SEB-prefix rule can be applied in the right direction.
    $script:namingCases = @(
        foreach ($f in $publicFiles) {
            foreach ($info in (Get-ContractFunctionInfo -Path $f.FullName)) {
                @{ Name = $info.Name; File = (& $rel $f.FullName); IsExported = $script:exportedNames.Contains($info.Name) }
            }
        }
        foreach ($f in $privateFiles) {
            foreach ($info in (Get-ContractFunctionInfo -Path $f.FullName)) {
                @{ Name = $info.Name; File = (& $rel $f.FullName); IsExported = $script:exportedNames.Contains($info.Name) }
            }
        }
    )

    # Per-module-SOURCE-file cases (alias + Write-Host scans over Modules/).
    $script:moduleFileCases = foreach ($f in $moduleSourceFiles) {
        @{ Path = $f.FullName; File = (& $rel $f.FullName) }
    }
    $script:moduleFileCases = @($script:moduleFileCases)
}

BeforeAll {
    # -- Allow-lists (documented baselines of known, pre-existing exceptions) ------------------
    # Defined in BeforeAll (run-time scope) because the It bodies that consult them execute there,
    # not at discovery time. Following the build.ps1 PSScriptAnalyzer-baseline pattern: the rule is
    # GREEN now, yet any NEW violation NOT on the allow-list still fails. Shrink as code is fixed.

    # Public functions that legitimately lack [OutputType()] today (e.g. void/side-effecting
    # senders, console writers, throttled-copy starters). NEW public functions must declare
    # [OutputType()]; remove names here as each gains one. (CLAUDE.md: OutputType "where the
    # return type is known".)
    $script:allowNoOutputType = @(
        'Add-SEBMetric', 'Clear-SEBOldMetrics', 'Get-SEBIntegrityReport', 'Get-SEBNodeMetrics',
        'Invoke-SEBRemoteCommand', 'Invoke-SEBVRageRequest', 'Invoke-SEBWithShadowCopy',
        'Remove-SEBSession', 'Send-SEBBackupNotification', 'Send-SEBNotification',
        'Send-SEBRestoreNotification', 'Start-SEBBitsTransfer', 'Start-SEBLogContext',
        'Stop-SEBLogContext', 'Stop-SEBTransfer', 'Test-SEBArchiveIntegrity', 'Test-SEBConnection',
        'Test-SEBManifestIntegrity', 'Test-SEBNodeLoad', 'Wait-SEBNodeLoad',
        'Write-SEBIntegrityReport', 'Write-SEBLog', 'Write-SEBManifest'
    )

    # Private functions that currently carry the SEB prefix. CLAUDE.md says private/internal
    # functions do NOT use the SEB prefix; these pre-date the rule's enforcement. NEW private
    # functions must be un-prefixed; remove names here as each is renamed. Keyed by function name
    # (private function names are unique across the codebase by the one-function-per-file rule).
    $script:allowPrivateSebPrefix = @(
        'Get-SEBBackupType', 'Test-SEBPreFlight', 'Convert-SEBLegacyCredential',
        'ConvertFrom-SEBProtectedCredential', 'ConvertTo-SEBProtectedCredential',
        'Get-SEBSecretEntropy', 'Protect-SEBSecret', 'Set-SEBCredentialAcl',
        'Test-SEBProtectedCredentialReadBack', 'Unprotect-SEBSecret',
        'Write-SEBProtectedCredentialFile', 'Resolve-SEBChainArchivePath', 'Get-SEBPlayerCount',
        'Get-SEBFileHash', 'Test-SEBManifestSchema', 'Get-SEBTrendIndicator', 'New-SEBDiscordEmbed',
        'Test-SEBSessionAlive', 'Test-SEBSessionUsable', 'Deploy-SEBRestoredFiles',
        'Start-SEBTorchServer', 'Stop-SEBTorchServer', 'Get-SEBProjectRoot',
        'New-SEBVRageAuthHeaders', 'Test-SEBVSSService'
    )

    # Public-file paths (relative, forward-slash) that define more than one TOP-LEVEL function.
    # Test-SEBConfig.ps1 keeps three file-scope validation helpers (Test-GlobalConfig/NodeConfig/
    # InstanceConfig) alongside the exported Test-SEBConfig. NEW files must be one-function-per-file.
    $script:allowMultiFunctionFiles = @(
        'Modules/ConfigManager/Public/Test-SEBConfig.ps1'
    )

    # Write-Host sites permitted in module code, keyed "relative/path:line". CLAUDE.md forbids
    # Write-Host in modules EXCEPT the logger's own colour-coded console sink (Write-SEBLog IS the
    # console-output mechanism, gated by -NoConsole). If the line moves, update the entry.
    $script:allowWriteHost = @(
        'Modules/Logger/Public/Write-SEBLog.ps1:165'
    )

    $script:approvedVerbs = [System.Collections.Generic.HashSet[string]]::new(
        [string[]](Get-Verb | ForEach-Object Verb), [System.StringComparer]::OrdinalIgnoreCase)

    # Resolve the set of alias NAMES once. The alias rule flags any CommandAst whose command name
    # is a known alias (e.g. gci/%/?/select/where/ls/cat). Built dynamically from the live session
    # so it tracks PowerShell's own alias table rather than a hand-maintained list.
    $script:aliasNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($a in (Get-Alias)) { [void]$script:aliasNames.Add($a.Name) }

    function script:Get-CommandAstsFromFile {
        param([string]$Path)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    }
}

# -- Rule 1: comment-based help on every PUBLIC function ----------------------------------------
Describe 'Public functions carry comment-based help' {
    It '<Name> has a .SYNOPSIS (<File>)' -ForEach $script:exportedFunctionCases {
        $HasSynopsis | Should -BeTrue -Because "CLAUDE.md requires comment-based help; $Name is exported and must declare at least .SYNOPSIS"
    }
    It '<Name> has a .DESCRIPTION (<File>)' -ForEach $script:exportedFunctionCases {
        $HasDescription | Should -BeTrue -Because "$Name is exported and should document .DESCRIPTION (CLAUDE.md comment-based help)"
    }
    It '<Name> has at least one .EXAMPLE (<File>)' -ForEach $script:exportedFunctionCases {
        $HasExample | Should -BeTrue -Because "$Name is exported and should show at least one .EXAMPLE (CLAUDE.md comment-based help)"
    }
}

# -- Rule 2: [CmdletBinding()] (always) and [OutputType()] (where known) on PUBLIC functions -----
Describe 'Public functions declare [CmdletBinding()]' {
    It '<Name> has [CmdletBinding()] (<File>)' -ForEach $script:exportedFunctionCases {
        $HasCmdletBind | Should -BeTrue -Because "CLAUDE.md: use [CmdletBinding()] on all functions; $Name is exported"
    }
}

Describe 'Public functions declare [OutputType()] (allow-listed exceptions aside)' {
    It '<Name> has [OutputType()] (<File>)' -ForEach $script:exportedFunctionCases {
        if ($Name -in $script:allowNoOutputType) {
            Set-ItResult -Skipped -Because "known pre-existing exception: $Name lacks [OutputType()] (documented allow-list)"
            return
        }
        $HasOutputType | Should -BeTrue -Because "CLAUDE.md: declare [OutputType()] where the return type is known; $Name is a new/known-return public function not on the allow-list"
    }
}

# -- Rule 3: one function per file (file name == function name) ----------------------------------
Describe 'Each module .ps1 defines exactly one top-level function named for the file' {
    It '<File> defines a single top-level function matching its BaseName' -ForEach $script:publicFileCases {
        if ($File -in $script:allowMultiFunctionFiles) {
            Set-ItResult -Skipped -Because "known pre-existing exception: $File keeps file-scope helpers (documented allow-list)"
            return
        }
        $TopLevelCount | Should -Be 1 -Because "CLAUDE.md one-function-per-file: $File declares top-level function(s): $($TopLevelNames -join ', ')"
        $TopLevelNames[0] | Should -BeExactly $BaseName -Because "CLAUDE.md: the file name must match the function name ($File)"
    }
}

# -- Rule 4: SEB-prefix rule (exported MUST carry it; private must NOT) --------------------------
Describe 'SEB-prefix naming rule' {
    It 'exported <Name> matches ^[A-Z][a-z]+-SEB[A-Z] (<File>)' -ForEach @($script:namingCases | Where-Object { $_.IsExported }) {
        $Name | Should -Match '^[A-Z][a-z]+-SEB[A-Z]' -Because "CLAUDE.md: every exported function is Verb-SEBNoun ($File)"
    }
    It 'private <Name> does NOT carry the SEB prefix (<File>)' -ForEach @($script:namingCases | Where-Object { -not $_.IsExported }) {
        if ($Name -in $script:allowPrivateSebPrefix) {
            Set-ItResult -Skipped -Because "known pre-existing exception: private $Name carries the SEB prefix (documented allow-list)"
            return
        }
        $Name | Should -Not -Match '-SEB' -Because "CLAUDE.md: private/internal functions do NOT use the SEB prefix; $Name is not exported and not on the allow-list ($File)"
    }
}

# -- Rule 5: approved PowerShell verbs ----------------------------------------------------------
Describe 'All module functions use approved verbs' {
    It '<Name> uses an approved verb (<File>)' -ForEach $script:namingCases {
        $verb = ($Name -split '-', 2)[0]
        ($Name -match '-') | Should -BeTrue -Because "function names must be Verb-Noun: $Name ($File)"
        $script:approvedVerbs.Contains($verb) | Should -BeTrue -Because "CLAUDE.md: use approved PowerShell verbs (Get-Verb); '$verb' in $Name is not approved ($File)"
    }
}

# -- Rule 6: no PowerShell aliases in module code -----------------------------------------------
Describe 'Module code uses full cmdlet names (no aliases)' {
    It '<File> uses no command aliases' -ForEach $script:moduleFileCases {
        $hits = foreach ($c in (Get-CommandAstsFromFile -Path $Path)) {
            $name = $c.GetCommandName()
            if ($name -and $script:aliasNames.Contains($name)) { "L$($c.Extent.StartLineNumber): '$name'" }
        }
        $hits = @($hits)
        $hits -join "`n" | Should -BeNullOrEmpty -Because "CLAUDE.md: use full cmdlet names, not aliases, in $File`n$($hits -join "`n")"
    }
}

# -- Rule 7: no Write-Host in module code (logger console sink excepted) -------------------------
Describe 'Module code does not use Write-Host' {
    It '<File> contains no Write-Host (outside the allow-list)' -ForEach $script:moduleFileCases {
        $hits = foreach ($c in (Get-CommandAstsFromFile -Path $Path)) {
            if ($c.GetCommandName() -eq 'Write-Host') {
                $key = "$File`:$($c.Extent.StartLineNumber)"
                if ($key -notin $script:allowWriteHost) { "L$($c.Extent.StartLineNumber)" }
            }
        }
        $hits = @($hits)
        $hits -join "`n" | Should -BeNullOrEmpty -Because "CLAUDE.md: do not use Write-Host in module code (use Write-SEBLog) in $File`n$($hits -join "`n")"
    }
}
