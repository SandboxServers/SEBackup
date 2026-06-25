#Requires -Version 7.0
<#
.SYNOPSIS
    SEBackup CI build: PSScriptAnalyzer (Error-gated) + the full Pester suite.

.DESCRIPTION
    The single entry point used by both GitHub Actions (.github/workflows/ci.yml) and
    local developers, so "what CI runs" and "what I can run" are identical.

    Two gates:
      1. PSScriptAnalyzer at Error severity across the repo. A small, documented baseline
         of already-known Error findings is accepted; ANY new Error fails the build.
         (Warnings -- e.g. Write-Host in install/interactive scripts, allowed by CLAUDE.md --
         are reported for awareness but never gate.)
      2. Pester 5 over Tests/, excluding tags that need real infrastructure (VSS / WinRM /
         Torch). Those E2E/Integration tests run on the local 3-instance Torch harness, not
         on GitHub-hosted runners.

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
        $deps = @(
            @{ Name = 'PSToml';           MinimumVersion = '0.4.0' }
            @{ Name = 'Pester';           MinimumVersion = '5.5.0' }
            @{ Name = 'PSScriptAnalyzer'; MinimumVersion = '1.22.0' }
        )
        foreach ($d in $deps) {
            $have = Get-Module -ListAvailable -Name $d.Name |
                Where-Object { $_.Version -ge [version]$d.MinimumVersion }
            if ($have) { continue }
            Write-Host "Installing $($d.Name) >= $($d.MinimumVersion)"
            # -SkipPublisherCheck is needed ONLY for Pester: Windows ships an in-box Pester signed
            # by Microsoft, while the PSGallery build is signed by the Pester team, so a plain
            # install trips the publisher-mismatch guard. The other modules don't need it.
            $extra = if ($d.Name -eq 'Pester') { @{ SkipPublisherCheck = $true } } else { @{} }
            Install-Module @d @extra -Force -Scope CurrentUser -AllowClobber
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

# ── Gate 1: PSScriptAnalyzer (Error severity) ────────────────────────────────
Write-Host ''
Write-Host '== PSScriptAnalyzer (Error severity) =='

# Documented baseline of accepted Error findings, keyed "RuleName|relative/path|line". Keying by
# path AND line (not just the file leaf) keeps the "any new Error fails" guarantee even for a
# second occurrence of the same rule inside a baseline file. Any Error NOT listed here fails the
# build. If a baseline finding's line shifts, update the entry. Shrink this list as findings are fixed.
$pssaBaseline = @(
    # Setup-Node.ps1 converts a plaintext password to a SecureString to create the node
    # service account (New-LocalUser) over PSRemoting. Hardening tracked under issue #30.
    'PSAvoidUsingConvertToSecureStringWithPlainText|Scripts/Setup-Node.ps1|224'
)

$pssa = @(Invoke-ScriptAnalyzer -Path $RepoRoot -Recurse -Severity Error -ErrorAction SilentlyContinue)
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
$conf.Filter.ExcludeTag = $ExcludeTag
$conf.Output.Verbosity = 'Detailed'
$conf.TestResult.Enabled = $true
$conf.TestResult.OutputFormat = 'NUnitXml'
$conf.TestResult.OutputPath = Join-Path $RepoRoot 'testResults.xml'

$result = Invoke-Pester -Configuration $conf
if ($result.FailedCount -gt 0) {
    Write-Host "FAIL: $($result.FailedCount) test(s) failed."
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
