#Requires -Module Pester

# One credential-passthrough test builds a PSCredential from a known plaintext password (the only way
# to construct a SecureString from a literal in-test). No production code uses this pattern; suppress
# the analyzer rule for this fixture file only so the Error-gated build stays clean.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Test fixture credential; the underlying transfer is mocked so the secret is inert.')]
param()

# Behavioral tests for Copy-SEBThrottled (issue #20). The existing NetworkThrottle suite only unit-
# tested the private ConvertTo-RobocopyIpg; this exercises the public copy dispatcher's
# STRATEGY SELECTION and result shape without moving real bytes over a real network:
#
#   Strategy 1 (BITS)      : -UseBITS + BITS available -> delegates to Start-SEBBitsTransfer (Low prio).
#   Strategy 2 (Robocopy)  : robocopy present -> /IPG throttling, explicit ms wins over derived Mbps,
#                            and the no-throttle robocopy path omits /IPG.
#   Strategy 3 (Copy-Item) : neither BITS nor robocopy -> warns and copies unthrottled.
#
# Seams mocked in NetworkThrottle scope: Test-BITSAvailable, Start-SEBBitsTransfer, the external
# robocopy executable (Pester CAN mock it; the mock sets $LASTEXITCODE), Get-Command (to hide
# robocopy for the fallback case), and Copy-Item. Real temp files/dirs are used only so the source
# size probe and directory-vs-leaf detection behave naturally.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # A real temp source DIRECTORY (with a file for the size calc) + a real destination directory.
    # A directory source keeps robocopy on its directory path and skips the leaf post-verify/move
    # block, so no real file ever has to land for the mocked-robocopy assertions.
    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) ("SEBThrottle_" + [guid]::NewGuid().ToString('n'))
    $script:srcDir = Join-Path $script:work 'src'
    $script:dstDir = Join-Path $script:work 'dst'
    New-Item -ItemType Directory -Path $script:srcDir -Force | Out-Null
    New-Item -ItemType Directory -Path $script:dstDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $script:srcDir 'payload.bin') -Value ('x' * 4096) -NoNewline

    # A real temp source FILE for BITS/Copy-Item leaf tests.
    $script:srcFile = Join-Path $script:work 'archive.7z'
    Set-Content -LiteralPath $script:srcFile -Value ('y' * 2048) -NoNewline
}

AfterAll {
    if (Test-Path -LiteralPath $script:work) { Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Copy-SEBThrottled :: Strategy 1 (BITS)' {
    BeforeEach {
        Mock Test-BITSAvailable -ModuleName NetworkThrottle { $true }
        Mock Start-SEBBitsTransfer -ModuleName NetworkThrottle {}
    }

    It 'uses BITS (Priority Low) when -UseBITS is set and BITS is available' {
        $r = Copy-SEBThrottled -Source $script:srcFile -Destination $script:dstDir -UseBITS
        $r.Method | Should -Be 'BITS'
        Should -Invoke Start-SEBBitsTransfer -ModuleName NetworkThrottle -Times 1 -Exactly -ParameterFilter {
            $Source -eq $script:srcFile -and $Priority -eq 'Low'
        }
    }

    It 'passes a -Credential through to the BITS transfer' {
        $sec = ConvertTo-SecureString 'p' -AsPlainText -Force
        $cred = [System.Management.Automation.PSCredential]::new('u', $sec)
        Copy-SEBThrottled -Source $script:srcFile -Destination $script:dstDir -UseBITS -Credential $cred | Out-Null
        Should -Invoke Start-SEBBitsTransfer -ModuleName NetworkThrottle -Times 1 -Exactly -ParameterFilter {
            $null -ne $Credential -and $Credential.UserName -eq 'u'
        }
    }

    It 'reports the real source size and a populated result object' {
        $r = Copy-SEBThrottled -Source $script:srcFile -Destination $script:dstDir -UseBITS
        $r.SizeBytes | Should -Be 2048
        $r.Source | Should -Be $script:srcFile
        $r.Destination | Should -Be $script:dstDir
        $r.PSObject.Properties.Name | Should -Contain 'AverageMbps'
        $r.PSObject.Properties.Name | Should -Contain 'DurationSeconds'
    }

    It 'falls through to another strategy when -UseBITS is set but BITS is unavailable' {
        Mock Test-BITSAvailable -ModuleName NetworkThrottle { $false }
        Mock Start-SEBBitsTransfer -ModuleName NetworkThrottle { throw 'BITS must not be used when unavailable' }
        Mock robocopy -ModuleName NetworkThrottle { $global:LASTEXITCODE = 0; '' }
        $r = Copy-SEBThrottled -Source $script:srcDir -Destination $script:dstDir -UseBITS
        $r.Method | Should -Not -Be 'BITS'
        Should -Invoke Start-SEBBitsTransfer -ModuleName NetworkThrottle -Times 0 -Exactly
    }
}

Describe 'Copy-SEBThrottled :: Strategy 2 (Robocopy /IPG throttling)' {
    BeforeEach {
        # Not using BITS in these tests; robocopy is the path. Mock the exe so nothing copies for real.
        Mock Test-BITSAvailable -ModuleName NetworkThrottle { $false }
        $script:roboArgs = $null
        Mock robocopy -ModuleName NetworkThrottle {
            $script:roboArgs = $args
            $global:LASTEXITCODE = 0
            ''
        }
    }

    It 'derives the /IPG gap from MaxBandwidthMbps (10 Mbps -> /IPG:52)' {
        $r = Copy-SEBThrottled -Source $script:srcDir -Destination $script:dstDir -MaxBandwidthMbps 10
        $r.Method | Should -Be 'Robocopy'
        # The first two positional args ARE the copy itself; without pinning them the /IPG / /E checks
        # could pass while robocopy copied the wrong source to the wrong destination.
        $script:roboArgs[0] | Should -Be $script:srcDir
        $script:roboArgs[1] | Should -Be $script:dstDir
        ($script:roboArgs -join ' ') | Should -Match '/IPG:52'
        ($script:roboArgs -join ' ') | Should -Match '/E'   # recursive directory copy
    }

    It 'prefers an explicit RobocopyIpgMs over the value derived from MaxBandwidthMbps' {
        Copy-SEBThrottled -Source $script:srcDir -Destination $script:dstDir -MaxBandwidthMbps 10 -RobocopyIpgMs 200 | Out-Null
        ($script:roboArgs -join ' ') | Should -Match '/IPG:200'
        ($script:roboArgs -join ' ') | Should -Not -Match '/IPG:52'
    }

    It 'omits /IPG entirely when no throttle is configured (robocopy still used for reliability)' {
        $r = Copy-SEBThrottled -Source $script:srcDir -Destination $script:dstDir
        $r.Method | Should -Be 'Robocopy'
        # Still the real copy: source/destination must be present and correct on the no-throttle branch.
        $script:roboArgs[0] | Should -Be $script:srcDir
        $script:roboArgs[1] | Should -Be $script:dstDir
        ($script:roboArgs -join ' ') | Should -Not -Match '/IPG:'
    }

    It 'throws when robocopy reports a fatal exit code (>= 8)' {
        Mock robocopy -ModuleName NetworkThrottle { $global:LASTEXITCODE = 8; 'ERROR 8 (0x00000008) copy failed' }
        { Copy-SEBThrottled -Source $script:srcDir -Destination $script:dstDir -MaxBandwidthMbps 10 2>$null } |
            Should -Throw -ExpectedMessage '*Robocopy failed*'
    }

    It 'treats robocopy exit codes 0-7 as success (e.g. 1 = files copied)' {
        Mock robocopy -ModuleName NetworkThrottle { $global:LASTEXITCODE = 1; '' }
        { Copy-SEBThrottled -Source $script:srcDir -Destination $script:dstDir -MaxBandwidthMbps 10 } | Should -Not -Throw
    }

    It 'for a single-file source, robocopy gets the (srcDir, destDir, filename) triplet -- not a file as arg2' {
        # Robocopy's 2nd arg must be a DIRECTORY; a leaf source is split into srcDir + filename so the
        # file is selected by pattern. Pin all three positionals. The mock "lands" the file robocopy
        # would have produced (<destDir>\<sourceName>) so the function's post-copy verify passes
        # naturally without a real network copy.
        $script:roboArgs = $null
        Mock robocopy -ModuleName NetworkThrottle {
            $script:roboArgs = $args
            Copy-Item -LiteralPath (Join-Path $args[0] $args[2]) -Destination (Join-Path $args[1] $args[2]) -Force
            $global:LASTEXITCODE = 0
            ''
        }
        $expectedSrcDir = [System.IO.Path]::GetDirectoryName($script:srcFile)
        $expectedFile = [System.IO.Path]::GetFileName($script:srcFile)
        $r = Copy-SEBThrottled -Source $script:srcFile -Destination $script:dstDir -MaxBandwidthMbps 10
        $r.Method | Should -Be 'Robocopy'
        $script:roboArgs[0] | Should -Be $expectedSrcDir          # source DIRECTORY
        $script:roboArgs[1] | Should -Be $script:dstDir           # destination DIRECTORY
        $script:roboArgs[2] | Should -Be $expectedFile            # filename pattern (arg2 is NOT a path)
        ($script:roboArgs -join ' ') | Should -Match '/IPG:52'
    }

    It 'silently ignores -Credential on the robocopy path (robocopy cannot accept a PSCredential)' {
        # HONESTY GUARD: robocopy is a native exe invoked as `& robocopy @args`; the function never
        # references $Credential on either robocopy branch. So a -Credential is DROPPED with no warning
        # -- assert exactly that (no false impression the credential is honored): the copy still runs,
        # no warning is emitted, and the credential never appears anywhere in the robocopy arg vector.
        $script:roboArgs = $null
        Mock robocopy -ModuleName NetworkThrottle { $script:roboArgs = $args; $global:LASTEXITCODE = 0; '' }
        $sec = ConvertTo-SecureString 'p' -AsPlainText -Force
        $cred = [System.Management.Automation.PSCredential]::new('robo-user', $sec)
        $warnings = @()
        $r = Copy-SEBThrottled -Source $script:srcDir -Destination $script:dstDir -MaxBandwidthMbps 10 `
            -Credential $cred -WarningVariable warnings -WarningAction SilentlyContinue
        $r.Method | Should -Be 'Robocopy'
        $warnings | Should -BeNullOrEmpty                                  # not warned: silently ignored
        # Pester's -Match is case-insensitive; the credential (username or the literal '/credential'
        # switch robocopy has no concept of) must appear nowhere in the arg vector.
        ($script:roboArgs -join ' ') | Should -Not -Match 'robo-user'     # credential never forwarded
        ($script:roboArgs -join ' ') | Should -Not -Match 'credential'
    }
}

Describe 'Copy-SEBThrottled :: Strategy 3 (Copy-Item fallback, no throttling)' {
    BeforeEach {
        Mock Test-BITSAvailable -ModuleName NetworkThrottle { $false }
        # Hide robocopy so the dispatcher reaches the Copy-Item fallback.
        Mock Get-Command -ModuleName NetworkThrottle { $null } -ParameterFilter { $Name -eq 'robocopy' }
        Mock Copy-Item -ModuleName NetworkThrottle {}
    }

    It 'falls back to Copy-Item and reports Method=CopyItem' {
        $r = Copy-SEBThrottled -Source $script:srcFile -Destination $script:dstDir -WarningAction SilentlyContinue
        $r.Method | Should -Be 'CopyItem'
        Should -Invoke Copy-Item -ModuleName NetworkThrottle -Times 1 -Exactly
    }

    It 'warns that bandwidth limits could not be enforced on the fallback path' {
        $warnings = @()
        Copy-SEBThrottled -Source $script:srcFile -Destination $script:dstDir -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        ($warnings -join "`n") | Should -Match 'no bandwidth throttling'
    }

    It 'adds -Recurse for a directory source on the fallback path' {
        Copy-SEBThrottled -Source $script:srcDir -Destination $script:dstDir -WarningAction SilentlyContinue | Out-Null
        Should -Invoke Copy-Item -ModuleName NetworkThrottle -Times 1 -Exactly -ParameterFilter { $Recurse -eq $true }
    }

    It 'does NOT add -Recurse for a single-file source on the fallback path' {
        Copy-SEBThrottled -Source $script:srcFile -Destination $script:dstDir -WarningAction SilentlyContinue | Out-Null
        Should -Invoke Copy-Item -ModuleName NetworkThrottle -Times 1 -Exactly -ParameterFilter { -not $Recurse }
    }

    It 'FORWARDS -Credential to Copy-Item (unlike robocopy, this path can honor it for some providers)' {
        # Counterpart to the robocopy "silently ignored" guard: the Copy-Item branch DOES add
        # $copyParams['Credential'], so assert the real credential is forwarded (not dropped). This
        # pins the contrast so neither path's credential behavior can silently regress unnoticed.
        $sec = ConvertTo-SecureString 'p' -AsPlainText -Force
        $cred = [System.Management.Automation.PSCredential]::new('copy-user', $sec)
        Copy-SEBThrottled -Source $script:srcFile -Destination $script:dstDir -Credential $cred -WarningAction SilentlyContinue | Out-Null
        Should -Invoke Copy-Item -ModuleName NetworkThrottle -Times 1 -Exactly -ParameterFilter {
            $null -ne $Credential -and $Credential.UserName -eq 'copy-user'
        }
    }
}
