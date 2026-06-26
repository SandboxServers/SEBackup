#Requires -Version 7.0
<#
.SYNOPSIS
    SEBackup CI build: PSScriptAnalyzer (Error-gated) + the full Pester suite.

.DESCRIPTION
    The single entry point used by both GitHub Actions (.github/workflows/ci.yml) and
    local developers, so "what CI runs" and "what I can run" are identical.

    Two gates:
      1. PSScriptAnalyzer at Error AND ParseError severity across the repo (ParseError catches
         files that don't even parse -- which are NOT reported under Error severity). A small,
         documented baseline of already-known findings is accepted; ANY new finding fails the
         build. Warnings (e.g. Write-Host in install/interactive scripts, allowed by CLAUDE.md)
         are intentionally not collected here.
      2. Pester 5 over Tests/, excluding tags that need real infrastructure (VSS / WinRM /
         Torch). Those E2E/Integration tests run on the local 3-instance Torch harness, not
         on GitHub-hosted runners. The gate fails on any non-Passed run result (including
         discovery/parse failures, which report FailedCount=0) and on an empty run.

.PARAMETER InstallDeps
    Install/update the required modules (PSToml, Pester, PSScriptAnalyzer) from PSGallery
    before running. CI passes this; locally, omit it if you already have them.

.PARAMETER ExcludeTag
    Pester tags to exclude (default: E2E, Integration -- the infra-dependent suites).

.PARAMETER Coverage
    Measure JaCoCo code coverage over Modules/ during the (same) Pester run and enforce the
    ratchet gate against coverage-baseline.json. The gate FAILS the build if ANY of these trip,
    so coverage can only hold or climb and no single module can quietly lose its tests:
      * OVERALL drops more than the tolerance below the committed baseline overall;
      * ANY PER-MODULE hit-ratio drops more than the tolerance below its own committed baseline
        (a module losing its tests fails even if the overall ratio stays within tolerance);
      * the measured overall (or the committed baseline overall) falls below an ABSOLUTE hard
        floor that does not depend on the baseline -- so editing the baseline down to a tiny
        number can't silently disarm the gate.
    Alias: -CodeCoverage. CI passes this; local quick runs can omit it (coverage instrumentation
    adds wall-clock, and the gate only applies when coverage was actually measured). Writes
    coverage.xml (gitignored).

.EXAMPLE
    ./build.ps1 -InstallDeps -Coverage   # what CI runs
.EXAMPLE
    ./build.ps1                          # local quick run (deps present, no coverage gate)
.EXAMPLE
    ./build.ps1 -Coverage                # local run WITH the coverage ratchet gate
.OUTPUTS
    Exit code 0 on success, 1 on any analyzer-error/test/coverage-gate failure.
#>
[CmdletBinding()]
param(
    [switch]$InstallDeps,
    [string[]]$ExcludeTag = @('E2E', 'Integration'),
    # Alias 'CodeCoverage' so the issue-#17 wording (-CodeCoverage) works too. Same switch.
    [Alias('CodeCoverage')]
    [switch]$Coverage
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
$failed = $false

# Pinned toolchain versions — single source of truth for BOTH install and import, so the runner
# never drifts between what it installs and what it loads. Bump these deliberately.
$PinnedModules = [ordered]@{
    PSToml           = '0.5.0'
    Pester           = '5.7.1'
    PSScriptAnalyzer = '1.25.0'
}

if ($InstallDeps) {
    Write-Host '== Installing dependencies =='
    # Trust PSGallery only for the duration of this run, then restore the prior policy so we
    # don't permanently lower trust on a developer machine.
    $priorPolicy = (Get-PSRepository -Name PSGallery).InstallationPolicy
    try {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        # Install the EXACT pinned versions (no "latest at run time" — supply-chain hardening).
        foreach ($name in $PinnedModules.Keys) {
            $version = $PinnedModules[$name]
            $have = Get-Module -ListAvailable -Name $name |
                Where-Object { $_.Version -eq [version]$version }
            if ($have) { continue }
            Write-Host "Installing $name $version"
            # -SkipPublisherCheck is scoped to Pester ONLY: Windows ships an in-box Pester signed
            # by Microsoft, while the PSGallery build is signed by the Pester team, so a plain
            # install trips the publisher-mismatch guard. PSToml/PSScriptAnalyzer verify normally.
            $extra = if ($name -eq 'Pester') { @{ SkipPublisherCheck = $true } } else { @{} }
            Install-Module -Name $name -RequiredVersion $version `
                -Repository PSGallery -Scope CurrentUser -Force -AllowClobber @extra
        }
    }
    finally {
        if ($priorPolicy -and $priorPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy $priorPolicy
        }
    }
}

# Import the EXACT pinned versions (not -MinimumVersion) so a runner's preinstalled copy can't
# shadow the pinned one -- keeps "what ran" identical to "what was installed".
Import-Module PSScriptAnalyzer -RequiredVersion $PinnedModules.PSScriptAnalyzer -Force
Import-Module Pester -RequiredVersion $PinnedModules.Pester -Force

# ── Gate 1: PSScriptAnalyzer (Error + ParseError) ────────────────────────────
Write-Host ''
Write-Host '== PSScriptAnalyzer (Error + ParseError) =='

# Documented baseline of accepted Error findings, keyed "RuleName|relative/path|line". Keying by
# path AND line (not just the file leaf) keeps the "any new Error fails" guarantee even for a
# second occurrence of the same rule inside a baseline file. Any Error NOT listed here fails the
# build. If a baseline finding's line shifts, update the entry. Shrink this list as findings are fixed.
$pssaBaseline = @(
    # Setup-Node.ps1 converts a plaintext password to a SecureString to create the node
    # service account (New-LocalUser) over PSRemoting. Hardening tracked under issue #30.
    'PSAvoidUsingConvertToSecureStringWithPlainText|Scripts/Setup-Node.ps1|229'
)

# Include ParseError: a file that doesn't parse emits ParseError findings (NOT Error), so an
# unparseable .ps1 would otherwise sail through an Error-only gate. ParseErrors are never baselined.
$pssa = @(Invoke-ScriptAnalyzer -Path $RepoRoot -Recurse -Severity Error, ParseError -ErrorAction SilentlyContinue)
$newErrors = @($pssa | Where-Object {
        $rel = [System.IO.Path]::GetRelativePath($RepoRoot, $_.ScriptPath).Replace('\', '/')
        "$($_.RuleName)|$rel|$($_.Line)" -notin $pssaBaseline
    })

if ($pssa.Count) {
    $pssa | Format-Table RuleName, @{ l = 'File'; e = { Split-Path $_.ScriptPath -Leaf } }, Line, Message -AutoSize |
        Out-String -Width 200 | Write-Host
}
if ($newErrors.Count) {
    Write-Host "FAIL: $($newErrors.Count) new PSScriptAnalyzer Error/ParseError finding(s) not in baseline."
    $failed = $true
}
else {
    Write-Host "PSScriptAnalyzer OK: $($pssa.Count) baseline-accepted, 0 new errors."
}

# ── Gate 2: Pester ───────────────────────────────────────────────────────────
Write-Host ''
Write-Host "== Pester (excluding tags: $($ExcludeTag -join ', ')) =="

$conf = New-PesterConfiguration
$conf.Run.Path = Join-Path $RepoRoot 'Tests'
$conf.Run.PassThru = $true
# NOTE: no test currently carries an 'E2E'/'Integration' tag, so this filter excludes nothing
# today -- it is forward-looking. Any test needing VSS/WinRM/Torch/real-DPAPI MUST be tagged
# 'E2E' or 'Integration' (see .github/CONTRIBUTING.md) or it will run here on windows-latest.
$conf.Filter.ExcludeTag = $ExcludeTag
$conf.Output.Verbosity = 'Detailed'
$conf.TestResult.Enabled = $true
$conf.TestResult.OutputFormat = 'NUnitXml'
$conf.TestResult.OutputPath = Join-Path $RepoRoot 'testResults.xml'

# Coverage is folded into THIS Pester run (one suite execution, not two) so CI time stays
# reasonable. It is opt-in via -Coverage because breakpoint instrumentation adds measurable
# wall-clock; the ratchet gate below only runs when coverage was actually measured.
$coverageXml = Join-Path $RepoRoot 'coverage.xml'
if ($Coverage) {
    $conf.CodeCoverage.Enabled = $true
    $conf.CodeCoverage.Path = Join-Path $RepoRoot 'Modules'  # production code only, not Tests/
    $conf.CodeCoverage.OutputFormat = 'JaCoCo'               # build-server-friendly report
    $conf.CodeCoverage.OutputPath = $coverageXml             # gitignored; uploaded as a CI artifact
    # RecursePaths/SingleHitBreakpoints/ExcludeTests all default true (verified on Pester 5.7.1):
    # recurse the module tree, drop each breakpoint once hit (faster), and don't count test files.
}

$result = Invoke-Pester -Configuration $conf
$ran = $result.PassedCount + $result.FailedCount
if ($result.Result -ne 'Passed') {
    # Gate on the overall run result, not just FailedCount: a discovery/parse-time failure in a
    # .Tests.ps1 reports Result='Failed' with FailedCount=0, which a FailedCount-only check misses.
    Write-Host "FAIL: Pester run result = $($result.Result) ($($result.FailedCount) failed)."
    $result.Containers | Where-Object Result -ne 'Passed' | ForEach-Object {
        Write-Host "  container not passed: $($_.Item) [$($_.Result)]"
    }
    $failed = $true
}
elseif ($ran -lt 1) {
    # Green-while-testing-nothing is the worst false pass: a wrong Run.Path or an over-broad
    # ExcludeTag would otherwise exit 0 having executed no tests.
    Write-Host 'FAIL: no tests executed (check Run.Path / ExcludeTag).'
    $failed = $true
}
else {
    Write-Host "Pester OK: $($result.PassedCount) passed, $($result.SkippedCount) skipped."
}

# ── Gate 3: Coverage ratchet ──────────────────────────────────────────────────
# Only runs when coverage was measured (-Coverage). The gate is deliberately un-gameable: it
# enforces THREE independent things against coverage-baseline.json so coverage can only hold or
# climb and no single module can quietly shed its tests behind another's gains:
#   1. OVERALL ratchet: measured overall must stay within $coverageTolerance of baseline.overall.
#   2. PER-MODULE ratchet: EVERY module in baseline.perModule must stay within $coverageTolerance
#      of its OWN baseline -- enforced every run, not merely reported on an overall failure. A
#      module losing its tests fails the build even when the overall ratio rides within tolerance
#      (one module's gain can no longer mask another's collapse).
#   3. ABSOLUTE hard floor ($coverageAbsoluteFloor): a baseline-independent minimum applied to BOTH
#      the measured overall AND the committed baseline.overall. This catches a gutted suite and a
#      tampered baseline (e.g. someone editing overall down to a tiny number to disarm the gate) --
#      the floor is well below the real ~57% so it never false-trips, but a baseline below it is
#      rejected as implausible rather than trusted.
# The tolerance absorbs measurement jitter: a few lines hit by timing-/environment-dependent paths
# flip between runs, nudging the % by fractions of a point. The baseline only moves UP, and only by
# a deliberate human commit (see the "ratchet" hint below and .github/CONTRIBUTING.md).
if ($Coverage) {
    Write-Host ''
    Write-Host '== Coverage ratchet =='

    # Tolerance (percentage points) below baseline still accepted, for BOTH the overall and each
    # per-module floor. Measured run-to-run jitter is ~0.02pt, so 0.3pt is ~15x the noise -- wide
    # enough to ride out that jitter, tight enough that real erosion (a function/test removed) trips
    # it promptly. Named constant: change it here, in one place, for both gates.
    $coverageTolerance = 0.30

    # Absolute, BASELINE-INDEPENDENT hard floor (percentage points). Documented constant set well
    # below the real measured overall (~57.31%) so it never false-trips, yet high enough to catch a
    # gutted suite or a baseline that was edited down to defeat the ratchet. Applied to the measured
    # overall AND to baseline.overall (an implausibly low baseline is rejected, not trusted).
    $coverageAbsoluteFloor = 50.0

    # How far above baseline before we suggest raising it. Avoids nagging on every fractional gain.
    $ratchetHintMargin = 1.0

    $cc = $result.CodeCoverage
    if (-not $cc) {
        # CodeCoverage was requested but the run produced no coverage object -- treat as a hard
        # failure rather than a silent pass (a green build that measured nothing is the trap).
        Write-Host 'FAIL: -Coverage was set but no coverage data was produced.'
        $failed = $true
    }
    else {
        $currentOverall = [math]::Round($cc.CoveragePercent, 2)

        # Per-module % from command-level hit/miss data, grouped by the module folder name (the
        # path segment right after Modules/). This is BOTH the per-module gate input and how we
        # name regressors. Stored as a hashtable for O(1) presence checks against the baseline.
        $cmds = @(
            @($cc.CommandsExecuted | ForEach-Object { [pscustomobject]@{ File = $_.File; Hit = $true } }) +
            @($cc.CommandsMissed   | ForEach-Object { [pscustomobject]@{ File = $_.File; Hit = $false } })
        )
        $currentPerModule = [ordered]@{}
        $cmds | Group-Object {
            if ($_.File -match '[\\/]Modules[\\/]([^\\/]+)[\\/]') { $Matches[1] } else { 'OTHER' }
        } | Sort-Object Name | ForEach-Object {
            $total = $_.Count
            $hit = @($_.Group | Where-Object Hit).Count
            $currentPerModule[$_.Name] = if ($total) { [math]::Round(100.0 * $hit / $total, 2) } else { 0.0 }
        }

        # Load the committed ratchet baseline.
        $baselinePath = Join-Path $RepoRoot 'coverage-baseline.json'
        if (-not (Test-Path -LiteralPath $baselinePath)) {
            Write-Host "FAIL: coverage baseline not found at $baselinePath (run with -Coverage and commit the file)."
            $failed = $true
        }
        else {
            $baseline = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
            $baseOverall = [double]$baseline.overall
            $floor = [math]::Round($baseOverall - $coverageTolerance, 2)

            Write-Host ("Coverage: {0}% overall (baseline {1}%, floor {2}% with {3}pt tolerance; absolute floor {4}%)." -f `
                    $currentOverall, $baseOverall, $floor, $coverageTolerance, $coverageAbsoluteFloor)

            # ---- Baseline sanity (tamper guard) -------------------------------------------------
            # A baseline overall below the absolute floor cannot be real for this suite (~57%); it
            # is almost certainly a baseline edited down to disarm the ratchet. Reject it outright
            # so a gutted baseline fails LOUDLY instead of silently lowering the floor to nothing.
            if ($baseOverall -lt $coverageAbsoluteFloor) {
                Write-Host ("FAIL: baseline overall {0}% is below the absolute floor {1}% -- implausible for this suite; the baseline looks gutted or tampered. Restore coverage-baseline.json." -f `
                        $baseOverall, $coverageAbsoluteFloor)
                $failed = $true
            }

            # ---- Absolute floor on the MEASURED overall (baseline-independent) -------------------
            # Independent of the baseline so that even a tampered/lowered baseline cannot let a
            # genuinely collapsed suite pass. The real overall sits ~7pt above this.
            if ($currentOverall -lt $coverageAbsoluteFloor) {
                Write-Host ("FAIL: coverage {0}% is below the ABSOLUTE floor {1}% (baseline-independent hard minimum). The suite appears gutted." -f `
                        $currentOverall, $coverageAbsoluteFloor)
                $failed = $true
            }

            # ---- Overall ratchet (vs committed baseline) ----------------------------------------
            $overallRegressed = $currentOverall -lt $floor
            if ($overallRegressed) {
                Write-Host ("FAIL: overall coverage {0}% is below baseline {1}% (floor {2}%, {3}pt tolerance)." -f `
                        $currentOverall, $baseOverall, $floor, $coverageTolerance)
                $failed = $true
            }

            # ---- Per-module ratchet (ALWAYS enforced, not just on an overall drop) ---------------
            # For EVERY module recorded in the baseline, fail if its current hit-ratio fell more
            # than the tolerance below its own baseline. Running this unconditionally is the whole
            # point: it catches a single module shedding tests even while the overall holds.
            $perModuleRegressed = @()
            $perModuleOk = @()
            $newModules = @()           # present on disk now but absent from the baseline
            $missingModules = @()       # in the baseline but no longer produced any coverage

            if (-not $baseline.perModule) {
                # No per-module map at all -> cannot enforce floor #2. Treat as a baseline that must
                # be regenerated rather than silently skipping half the gate.
                Write-Host 'FAIL: coverage baseline has no perModule map; cannot enforce per-module floors. Regenerate coverage-baseline.json (see .github/CONTRIBUTING.md).'
                $failed = $true
            }
            else {
                # Baseline-side member names (ConvertFrom-Json gives a PSCustomObject; enumerate its
                # NoteProperty names) so we can detect baseline entries with no current coverage.
                $baselineModuleNames = @($baseline.perModule.PSObject.Properties.Name)

                # Enforce each baseline module's own floor; guard against a baseline module that no
                # longer exists on disk (produced no commands this run) instead of comparing to nothing.
                foreach ($name in $baselineModuleNames) {
                    $bm = [double]$baseline.perModule.$name
                    if (-not $currentPerModule.Contains($name)) {
                        $missingModules += '{0} (baseline {1}%)' -f $name, $bm
                        continue
                    }
                    $cur = [double]$currentPerModule[$name]
                    $mFloor = [math]::Round($bm - $coverageTolerance, 2)
                    if ($cur -lt $mFloor) {
                        $perModuleRegressed += '{0} {1}% -> {2}% (floor {3}%)' -f $name, $bm, $cur, $mFloor
                    }
                    else {
                        $perModuleOk += '{0} {1}%' -f $name, $cur
                    }
                }

                # A module present now but ABSENT from the baseline is a new module that needs its
                # own baseline entry -- don't null-deref it, and don't let it sneak in ungated. Warn
                # loudly so its floor gets committed; the overall+absolute gates still cover the run.
                foreach ($name in $currentPerModule.Keys) {
                    if ($name -notin $baselineModuleNames) {
                        $newModules += '{0} {1}%' -f $name, ([double]$currentPerModule[$name])
                    }
                }

                if ($perModuleRegressed.Count) {
                    Write-Host '  FAIL: per-module coverage regressed below baseline:'
                    $perModuleRegressed | ForEach-Object { Write-Host "    $_" }
                    $failed = $true
                }
                if ($missingModules.Count) {
                    # A baseline module with no coverage this run: either it was deleted (update the
                    # baseline) or its tests stopped running (a real regression). Fail so it's noticed.
                    Write-Host '  FAIL: baseline modules produced no coverage this run (deleted, or their tests stopped running):'
                    $missingModules | ForEach-Object { Write-Host "    $_" }
                    Write-Host '    If a module was intentionally removed, drop its entry from coverage-baseline.json perModule.'
                    $failed = $true
                }
                if ($newModules.Count) {
                    Write-Host '  WARN: new module(s) not yet in the baseline perModule map -- add an entry to lock in their floor:'
                    $newModules | ForEach-Object { Write-Host "    $_" }
                }
            }

            # ---- Summary / ratchet hint ---------------------------------------------------------
            if (-not $overallRegressed -and -not $perModuleRegressed.Count -and `
                    -not $missingModules.Count -and $currentOverall -ge $coverageAbsoluteFloor -and `
                    $baseOverall -ge $coverageAbsoluteFloor) {
                Write-Host ("Coverage OK vs baseline: overall {0}% (floor {1}%) and all {2} baseline module(s) within tolerance." -f `
                        $currentOverall, $floor, @($perModuleOk).Count)
                if ($currentOverall -ge ($baseOverall + $ratchetHintMargin)) {
                    # INCREASE beyond the margin: nudge -- but do NOT auto-raise. Raising the baseline
                    # is a deliberate commit so the new floor (overall AND perModule) is reviewed.
                    Write-Host ("  ratchet: baseline can be raised to {0}% (currently {1}%). Update coverage-baseline.json -- BOTH overall and the relevant perModule entries -- in a commit to lock it in (see .github/CONTRIBUTING.md)." -f `
                            $currentOverall, $baseOverall)
                }
            }
        }
    }
}

# ── Result ───────────────────────────────────────────────────────────────────
Write-Host ''
if ($failed) {
    Write-Host 'BUILD FAILED'
    exit 1
}
Write-Host 'BUILD OK'
exit 0
