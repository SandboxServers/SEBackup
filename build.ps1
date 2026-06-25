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
    ratchet gate against coverage-baseline.json: the build FAILS if overall coverage drops more
    than a small tolerance below the committed baseline, so coverage can only hold or climb. CI
    passes this; local quick runs can omit it (coverage instrumentation adds wall-clock, and the
    gate only applies when coverage was actually measured). Writes coverage.xml (gitignored).

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
# Only runs when coverage was measured (-Coverage). Compares the run's overall % against the
# committed baseline in coverage-baseline.json and FAILS the build if it dropped more than a
# tolerance below baseline. The tolerance absorbs measurement jitter: a few lines hit by timing-
# or environment-dependent paths flip between runs, nudging the % by fractions of a point. The
# baseline only moves UP, and only by a deliberate human commit (see the "ratchet" hint below).
if ($Coverage) {
    Write-Host ''
    Write-Host '== Coverage ratchet =='

    # Tolerance (percentage points) below baseline that is still accepted. Small enough that a
    # real regression (a whole function left untested) trips it, large enough to ride out jitter.
    $coverageTolerance = 0.75

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
        # path segment right after Modules/). Lets us NAME which modules regressed on a drop.
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

            Write-Host ("Coverage: {0}% overall (baseline {1}%, floor {2}% with {3}pt tolerance)." -f `
                    $currentOverall, $baseOverall, $floor, $coverageTolerance)

            if ($currentOverall -lt $floor) {
                # DROP below the allowed floor -> fail and name the modules that regressed so the
                # author knows where to add tests (or which module's deletion shifted the ratio).
                Write-Host ("FAIL: coverage {0}% is below baseline {1}% (floor {2}%)." -f `
                        $currentOverall, $baseOverall, $floor)
                $regressed = @()
                if ($baseline.perModule) {
                    foreach ($name in $currentPerModule.Keys) {
                        $bm = $baseline.perModule.$name
                        if ($null -ne $bm -and $currentPerModule[$name] -lt ([double]$bm - $coverageTolerance)) {
                            $regressed += '{0} {1}% -> {2}%' -f $name, ([double]$bm), $currentPerModule[$name]
                        }
                    }
                }
                if ($regressed.Count) {
                    Write-Host '  regressed modules:'
                    $regressed | ForEach-Object { Write-Host "    $_" }
                }
                else {
                    Write-Host '  (no single module crossed the per-module tolerance; the overall ratio shifted -- e.g. new uncovered code or a covered module removed).'
                }
                $failed = $true
            }
            else {
                Write-Host 'Coverage OK vs baseline.'
                if ($currentOverall -ge ($baseOverall + $ratchetHintMargin)) {
                    # INCREASE beyond the margin: nudge -- but do NOT auto-raise. Raising the
                    # baseline is a deliberate commit so the new floor is reviewed and intentional.
                    Write-Host ("  ratchet: baseline can be raised to {0}% (currently {1}%). Update coverage-baseline.json in a commit to lock it in." -f `
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
