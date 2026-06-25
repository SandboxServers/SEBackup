#Requires -Module Pester

# Issue #28 final consolidation: every PUBLIC function that takes -InstanceName and interpolates it
# into a filesystem path must guard it with the shared Test-SEBSafeName validator. These tests cover
# the six functions migrated last:
#   Get-SEBBackupHistory, Get-SEBLatestManifest, Get-SEBManifestChain  (read boundaries)
#   Get-SEBIntegrityReport, Write-SEBIntegrityReport, Add-SEBMetric    (read + write boundaries)
# plus Get-SEBRestorePoints, whose guard moved from a binding-time [ValidateScript] into the body.
#
# Each function keeps its OWN error contract on a rejected name, so the assertions differ by function:
#   - throw  : Get-SEBManifestChain, Add-SEBMetric, Get-SEBRestorePoints
#   - $null  : Get-SEBLatestManifest, Get-SEBIntegrityReport
#   - @()    : Get-SEBBackupHistory
#   - (none) : Write-SEBIntegrityReport (Write-Error, returns nothing -- assert NO file is written)
#
# Two invariants are pinned for every function:
#   1. a traversal value ('..\evil') is rejected at the InstanceName->path boundary, and
#   2. a legitimate DOTTED name ('PvP.Arena') is ACCEPTED (no over-rejection) -- proven by the call
#      reaching its normal "nothing here" result against a fresh empty BackupRoot rather than failing
#      the guard.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    function New-EmptyRoot {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sebgrd_" + [guid]::NewGuid().ToString('n'))
        New-Item -Path $root -ItemType Directory -Force | Out-Null
        return $root
    }

    $script:traversal = '..\evil'
    $script:dotted = 'PvP.Arena'   # filename-legal: a single '.' must be allowed, no '..' sequence
}

Describe 'InstanceName->path guards reject traversal but accept dotted names (issue #28)' {

    Context 'Get-SEBBackupHistory (contract: @() + Write-Error on reject)' {
        It 'rejects a traversal InstanceName (empty result, error emitted)' {
            $root = New-EmptyRoot
            try {
                $points = Get-SEBBackupHistory -InstanceName $traversal -BackupRoot $root -ErrorAction SilentlyContinue
                @($points) | Should -HaveCount 0
                # The guard must fire BEFORE any path use; an error is written per its contract.
                Get-SEBBackupHistory -InstanceName $traversal -BackupRoot $root -ErrorVariable ev -ErrorAction SilentlyContinue | Out-Null
                "$ev" | Should -Match 'Invalid InstanceName'
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'ACCEPTS a dotted InstanceName (reaches the empty-root result, no guard error)' {
            $root = New-EmptyRoot
            try {
                $points = Get-SEBBackupHistory -InstanceName $dotted -BackupRoot $root -ErrorVariable ev -ErrorAction SilentlyContinue
                @($points) | Should -HaveCount 0
                "$ev" | Should -Not -Match 'Invalid InstanceName'
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'Get-SEBLatestManifest (contract: $null + Write-Error on reject)' {
        It 'rejects a traversal InstanceName (returns $null, error emitted)' {
            $root = New-EmptyRoot
            try {
                $r = Get-SEBLatestManifest -InstanceName $traversal -BackupRoot $root -ErrorVariable ev -ErrorAction SilentlyContinue
                $r | Should -BeNullOrEmpty
                "$ev" | Should -Match 'Invalid InstanceName'
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'ACCEPTS a dotted InstanceName (returns $null for empty root, no guard error)' {
            $root = New-EmptyRoot
            try {
                $r = Get-SEBLatestManifest -InstanceName $dotted -BackupRoot $root -ErrorVariable ev -ErrorAction SilentlyContinue
                $r | Should -BeNullOrEmpty
                "$ev" | Should -Not -Match 'Invalid InstanceName'
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'Get-SEBManifestChain (contract: throw on reject)' {
        It 'throws on a traversal InstanceName' {
            { Get-SEBManifestChain -InstanceName $traversal -TargetManifest 'x.json' -BackupRoot 'C:\Backups' } |
                Should -Throw -ExpectedMessage '*Invalid name*'
        }

        It 'ACCEPTS a dotted InstanceName (passes the guard; fails later on the missing manifest dir, not the name)' {
            $root = New-EmptyRoot
            try {
                # The guard must NOT reject 'PvP.Arena'. With no manifests dir the function throws a
                # DIFFERENT error ("Manifest directory not found"), proving the name cleared the guard.
                { Get-SEBManifestChain -InstanceName $dotted -TargetManifest 'x.json' -BackupRoot $root } |
                    Should -Throw -ExpectedMessage '*Manifest directory not found*'
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'Get-SEBIntegrityReport (contract: $null + Write-Error on reject)' {
        It 'rejects a traversal InstanceName (returns $null, error emitted)' {
            $root = New-EmptyRoot
            try {
                $r = Get-SEBIntegrityReport -InstanceName $traversal -BackupRoot $root -ErrorVariable ev -ErrorAction SilentlyContinue
                $r | Should -BeNullOrEmpty
                "$ev" | Should -Match 'Invalid InstanceName'
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'ACCEPTS a dotted InstanceName (returns $null for missing report, no guard error)' {
            $root = New-EmptyRoot
            try {
                $r = Get-SEBIntegrityReport -InstanceName $dotted -BackupRoot $root -ErrorVariable ev -ErrorAction SilentlyContinue
                $r | Should -BeNullOrEmpty
                "$ev" | Should -Not -Match 'Invalid InstanceName'
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'Write-SEBIntegrityReport (contract: Write-Error, writes nothing -- a WRITE boundary)' {
        It 'rejects a traversal InstanceName and creates NO file/dir outside the root' {
            $root = New-EmptyRoot
            try {
                Write-SEBIntegrityReport -InstanceName $traversal -BackupRoot $root -Report @{ a = 1 } -ErrorVariable ev -ErrorAction SilentlyContinue
                "$ev" | Should -Match 'Invalid InstanceName'
                # The guard must fire before New-Item: the root stays empty (no traversal dir created).
                @(Get-ChildItem -LiteralPath $root -Force) | Should -HaveCount 0
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'ACCEPTS a dotted InstanceName and writes the report under that instance dir' {
            $root = New-EmptyRoot
            try {
                Write-SEBIntegrityReport -InstanceName $dotted -BackupRoot $root -Report @{ ok = $true } -ErrorVariable ev -ErrorAction SilentlyContinue
                "$ev" | Should -Not -Match 'Invalid InstanceName'
                Test-Path -LiteralPath (Join-Path (Join-Path $root $dotted) 'integrity_report.json') -PathType Leaf | Should -BeTrue
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'Add-SEBMetric (contract: throw on reject -- a WRITE boundary)' {
        It 'throws on a traversal InstanceName and creates NO metrics file outside the root' {
            $root = New-EmptyRoot
            try {
                { Add-SEBMetric -InstanceName $traversal -MetricData @{ success = $true } -BackupRoot $root } |
                    Should -Throw -ExpectedMessage '*Invalid name*'
                # Guard fires before the metrics dir is created/written.
                Test-Path -LiteralPath (Join-Path $root 'Data') | Should -BeFalse
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'ACCEPTS a dotted InstanceName and writes its metrics file' {
            $root = New-EmptyRoot
            try {
                { Add-SEBMetric -InstanceName $dotted -MetricData @{ type = 'Full'; success = $true } -BackupRoot $root } |
                    Should -Not -Throw
                Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $root 'Data') 'metrics') "$dotted`_metrics.json") -PathType Leaf | Should -BeTrue
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'Get-SEBRestorePoints (guard moved from [ValidateScript] to the body; contract: throw on reject)' {
        It 'throws on a traversal InstanceName' {
            { Get-SEBRestorePoints -InstanceName $traversal -BackupRoot 'C:\Backups' } |
                Should -Throw -ExpectedMessage '*Invalid name*'
        }

        It 'ACCEPTS a dotted InstanceName (reaches the empty-root result, no throw)' {
            $root = New-EmptyRoot
            try {
                { Get-SEBRestorePoints -InstanceName $dotted -BackupRoot $root } | Should -Not -Throw
                @(Get-SEBRestorePoints -InstanceName $dotted -BackupRoot $root) | Should -HaveCount 0
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
