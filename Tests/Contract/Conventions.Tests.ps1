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
#
# Two anti-false-green guards back the allow-lists themselves (see the bottom of this file):
#   * a STALE-ENTRY guard asserts every allow-list entry STILL corresponds to a real current
#     violation, so a fixed-but-still-listed name fails and forces the list to be pruned; and
#   * a NON-VACUITY sentinel asserts the data-driven discovery actually found cases (counts above
#     sane floors), so an empty Get-ChildItem/glob regression turns the build RED instead of green.

BeforeDiscovery {
    . "$PSScriptRoot/_ContractAst.ps1"   # memoized Get-ContractAst / Get-ContractFunctionInfo
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path

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
    # SCOPED TO TOP-LEVEL (file-scope) functions only -- consistent with how exports and the
    # one-function-per-file rule are evaluated. A nested helper inside a public function (e.g.
    # Resolve-SessionFromCache inside Invoke-SEBWithShadowCopy) is an implementation detail and is
    # neither exported nor subject to the public/private SEB-prefix split, so flagging or exempting
    # it by these rules would be wrong.
    $script:namingCases = @(
        foreach ($f in @($publicFiles + $privateFiles)) {
            foreach ($info in (Get-ContractFunctionInfo -Path $f.FullName)) {
                if (-not $info.IsTopLevel) { continue }
                @{ Name = $info.Name; File = (& $rel $f.FullName); IsExported = $script:exportedNames.Contains($info.Name) }
            }
        }
    )

    # Per-module-SOURCE-file cases (alias + Write-Host scans over Modules/).
    $script:moduleFileCases = foreach ($f in $moduleSourceFiles) {
        @{ Path = $f.FullName; File = (& $rel $f.FullName) }
    }
    $script:moduleFileCases = @($script:moduleFileCases)

    # Non-vacuity sentinel cases. Each carries the ACTUAL discovery-time count of one enumeration
    # plus the sane floor it must exceed. Data-driving the sentinel (vs reading a $script: scalar in
    # the It) is deliberate: a -ForEach value is captured AT DISCOVERY and surfaced to the run-time
    # It as $Count, so the assertion is tied to the exact count discovery used to expand the rules
    # above. Floors = real current counts minus a margin; raise them as the codebase grows, never
    # lower them to paper over a regression.
    $script:sentinelCases = @(
        @{ What = 'exported public functions (help/CmdletBinding/OutputType rules)'; Count = $script:exportedFunctionCases.Count; Floor = 50 }
        @{ What = 'Public/ files (one-function-per-file rule)';                       Count = $publicFiles.Count;                Floor = 50 }
        @{ What = 'Private/ files (private-SEB-prefix rule)';                         Count = $privateFiles.Count;               Floor = 25 }
        @{ What = 'module source files (alias/Write-Host scans)';                     Count = $moduleSourceFiles.Count;          Floor = 90 }
        @{ What = 'top-level naming cases (SEB-prefix/approved-verb rules)';          Count = $script:namingCases.Count;         Floor = 80 }
    )
}

BeforeAll {
    . "$PSScriptRoot/_ContractAst.ps1"   # memoized Get-CommandAstsFromFile / Get-ContractFunctionInfo
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path

    # -- Allow-lists (documented baselines of known, pre-existing exceptions) ------------------
    # Defined in BeforeAll (run-time scope) because the It bodies that consult them execute there,
    # not at discovery time. Following the build.ps1 PSScriptAnalyzer-baseline pattern: the rule is
    # GREEN now, yet any NEW violation NOT on the allow-list still fails. Shrink as code is fixed.
    # The stale-allow-list guard (bottom of file) keeps every entry honest.

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

    # Public-file paths (relative, forward-slash) that define more than one TOP-LEVEL function,
    # mapped to the EXACT, FROZEN set of top-level function names that file is allowed to define
    # (sorted). The one-function-per-file rule asserts an allow-listed file's current top-level set
    # EQUALS this frozen set -- so adding a 4th/renamed top-level function to such a file FAILS,
    # rather than being skipped. Test-SEBConfig.ps1 keeps three file-scope validation helpers
    # (Test-GlobalConfig/NodeConfig/InstanceConfig) alongside the exported Test-SEBConfig. NEW files
    # must be strictly one-function-per-file (do NOT add entries here without strong justification).
    $script:allowMultiFunctionFiles = @{
        'Modules/ConfigManager/Public/Test-SEBConfig.ps1' = @(
            'Test-GlobalConfig', 'Test-InstanceConfig', 'Test-NodeConfig', 'Test-SEBConfig'
        )
    }

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
        if ($script:allowMultiFunctionFiles.ContainsKey($File)) {
            # Allow-listed multi-function file: do NOT skip. Assert the CURRENT top-level set equals
            # the frozen, documented set -- so a NEW/renamed top-level function here fails.
            $expected = @($script:allowMultiFunctionFiles[$File] | Sort-Object)
            $actual = @($TopLevelNames | Sort-Object)
            ($actual -join ', ') | Should -Be ($expected -join ', ') -Because "CLAUDE.md one-function-per-file allow-list for $File is FROZEN to [$($expected -join ', ')]; the file now defines [$($actual -join ', ')]. Update Test-SEBConfig (split the file) or, with justification, the frozen allow-list."
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

# -- Anti-false-green guard A: non-vacuity sentinel ---------------------------------------------
# The rule Describes above are -ForEach data-driven from BeforeDiscovery enumerations. If any
# enumeration returns EMPTY (a path typo, a glob regression, a worktree layout change), Pester
# expands that Describe to ZERO Its and reports GREEN while enforcing NOTHING. These sentinel Its
# assert each discovered case count (captured at discovery, surfaced here as $Count) exceeds a sane
# floor (real current count minus a margin), so an empty/under-populated discovery is a RED build.
# Authoring-time counts: 80 exported public fns, 80 Public files, 39 Private files, 135 module
# source files, 122 top-level naming cases. Bump floors UP as the codebase grows; never down.
Describe 'Contract discovery is non-vacuous (sentinel)' {
    It 'discovered a healthy number of <What>' -ForEach $script:sentinelCases {
        $Count | Should -BeGreaterThan $Floor -Because "an empty/under-populated discovery would vacuously pass the corresponding rule(s); discovered $Count $What (floor $Floor)"
    }
}

# -- Anti-false-green guard B: stale-allow-list guard -------------------------------------------
# The four allow-lists above are append-only baselines. Without a guard they are STICKY: if a
# function's debt is later fixed (it gains [OutputType()], a private function is renamed off the
# SEB prefix, a multi-function file is split, a Write-Host is removed) but its allow-list entry is
# left behind, that stale entry would silently MASK a NEW violation should the same name/site recur.
# These guards assert every allow-list ENTRY still maps to a REAL current violation; a fixed-but-
# still-listed entry FAILS, forcing the list to be pruned. This keeps the baseline honest.
Describe 'Allow-lists contain no stale entries (guard)' {

    BeforeAll {
        . "$PSScriptRoot/_ContractAst.ps1"
        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $rel = { param($p) $p.Replace($repoRoot, '').TrimStart('\', '/').Replace('\', '/') }

        # Rebuild the exported-name set here (self-contained; do not rely on discovery-scope leakage).
        $exportedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($mm in @(Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.psd1')) {
            $md = Import-PowerShellDataFile -Path $mm.FullName
            foreach ($fn in [string[]]$md.FunctionsToExport) { if ($fn) { [void]$exportedNames.Add($fn) } }
        }

        $publicFiles = @(Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.ps1' |
            Where-Object { $_.FullName -match '[\\/]Public[\\/]' })
        $privateFiles = @(Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Filter '*.ps1' |
            Where-Object { $_.FullName -match '[\\/]Private[\\/]' })
        $moduleSourceFiles = @(Get-ChildItem -Path "$repoRoot/Modules" -Recurse -File -Include '*.ps1', '*.psm1')

        # Top-level public functions that genuinely LACK [OutputType()] right now.
        $script:noOutputTypeNow = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $publicFiles) {
            foreach ($info in (Get-ContractFunctionInfo -Path $f.FullName)) {
                if ($info.IsTopLevel -and $exportedNames.Contains($info.Name) -and -not $info.HasOutputType) {
                    [void]$script:noOutputTypeNow.Add($info.Name)
                }
            }
        }

        # Top-level PRIVATE (non-exported) functions that genuinely carry a -SEB prefix right now.
        $script:privateSebNow = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $privateFiles) {
            foreach ($info in (Get-ContractFunctionInfo -Path $f.FullName)) {
                if ($info.IsTopLevel -and -not $exportedNames.Contains($info.Name) -and $info.Name -match '-SEB') {
                    [void]$script:privateSebNow.Add($info.Name)
                }
            }
        }

        # Relative paths of Public files that genuinely define MORE than one top-level function now.
        $script:multiFnFilesNow = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($f in @($publicFiles + $privateFiles)) {
            $top = @((Get-ContractFunctionInfo -Path $f.FullName) | Where-Object { $_.IsTopLevel })
            if ($top.Count -gt 1) { [void]$script:multiFnFilesNow.Add((& $rel $f.FullName)) }
        }

        # "relative/path:line" of every Write-Host call site that genuinely exists in module code now.
        $script:writeHostSitesNow = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $moduleSourceFiles) {
            foreach ($c in (Get-CommandAstsFromFile -Path $f.FullName)) {
                if ($c.GetCommandName() -eq 'Write-Host') {
                    [void]$script:writeHostSitesNow.Add("$(& $rel $f.FullName):$($c.Extent.StartLineNumber)")
                }
            }
        }
    }

    It 'every allowNoOutputType entry is STILL a public function lacking [OutputType()]' {
        $stale = @($script:allowNoOutputType | Where-Object { -not $script:noOutputTypeNow.Contains($_) })
        $stale -join ', ' | Should -BeNullOrEmpty -Because "these now declare [OutputType()] (or are no longer exported) and must be REMOVED from allowNoOutputType: $($stale -join ', ')"
    }

    It 'every allowPrivateSebPrefix entry is STILL a private SEB-prefixed function' {
        $stale = @($script:allowPrivateSebPrefix | Where-Object { -not $script:privateSebNow.Contains($_) })
        $stale -join ', ' | Should -BeNullOrEmpty -Because "these are no longer private-and-SEB-prefixed (renamed or now exported) and must be REMOVED from allowPrivateSebPrefix: $($stale -join ', ')"
    }

    It 'every allowMultiFunctionFiles entry is STILL a multi-top-level-function file' {
        $stale = @($script:allowMultiFunctionFiles.Keys | Where-Object { -not $script:multiFnFilesNow.Contains($_) })
        $stale -join ', ' | Should -BeNullOrEmpty -Because "these no longer define more than one top-level function and must be REMOVED from allowMultiFunctionFiles: $($stale -join ', ')"
    }

    It 'every allowWriteHost entry is STILL a real Write-Host call site' {
        $stale = @($script:allowWriteHost | Where-Object { -not $script:writeHostSitesNow.Contains($_) })
        $stale -join ', ' | Should -BeNullOrEmpty -Because "these no longer point at a Write-Host call (removed or line moved) and must be REMOVED/updated in allowWriteHost: $($stale -join ', ')"
    }
}
