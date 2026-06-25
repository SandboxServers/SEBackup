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

.EXAMPLE
    ./build.ps1 -InstallDeps      # what CI runs
.EXAMPLE
    ./build.ps1                   # local, deps already present
.OUTPUTS
    Exit code 0 on success, 1 on any analyzer-error/test failure.
#>
[CmdletBinding()]
param(
    [switch]$InstallDeps,
    [string[]]$ExcludeTag = @('E2E', 'Integration')
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
$failed = $false

if ($InstallDeps) {
    Write-Host '== Installing dependencies =='
    # Trust PSGallery only for the duration of this run, then restore the prior policy so we
    # don't permanently lower trust on a developer machine.
    $priorPolicy = (Get-PSRepository -Name PSGallery).InstallationPolicy
    try {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        # Pin EXACT versions for a reproducible, supply-chain-resistant toolchain (no "latest at
        # run time"). Bump these deliberately.
        $deps = @(
            @{ Name = 'PSToml';           RequiredVersion = '0.5.0' }
            @{ Name = 'Pester';           RequiredVersion = '5.7.1' }
            @{ Name = 'PSScriptAnalyzer'; RequiredVersion = '1.25.0' }
        )
        foreach ($d in $deps) {
            $have = Get-Module -ListAvailable -Name $d.Name |
                Where-Object { $_.Version -eq [version]$d.RequiredVersion }
            if ($have) { continue }
            Write-Host "Installing $($d.Name) $($d.RequiredVersion)"
            # -SkipPublisherCheck is scoped to Pester ONLY: Windows ships an in-box Pester signed
            # by Microsoft, while the PSGallery build is signed by the Pester team, so a plain
            # install trips the publisher-mismatch guard. PSToml/PSScriptAnalyzer verify normally.
            $extra = if ($d.Name -eq 'Pester') { @{ SkipPublisherCheck = $true } } else { @{} }
            Install-Module -Name $d.Name -RequiredVersion $d.RequiredVersion `
                -Repository PSGallery -Scope CurrentUser -Force -AllowClobber @extra
        }
    }
    finally {
        if ($priorPolicy -and $priorPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy $priorPolicy
        }
    }
}

Import-Module PSScriptAnalyzer -MinimumVersion 1.22.0 -Force
Import-Module Pester -MinimumVersion 5.5.0 -Force

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
    'PSAvoidUsingConvertToSecureStringWithPlainText|Scripts/Setup-Node.ps1|224'
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
    Write-Host "FAIL: $($newErrors.Count) new PSScriptAnalyzer Error finding(s) not in baseline."
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

# ── Result ───────────────────────────────────────────────────────────────────
Write-Host ''
if ($failed) {
    Write-Host 'BUILD FAILED'
    exit 1
}
Write-Host 'BUILD OK'
exit 0
