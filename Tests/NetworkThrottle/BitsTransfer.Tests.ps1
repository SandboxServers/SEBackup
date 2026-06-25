#Requires -Module Pester

# Two credential-passthrough tests build a PSCredential from a known plaintext password (the only way
# to construct a SecureString from a literal in-test). No production code uses this pattern; suppress
# the analyzer rule for this fixture file only so the Error-gated build stays clean.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Test fixture credential; Start-BitsTransfer is mocked so the secret is inert.')]
param()

# Behavioral tests for the BITS-facing NetworkThrottle public functions (issue #20):
# Start-SEBBitsTransfer / Get-SEBTransferStatus / Stop-SEBTransfer. No real BITS job is ever created.
#
# Seams mocked in NetworkThrottle scope: Test-BITSAvailable, Import-Module (the function imports
# BitsTransfer at run time), and the BitsTransfer cmdlets Start-BitsTransfer / Get-BitsTransfer /
# Remove-BitsTransfer. A fake BITS job object stands in for the real Management.BitsJob.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # Stop-SEBTransfer passes the job to Remove-BitsTransfer -BitsJob, whose parameter is the strict
    # type [Management.BitsJob[]]; a PSCustomObject would not bind (its mock would be skipped). So the
    # double is a real (uninitialized) BitsJob -- which has no public ctor -- with the handful of
    # members the functions read shadowed via Add-Member. It binds to -BitsJob AND reads back our
    # values; Get-BitsTransfer (mocked) just hands this object back, so no real BITS state is touched.
    function New-FakeBitsJob {
        param(
            [guid]$JobId = [guid]'11111111-2222-3333-4444-555555555555',
            [string]$JobState = 'Transferred',
            [long]$BytesTransferred = 1048576,
            [long]$BytesTotal = 10485760
        )
        $j = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
            [Microsoft.BackgroundIntelligentTransfer.Management.BitsJob])
        $j | Add-Member -NotePropertyName JobId            -NotePropertyValue $JobId -Force
        $j | Add-Member -NotePropertyName JobState         -NotePropertyValue $JobState -Force
        $j | Add-Member -NotePropertyName BytesTransferred -NotePropertyValue $BytesTransferred -Force
        $j | Add-Member -NotePropertyName BytesTotal       -NotePropertyValue $BytesTotal -Force
        $j
    }
}

Describe 'Start-SEBBitsTransfer' {
    BeforeEach {
        Mock Import-Module -ModuleName NetworkThrottle {} -ParameterFilter { $Name -eq 'BitsTransfer' }
    }

    It 'throws a clear error when BITS is unavailable (no transfer attempted)' {
        Mock Test-BITSAvailable -ModuleName NetworkThrottle { $false }
        Mock Start-BitsTransfer -ModuleName NetworkThrottle { throw 'must not start a transfer when BITS is unavailable' }
        { Start-SEBBitsTransfer -Source 'C:\a.7z' -Destination '\\nas\a.7z' } |
            Should -Throw -ExpectedMessage '*BITS*not available*'
        Should -Invoke Start-BitsTransfer -ModuleName NetworkThrottle -Times 0 -Exactly
    }

    It 'starts a synchronous transfer with the default Low priority' {
        Mock Test-BITSAvailable -ModuleName NetworkThrottle { $true }
        Mock Start-BitsTransfer -ModuleName NetworkThrottle {}
        Start-SEBBitsTransfer -Source 'C:\a.7z' -Destination '\\nas\a.7z'
        Should -Invoke Start-BitsTransfer -ModuleName NetworkThrottle -Times 1 -Exactly -ParameterFilter {
            $Source -eq 'C:\a.7z' -and $Destination -eq '\\nas\a.7z' -and $Priority -eq 'Low' -and -not $Asynchronous
        }
    }

    It 'returns the BITS job object when -Asynchronous is specified' {
        Mock Test-BITSAvailable -ModuleName NetworkThrottle { $true }
        Mock Start-BitsTransfer -ModuleName NetworkThrottle { New-FakeBitsJob }
        $job = Start-SEBBitsTransfer -Source 'C:\a.7z' -Destination '\\nas\a.7z' -Asynchronous
        $job | Should -Not -BeNullOrEmpty
        $job.JobId | Should -Be ([guid]'11111111-2222-3333-4444-555555555555')
        Should -Invoke Start-BitsTransfer -ModuleName NetworkThrottle -Times 1 -Exactly -ParameterFilter { $Asynchronous -eq $true }
    }

    It 'honors a non-default Priority and passes a Credential through' {
        Mock Test-BITSAvailable -ModuleName NetworkThrottle { $true }
        Mock Start-BitsTransfer -ModuleName NetworkThrottle {}
        $sec = ConvertTo-SecureString 'p' -AsPlainText -Force
        $cred = [System.Management.Automation.PSCredential]::new('u', $sec)
        Start-SEBBitsTransfer -Source 'C:\a.7z' -Destination '\\nas\a.7z' -Priority Normal -Credential $cred
        Should -Invoke Start-BitsTransfer -ModuleName NetworkThrottle -Times 1 -Exactly -ParameterFilter {
            $Priority -eq 'Normal' -and $null -ne $Credential -and $Credential.UserName -eq 'u'
        }
    }

    It 'rethrows when the underlying BITS transfer fails' {
        Mock Test-BITSAvailable -ModuleName NetworkThrottle { $true }
        Mock Start-BitsTransfer -ModuleName NetworkThrottle { throw 'network path not found' }
        { Start-SEBBitsTransfer -Source 'C:\a.7z' -Destination '\\nas\a.7z' 2>$null } | Should -Throw
    }
}

Describe 'Get-SEBTransferStatus' {
    BeforeEach {
        Mock Import-Module -ModuleName NetworkThrottle {} -ParameterFilter { $Name -eq 'BitsTransfer' }
    }

    It 'computes PercentComplete from bytes transferred/total and returns the documented shape' {
        Mock Get-BitsTransfer -ModuleName NetworkThrottle { New-FakeBitsJob -BytesTransferred 1048576 -BytesTotal 10485760 -JobState 'Transferring' }
        $s = Get-SEBTransferStatus -JobId '11111111-2222-3333-4444-555555555555'
        $s.State | Should -Be 'Transferring'
        $s.BytesTransferred | Should -Be 1048576
        $s.BytesTotal | Should -Be 10485760
        $s.PercentComplete | Should -Be 10.0
        $s.PSObject.Properties.Name | Should -Contain 'JobId'
    }

    It 'reports 0% when BytesTotal is 0 (avoids divide-by-zero)' {
        Mock Get-BitsTransfer -ModuleName NetworkThrottle { New-FakeBitsJob -BytesTransferred 0 -BytesTotal 0 -JobState 'Connecting' }
        (Get-SEBTransferStatus -JobId '99999999-0000-0000-0000-000000000000').PercentComplete | Should -Be 0.0
    }

    It 'accepts a BITS job OBJECT (resolves via its .JobId) as well as a string id' {
        Mock Get-BitsTransfer -ModuleName NetworkThrottle {
            # -JobId is [guid[]]; normalize to the single id for the assertion.
            $script:capturedJobId = [string](@($JobId)[0])
            New-FakeBitsJob
        }
        $job = New-FakeBitsJob
        Get-SEBTransferStatus -JobId $job | Out-Null
        # When handed an object, the function passes its .JobId (a guid) to Get-BitsTransfer.
        $script:capturedJobId | Should -Be '11111111-2222-3333-4444-555555555555'
    }

    It 'returns $null (does not throw) when the job cannot be found' {
        Mock Get-BitsTransfer -ModuleName NetworkThrottle { throw 'No BITS jobs matched' }
        $result = 'sentinel'
        # The function reports the failure as a NON-terminating error and returns $null. Pass
        # -ErrorAction SilentlyContinue so the contract holds even when the caller's preference is
        # 'Stop' (otherwise the function's own Write-Error would terminate under a Stop caller).
        { $script:gs = Get-SEBTransferStatus -JobId '00000000-1111-2222-3333-444444444444' -ErrorAction SilentlyContinue } | Should -Not -Throw
        $script:gs | Should -BeNullOrEmpty
    }
}

Describe 'Stop-SEBTransfer' {
    BeforeEach {
        Mock Import-Module -ModuleName NetworkThrottle {} -ParameterFilter { $Name -eq 'BitsTransfer' }
    }

    It 'removes (cancels) the BITS job when it exists' {
        Mock Get-BitsTransfer -ModuleName NetworkThrottle { New-FakeBitsJob -JobState 'Transferring' }
        Mock Remove-BitsTransfer -ModuleName NetworkThrottle {}
        Stop-SEBTransfer -JobId '11111111-2222-3333-4444-555555555555'
        Should -Invoke Remove-BitsTransfer -ModuleName NetworkThrottle -Times 1 -Exactly
    }

    It 'resolves a string job id when querying the job' {
        Mock Remove-BitsTransfer -ModuleName NetworkThrottle {}
        Mock Get-BitsTransfer -ModuleName NetworkThrottle {
            $script:stopQueryId = [string](@($JobId)[0])
            New-FakeBitsJob
        }
        Stop-SEBTransfer -JobId 'deadbeef-0000-0000-0000-000000000000'
        $script:stopQueryId | Should -Be 'deadbeef-0000-0000-0000-000000000000'
    }

    It 'warns and does nothing when the job is not found (no Remove call, no throw)' {
        Mock Get-BitsTransfer -ModuleName NetworkThrottle { $null }
        Mock Remove-BitsTransfer -ModuleName NetworkThrottle { throw 'must not remove a non-existent job' }
        # Capture the warning stream directly (3>&1) -- robust across the module boundary.
        $out = $null
        { $script:out = Stop-SEBTransfer -JobId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' 3>&1 } | Should -Not -Throw
        Should -Invoke Remove-BitsTransfer -ModuleName NetworkThrottle -Times 0 -Exactly
        (@($script:out) -join "`n") | Should -Match 'not found'
    }

    It 'surfaces an error (does not throw) if removing the job fails' {
        Mock Get-BitsTransfer -ModuleName NetworkThrottle { New-FakeBitsJob }
        Mock Remove-BitsTransfer -ModuleName NetworkThrottle { throw 'access denied' }
        # Reported as a non-terminating error; -ErrorAction SilentlyContinue keeps it non-fatal even
        # under a 'Stop' caller, matching the "never blocks the pipeline" contract.
        { Stop-SEBTransfer -JobId '11111111-2222-3333-4444-555555555555' -ErrorAction SilentlyContinue } | Should -Not -Throw
    }
}
