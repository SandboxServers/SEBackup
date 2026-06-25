#Requires -Module Pester

# Behavioral tests for the SchedulerManager module (issue #20). Previously only the function-existence
# contract ran; this suite exercises the Task Scheduler action/trigger/principal construction, the
# S4U "run whether logged on or not" principal, the legacy-credential warning, the status mapping, and
# the update paths -- WITHOUT writing anything to the real Windows Task Scheduler.
#
# Infrastructure boundary mocked (in SchedulerManager scope): the ScheduledTasks cmdlets
#   New-ScheduledTaskTrigger / New-ScheduledTaskAction / New-ScheduledTaskPrincipal /
#   New-ScheduledTaskSettingsSet / Register-ScheduledTask / Get-ScheduledTask /
#   Get-ScheduledTaskInfo / Set-ScheduledTask / Enable-ScheduledTask / Disable-ScheduledTask /
#   Unregister-ScheduledTask, plus ConvertFrom-Toml and Get-ChildItem (the legacy-cred scan).
# Construction is asserted by capturing the arguments bound to the New-ScheduledTask* mocks.
#
# CI runs on windows-latest, so these cmdlets exist and are mockable; no real task is ever created.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # The ScheduledTasks cmdlets type their parameters as [CimInstance]/[CimInstance[]] and
    # Get-ScheduledTaskInfo's pipeline -InputObject is a MANDATORY [CimInstance]. A PSCustomObject
    # therefore can't bind (the mock body would be skipped). So our doubles are REAL client-only
    # CimInstances (which bind to every typed param) carrying the handful of properties the function
    # reads as ETS (Add-Member) members. This keeps the boundary fully mocked while letting the typed
    # binding succeed.
    # The ScheduledTasks cmdlets type their parameters as [CimInstance]/[CimInstance[]] AND the binder
    # matches the specific PSTypeName (e.g. ...#MSFT_TaskTrigger); Get-ScheduledTaskInfo's pipeline
    # -InputObject is a MANDATORY [CimInstance]#MSFT_ScheduledTask. A PSCustomObject cannot bind (the
    # mock body would be skipped). So our doubles are REAL client-only CimInstances of the CORRECT
    # MSFT class (so they bind), created in the taskscheduler namespace.
    #
    # We only Add-Member properties that are NOT real adapter members of that class (e.g. 'Kind',
    # 'Triggers', 'TaskName'); CIM-native members like 'State' are set via -Property at creation, and
    # real adapter members we don't need (principal UserId/LogonType/RunLevel) are left at their
    # defaults -- the construction itself is asserted on the arguments bound to the New-ScheduledTask*
    # mocks, not on the objects they return.
    $script:TaskNs = 'root/microsoft/windows/taskscheduler'
    function New-FakeCim {
        param([string]$Class, [hashtable]$CimProps = @{}, [hashtable]$Extra = @{})
        $ci = New-CimInstance -ClassName $Class -Namespace $script:TaskNs -ClientOnly -Property $CimProps
        foreach ($k in $Extra.Keys) { $ci | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] -Force }
        $ci
    }

    # A fabricated MSFT_ScheduledTask with controllable State + Triggers (a real CimInstance so it
    # pipes into Get-ScheduledTaskInfo). State is CIM-native; Triggers/TaskName are instance extensions.
    function New-FakeTask {
        param(
            [int]$State = 3,                 # 3 = Ready
            [string]$Interval = 'PT6H',      # ISO-8601 repetition interval
            [string]$StartBoundary = '2026-01-01T02:00:00'
        )
        New-FakeCim -Class 'MSFT_ScheduledTask' -CimProps @{ State = [uint16]$State } -Extra @{
            TaskName = 'SEBackup-Scheduled'
            Triggers = @(
                [PSCustomObject]@{
                    StartBoundary = $StartBoundary
                    Repetition    = [PSCustomObject]@{ Interval = $Interval }
                }
            )
        }
    }

    # Mocks shared by the register/update suites that build a task. Each builder returns a real
    # client-only CimInstance of the right class so it binds to Register/Set-ScheduledTask.
    function Set-SchedulerBuildMocks {
        Mock New-ScheduledTaskTrigger     -ModuleName SchedulerManager { New-FakeCim -Class 'MSFT_TaskTrigger' }
        Mock New-ScheduledTaskAction      -ModuleName SchedulerManager { New-FakeCim -Class 'MSFT_TaskAction' }
        Mock New-ScheduledTaskPrincipal   -ModuleName SchedulerManager { New-FakeCim -Class 'MSFT_TaskPrincipal' }
        Mock New-ScheduledTaskSettingsSet -ModuleName SchedulerManager { New-FakeCim -Class 'MSFT_TaskSettings' }
        Mock Register-ScheduledTask       -ModuleName SchedulerManager { New-FakeCim -Class 'MSFT_ScheduledTask' -Extra @{ TaskName = $TaskName } }
        Mock Unregister-ScheduledTask     -ModuleName SchedulerManager {}
        # No legacy .cred.xml files by default.
        Mock Get-ChildItem -ModuleName SchedulerManager { @() } -ParameterFilter { $Filter -eq '*.cred.xml' }
    }
}

Describe 'Register-SEBScheduledTask' {
    BeforeEach {
        Set-SchedulerBuildMocks
        # Fresh registration by default: no existing task.
        Mock Get-ScheduledTask -ModuleName SchedulerManager { $null }
        $script:gc = @{ schedule = @{ interval_hours = 4; start_time = '03:30' } }
    }

    It 'builds a repeating Once trigger from interval_hours/start_time' {
        Register-SEBScheduledTask -GlobalConfig $script:gc 3>$null | Out-Null
        Should -Invoke New-ScheduledTaskTrigger -ModuleName SchedulerManager -Times 1 -Exactly -ParameterFilter {
            $Once -eq $true -and $null -ne $RepetitionInterval -and $RepetitionInterval.TotalHours -eq 4
        }
    }

    It 'builds an action that runs pwsh.exe with the backup script and -All' {
        Register-SEBScheduledTask -GlobalConfig $script:gc 3>$null | Out-Null
        Should -Invoke New-ScheduledTaskAction -ModuleName SchedulerManager -Times 1 -Exactly -ParameterFilter {
            $Execute -eq 'pwsh.exe' -and
            $Argument -like '*Invoke-Backup.ps1*' -and
            $Argument -like '*-All*' -and
            $Argument -like '*-NoProfile*'
        }
    }

    It 'builds an S4U, highest-privilege, current-user principal (run whether logged on or not)' {
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Register-SEBScheduledTask -GlobalConfig $script:gc 3>$null | Out-Null
        Should -Invoke New-ScheduledTaskPrincipal -ModuleName SchedulerManager -Times 1 -Exactly -ParameterFilter {
            $LogonType -eq 'S4U' -and $RunLevel -eq 'Highest' -and $UserId -eq $me
        }
    }

    It 'registers the task with the assembled trigger/action/principal/settings' {
        Register-SEBScheduledTask -TaskName 'MyTask' -GlobalConfig $script:gc 3>$null | Out-Null
        # Each forwarded piece must be the corresponding builder's CimInstance output (asserted by
        # its specific MSFT PSTypeName) -- proving the assembled objects were the ones passed on.
        Should -Invoke Register-ScheduledTask -ModuleName SchedulerManager -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'MyTask' -and
            (@($Trigger)[0].PSTypeNames   -contains 'Microsoft.Management.Infrastructure.CimInstance#MSFT_TaskTrigger') -and
            (@($Action)[0].PSTypeNames    -contains 'Microsoft.Management.Infrastructure.CimInstance#MSFT_TaskAction') -and
            (@($Principal)[0].PSTypeNames -contains 'Microsoft.Management.Infrastructure.CimInstance#MSFT_TaskPrincipal') -and
            (@($Settings)[0].PSTypeNames  -contains 'Microsoft.Management.Infrastructure.CimInstance#MSFT_TaskSettings')
        }
    }

    It 'uses documented defaults (6h / 02:00) when the schedule keys are absent' {
        Register-SEBScheduledTask -GlobalConfig @{ schedule = @{} } 3>$null | Out-Null
        Should -Invoke New-ScheduledTaskTrigger -ModuleName SchedulerManager -Times 1 -Exactly -ParameterFilter {
            $RepetitionInterval.TotalHours -eq 6
        }
    }

    It 'throws on an invalid start_time format' {
        { Register-SEBScheduledTask -GlobalConfig @{ schedule = @{ start_time = '25:99' } } 3>$null } |
            Should -Throw -ExpectedMessage '*start_time*'
    }

    It 'throws when the [schedule] section is missing entirely' {
        { Register-SEBScheduledTask -GlobalConfig @{} 3>$null } | Should -Throw -ExpectedMessage '*schedule*'
    }

    It 'overwrites an existing task (unregister first, then register)' {
        Mock Get-ScheduledTask -ModuleName SchedulerManager { [PSCustomObject]@{ TaskName = 'SEBackup-Scheduled' } }
        Register-SEBScheduledTask -GlobalConfig $script:gc 3>$null | Out-Null
        Should -Invoke Unregister-ScheduledTask -ModuleName SchedulerManager -Times 1 -Exactly
        Should -Invoke Register-ScheduledTask   -ModuleName SchedulerManager -Times 1 -Exactly
    }

    It 'warns (and names the nodes) when legacy .cred.xml credentials are present' {
        Mock Get-ChildItem -ModuleName SchedulerManager {
            @(
                [PSCustomObject]@{ BaseName = 'node1.cred' }
                [PSCustomObject]@{ BaseName = 'node2.cred' }
            )
        } -ParameterFilter { $Filter -eq '*.cred.xml' }
        $warnings = @()
        Register-SEBScheduledTask -GlobalConfig $script:gc -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        ($warnings -join "`n") | Should -Match 'legacy'
        ($warnings -join "`n") | Should -Match 'node1'
        ($warnings -join "`n") | Should -Match 'node2'
    }

    It 'honors -WhatIf: it does NOT call Register-ScheduledTask' {
        Register-SEBScheduledTask -GlobalConfig $script:gc -WhatIf 3>$null | Out-Null
        Should -Invoke Register-ScheduledTask -ModuleName SchedulerManager -Times 0 -Exactly
    }

    It 'loads the config from global.toml when -GlobalConfig is not supplied' {
        # Cover the file-load branch without depending on the real TOML on disk.
        Mock Test-Path -ModuleName SchedulerManager { $true } -ParameterFilter { $Path -like '*global.toml' }
        Mock Get-Content -ModuleName SchedulerManager { 'stub-toml' } -ParameterFilter { $Path -like '*global.toml' }
        Mock ConvertFrom-Toml -ModuleName SchedulerManager { @{ schedule = @{ interval_hours = 8; start_time = '01:00' } } }
        Register-SEBScheduledTask 3>$null | Out-Null
        Should -Invoke ConvertFrom-Toml -ModuleName SchedulerManager -Times 1 -Exactly
        Should -Invoke New-ScheduledTaskTrigger -ModuleName SchedulerManager -Times 1 -Exactly -ParameterFilter { $RepetitionInterval.TotalHours -eq 8 }
    }
}

Describe 'Unregister-SEBScheduledTask' {
    It 'warns and does nothing when the task does not exist' {
        Mock Get-ScheduledTask -ModuleName SchedulerManager { $null }
        Mock Unregister-ScheduledTask -ModuleName SchedulerManager {}
        Unregister-SEBScheduledTask -TaskName 'Missing' -Force 3>$null
        Should -Invoke Unregister-ScheduledTask -ModuleName SchedulerManager -Times 0 -Exactly
    }

    It 'removes an existing task when -Force is supplied (no confirmation prompt)' {
        Mock Get-ScheduledTask -ModuleName SchedulerManager { [PSCustomObject]@{ TaskName = 'SEBackup-Scheduled' } }
        Mock Unregister-ScheduledTask -ModuleName SchedulerManager {}
        Mock Read-Host -ModuleName SchedulerManager { throw 'must not prompt when -Force is given' }
        Unregister-SEBScheduledTask -Force 3>$null
        Should -Invoke Unregister-ScheduledTask -ModuleName SchedulerManager -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'SEBackup-Scheduled' }
        Should -Invoke Read-Host -ModuleName SchedulerManager -Times 0 -Exactly
    }

    It 'honors -WhatIf: it does not remove the task' {
        Mock Get-ScheduledTask -ModuleName SchedulerManager { [PSCustomObject]@{ TaskName = 'SEBackup-Scheduled' } }
        Mock Unregister-ScheduledTask -ModuleName SchedulerManager {}
        Unregister-SEBScheduledTask -Force -WhatIf 3>$null
        Should -Invoke Unregister-ScheduledTask -ModuleName SchedulerManager -Times 0 -Exactly
    }
}

Describe 'Get-SEBScheduleStatus' {
    It 'returns Exists=$false with null fields when the task is not found' {
        Mock Get-ScheduledTask -ModuleName SchedulerManager { $null }
        $s = Get-SEBScheduleStatus -TaskName 'Nope' 3>$null
        $s.Exists | Should -BeFalse
        $s.TaskName | Should -Be 'Nope'
        $s.State | Should -BeNullOrEmpty
        $s.NextRunTime | Should -BeNullOrEmpty
        $s.TriggerInterval | Should -BeNullOrEmpty
    }

    It 'maps an existing Ready task with parsed run times and trigger interval' {
        Mock Get-ScheduledTask -ModuleName SchedulerManager { New-FakeTask -State 3 -Interval 'PT6H' }
        Mock Get-ScheduledTaskInfo -ModuleName SchedulerManager {
            [PSCustomObject]@{
                NextRunTime    = [datetime]'2026-02-28T02:00:00'
                LastRunTime    = [datetime]'2026-02-27T20:00:00'
                LastTaskResult = 0
            }
        }
        $s = Get-SEBScheduleStatus 3>$null
        $s.Exists | Should -BeTrue
        $s.State | Should -Be 'Ready'
        $s.LastResult | Should -Be 0
        $s.NextRunTime | Should -Be ([datetime]'2026-02-28T02:00:00')
        $s.TriggerInterval | Should -Be ([System.Xml.XmlConvert]::ToTimeSpan('PT6H'))
    }

    It 'maps state code 4 to Running and 1 to Disabled' {
        Mock Get-ScheduledTaskInfo -ModuleName SchedulerManager { [PSCustomObject]@{ NextRunTime = $null; LastRunTime = $null; LastTaskResult = $null } }
        Mock Get-ScheduledTask -ModuleName SchedulerManager { New-FakeTask -State 4 }
        (Get-SEBScheduleStatus 3>$null).State | Should -Be 'Running'
        Mock Get-ScheduledTask -ModuleName SchedulerManager { New-FakeTask -State 1 }
        (Get-SEBScheduleStatus 3>$null).State | Should -Be 'Disabled'
    }
}

Describe 'Update-SEBSchedule' {
    BeforeEach {
        # A real CimInstance trigger so it binds to Set-ScheduledTask -Trigger [CimInstance[]].
        Mock New-ScheduledTaskTrigger -ModuleName SchedulerManager { New-FakeCim -Class 'MSFT_TaskTrigger' }
        Mock Set-ScheduledTask     -ModuleName SchedulerManager { New-FakeCim -Class 'MSFT_ScheduledTask' }
        Mock Enable-ScheduledTask  -ModuleName SchedulerManager {}
        Mock Disable-ScheduledTask -ModuleName SchedulerManager {}
        # The function fetches the task at the start (must exist) and again at the end (return value).
        Mock Get-ScheduledTask -ModuleName SchedulerManager { New-FakeTask }
    }

    It 'throws when the task does not exist' {
        Mock Get-ScheduledTask -ModuleName SchedulerManager { $null }
        { Update-SEBSchedule -IntervalHours 4 3>$null } | Should -Throw -ExpectedMessage '*does not exist*'
    }

    It 'updates the trigger when -IntervalHours is given' {
        Update-SEBSchedule -IntervalHours 8 3>$null | Out-Null
        Should -Invoke New-ScheduledTaskTrigger -ModuleName SchedulerManager -Times 1 -Exactly -ParameterFilter { $RepetitionInterval.TotalHours -eq 8 }
        Should -Invoke Set-ScheduledTask -ModuleName SchedulerManager -Times 1 -Exactly
    }

    It 'rejects an invalid -StartTime via the parameter pattern (no Set-ScheduledTask call)' {
        # ValidatePattern '^\d{2}:\d{2}$' rejects '3:30' at binding time.
        { Update-SEBSchedule -StartTime '3:30' 3>$null } | Should -Throw
        Should -Invoke Set-ScheduledTask -ModuleName SchedulerManager -Times 0 -Exactly
    }

    It 'enables the task when -Enabled $true' {
        Update-SEBSchedule -Enabled $true 3>$null | Out-Null
        Should -Invoke Enable-ScheduledTask -ModuleName SchedulerManager -Times 1 -Exactly
        Should -Invoke Disable-ScheduledTask -ModuleName SchedulerManager -Times 0 -Exactly
    }

    It 'disables the task when -Enabled $false' {
        Update-SEBSchedule -Enabled $false 3>$null | Out-Null
        Should -Invoke Disable-ScheduledTask -ModuleName SchedulerManager -Times 1 -Exactly
        Should -Invoke Enable-ScheduledTask -ModuleName SchedulerManager -Times 0 -Exactly
    }

    It 'makes no changes (no trigger rebuild, no enable/disable) when no optional params are given' {
        Update-SEBSchedule 3>$null | Out-Null
        Should -Invoke New-ScheduledTaskTrigger -ModuleName SchedulerManager -Times 0 -Exactly
        Should -Invoke Set-ScheduledTask -ModuleName SchedulerManager -Times 0 -Exactly
        Should -Invoke Enable-ScheduledTask -ModuleName SchedulerManager -Times 0 -Exactly
        Should -Invoke Disable-ScheduledTask -ModuleName SchedulerManager -Times 0 -Exactly
    }

    It 'returns the (re-fetched) task object' {
        $r = Update-SEBSchedule -IntervalHours 4 3>$null
        $r | Should -Not -BeNullOrEmpty
        $r.TaskName | Should -Be 'SEBackup-Scheduled'
    }
}
