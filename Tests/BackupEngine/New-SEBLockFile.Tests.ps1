#Requires -Module Pester

# The per-instance lock coordinates backups and restores of the same instance. Acquisition
# must be mutually exclusive (a fresh lock blocks a second acquire), releasable, and able to
# break a stale lock. These functions are shared (exported) infrastructure used by both
# Invoke-SEBBackup and Invoke-SEBRestore.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null
    $script:lockDir = Join-Path $repoRoot 'Data' | Join-Path -ChildPath 'lockfiles'
    $script:inst = "PesterLockTest_$([guid]::NewGuid().ToString('n'))"
    $script:lockPath = Join-Path $script:lockDir "$($script:inst).lock"
}

Describe 'SEB lock file' {
    AfterEach {
        if (Test-Path -LiteralPath $script:lockPath) { Remove-Item -LiteralPath $script:lockPath -Force -ErrorAction SilentlyContinue }
    }

    It 'acquires a fresh lock and writes the lock file' {
        $r = New-SEBLockFile -InstanceName $script:inst
        $r.Acquired | Should -BeTrue
        Test-Path -LiteralPath $script:lockPath | Should -BeTrue
    }

    It 'refuses a second acquire while a fresh lock is held' {
        (New-SEBLockFile -InstanceName $script:inst).Acquired | Should -BeTrue
        $second = New-SEBLockFile -InstanceName $script:inst
        $second.Acquired | Should -BeFalse
    }

    It 'releases the lock so it can be re-acquired' {
        (New-SEBLockFile -InstanceName $script:inst).Acquired | Should -BeTrue
        (Remove-SEBLockFile -InstanceName $script:inst) | Should -BeTrue
        Test-Path -LiteralPath $script:lockPath | Should -BeFalse
        (New-SEBLockFile -InstanceName $script:inst).Acquired | Should -BeTrue
    }

    It 'breaks a stale lock older than the threshold' {
        if (-not (Test-Path $script:lockDir)) { New-Item -Path $script:lockDir -ItemType Directory -Force | Out-Null }
        @{
            pid       = 999999
            hostname  = 'old-host'
            timestamp = ([datetime]::UtcNow.AddHours(-9)).ToString('o')
            instance  = $script:inst
        } | ConvertTo-Json | Set-Content -LiteralPath $script:lockPath

        $r = New-SEBLockFile -InstanceName $script:inst -StaleThresholdHours 4
        $r.Acquired | Should -BeTrue
        $r.StaleLockBroken | Should -BeTrue
    }
}
