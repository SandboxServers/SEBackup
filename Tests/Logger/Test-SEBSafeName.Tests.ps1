#Requires -Module Pester

# Test-SEBSafeName is the single canonical guard for every name->path boundary in SEBackup
# (issue #28): node names, instance names, and lock stems are all interpolated into filesystem
# paths, so a value containing a separator, '..', a drive/UNC root, a wildcard, or an invalid
# filename character must be rejected -- while legitimate operator-chosen names (including dotted
# ones like 'PvP.Arena' and names with spaces) must be accepted. The function returns a [bool] by
# default and throws when -Throw is supplied; both styles are exercised here.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null
}

Describe 'Test-SEBSafeName' {

    Context 'accepts legitimate single-segment names' {
        It "accepts '<Name>'" -ForEach @(
            @{ Name = 'PvPArena' }
            @{ Name = 'PvP_Arena-01' }
            @{ Name = 'PvP.Arena' }          # dotted name must be allowed (a single '.' is fine)
            @{ Name = 'a.b.c' }              # multiple dots, but no '..' sequence
            @{ Name = 'My Server' }          # spaces are filename-legal and operator-chosen
            @{ Name = 'Creative01' }
            @{ Name = 'gamingpc01' }
            @{ Name = 'node-2' }
            @{ Name = '123' }
        ) {
            Test-SEBSafeName -Name $Name | Should -BeTrue -Because "'$Name' is a safe single path segment"
            # -Throw must NOT throw on a safe name, and must still return $true.
            { Test-SEBSafeName -Name $Name -Throw } | Should -Not -Throw
            Test-SEBSafeName -Name $Name -Throw | Should -BeTrue
        }
    }

    Context 'rejects traversal, separators, rooted paths, wildcards, and invalid filename chars' {
        It "rejects '<Name>' (<Why>)" -ForEach @(
            @{ Name = '..';                     Why = 'bare parent traversal' }
            @{ Name = '../x';                   Why = 'forward-slash traversal' }
            @{ Name = '..\x';                   Why = 'back-slash traversal' }
            @{ Name = 'a/b';                    Why = 'forward-slash separator' }
            @{ Name = 'a\b';                    Why = 'back-slash separator' }
            @{ Name = 'C:\x';                   Why = 'drive-rooted path' }
            @{ Name = 'C:\Windows';             Why = 'absolute path' }
            @{ Name = '\\server\share';         Why = 'UNC root' }
            @{ Name = '/etc/passwd';            Why = 'rooted forward-slash path' }
            @{ Name = '*';                      Why = 'star wildcard' }
            @{ Name = '?';                      Why = 'question wildcard' }
            @{ Name = '[x]';                    Why = 'bracket character class' }
            @{ Name = 'name*';                  Why = 'embedded star wildcard' }
            @{ Name = 'foo..bar';               Why = "embedded '..' sequence" }
            @{ Name = 'a<b';                    Why = 'invalid filename char <' }
            @{ Name = 'a>b';                    Why = 'invalid filename char >' }
            @{ Name = 'a|b';                    Why = 'invalid filename char |' }
            @{ Name = 'a:b';                    Why = 'invalid filename char : (also rooted-ish)' }
            @{ Name = "a`tb";                   Why = 'invalid control char (tab)' }
        ) {
            # Boolean style returns $false.
            Test-SEBSafeName -Name $Name | Should -BeFalse -Because "'$Name' is unsafe ($Why)"
            # -Throw style raises a terminating, descriptive error.
            { Test-SEBSafeName -Name $Name -Throw } | Should -Throw -Because "'$Name' is unsafe ($Why)"
        }
    }

    Context 'rejects null / empty / whitespace' {
        It 'rejects an empty string' {
            Test-SEBSafeName -Name '' | Should -BeFalse
            { Test-SEBSafeName -Name '' -Throw } | Should -Throw
        }

        It 'rejects a whitespace-only string' {
            Test-SEBSafeName -Name '   ' | Should -BeFalse
            { Test-SEBSafeName -Name '   ' -Throw } | Should -Throw
        }

        It 'rejects $null' {
            Test-SEBSafeName -Name $null | Should -BeFalse
            { Test-SEBSafeName -Name $null -Throw } | Should -Throw
        }
    }

    Context 'is callable from a ValidateScript context' {
        # This mirrors Get-SEBRestorePoints, which uses [ValidateScript({ Test-SEBSafeName -Name $_ -Throw })].
        It 'lets a safe value bind and rejects an unsafe value' {
            function Test-ValidateScriptUsage {
                param([ValidateScript({ Test-SEBSafeName -Name $_ -Throw })][string]$Instance)
                return $Instance
            }
            Test-ValidateScriptUsage -Instance 'PvP.Arena' | Should -Be 'PvP.Arena'
            { Test-ValidateScriptUsage -Instance '..\evil' } | Should -Throw
        }
    }
}
