#Requires -Module Pester

# Behavioral tests for the NotificationManager module (issue #20). Previously only the
# function-existence contract ran; this suite exercises the Discord webhook payload construction,
# level/type gating, the backup/restore summary builders, and -- CRITICALLY (per CLAUDE.md) -- that
# a transport failure NEVER throws or blocks the calling backup/restore pipeline.
#
# Infrastructure boundary mocked: the transport is Invoke-WebRequest (the module posts the JSON embed
# to the Discord webhook). All HTTP is mocked in NotificationManager scope; no network is touched.
# The 429 rate-limit path is exercised with a fake HttpResponseException-shaped exception plus a
# mocked Start-Sleep, so the retry/backoff runs without any real waiting or real HTTP.
#
# Mocks use -ModuleName NotificationManager because the functions run in that nested module scope
# when imported via the root SEBackup.psd1. New-SEBDiscordEmbed (private) is reached via InModuleScope.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # A minimal stand-in for the PS7 HttpResponseException shape the 429 handler inspects:
    #   $_.Exception.Response.StatusCode   (int-castable)
    #   $_.Exception.Response.Headers.TryGetValues('Retry-After', [ref]$out)
    class FakeRespHeaders {
        [object]$RetryAfter = $null
        [bool] TryGetValues([string]$name, [ref]$values) {
            if ($name -eq 'Retry-After') { $values.Value = @('2'); return $true }
            return $false
        }
    }
    class FakeResponse {
        [int]$StatusCode
        [FakeRespHeaders]$Headers = [FakeRespHeaders]::new()
    }
    class FakeHttpException : System.Exception {
        [FakeResponse]$Response
        FakeHttpException([string]$message, [int]$code) : base($message) {
            $this.Response = [FakeResponse]::new()
            $this.Response.StatusCode = $code
        }
    }
    # Expose to test bodies (classes are discovery-scoped; stash factories on script scope).
    function New-FakeHttpException { param([int]$Code) [FakeHttpException]::new("HTTP $Code", $Code) }

    # A standard "everything on" notifications config.
    function New-NotifConfig {
        param([hashtable]$Override = @{})
        $base = @{
            enabled         = $true
            webhook_url     = 'https://discord.example/api/webhooks/123/abc'
            on_success      = $true
            on_warning      = $true
            on_failure      = $true
            on_restore      = $true
            failure_mention = '<@&999>'
        }
        foreach ($k in $Override.Keys) { $base[$k] = $Override[$k] }
        @{ notifications = $base }
    }
}

Describe 'New-SEBDiscordEmbed (embed construction)' {
    It 'maps each notification Type to its documented color' {
        InModuleScope NotificationManager {
            (New-SEBDiscordEmbed -Type Success -Title t -Message m).embeds[0].color | Should -Be 0x2ECC71
            (New-SEBDiscordEmbed -Type Warning -Title t -Message m).embeds[0].color | Should -Be 0xF1C40F
            (New-SEBDiscordEmbed -Type Failure -Title t -Message m).embeds[0].color | Should -Be 0xE74C3C
            (New-SEBDiscordEmbed -Type Restore -Title t -Message m).embeds[0].color | Should -Be 0x3498DB
            (New-SEBDiscordEmbed -Type Info    -Title t -Message m).embeds[0].color | Should -Be 0x95A5A6
        }
    }

    It 'places title/description on the embed and wraps it in an embeds array' {
        InModuleScope NotificationManager {
            $p = New-SEBDiscordEmbed -Type Info -Title 'My Title' -Message 'My Body'
            @($p.embeds).Count | Should -Be 1
            $p.embeds[0].title | Should -Be 'My Title'
            $p.embeds[0].description | Should -Be 'My Body'
            $p.embeds[0].timestamp | Should -Match '^\d{4}-\d{2}-\d{2}T'
        }
    }

    It 'renders a Fields hashtable as inline embed fields' {
        InModuleScope NotificationManager {
            $p = New-SEBDiscordEmbed -Type Success -Title t -Message m -Fields @{ Duration = '3m'; Size = '2 GB' }
            $names = @($p.embeds[0].fields | ForEach-Object { $_.name })
            $names | Should -Contain 'Duration'
            $names | Should -Contain 'Size'
            ($p.embeds[0].fields | Where-Object name -eq 'Duration').value | Should -Be '3m'
            # Assert inline POSITIVELY: every field's inline must be $true. The old
            # '... | Should -Not -Contain $false' passed vacuously if the inline key were dropped
            # (each element would be $null, never $false). Here a dropped/non-true inline FAILS.
            @($p.embeds[0].fields | ForEach-Object { $_.inline }) | Should -Be @($true, $true)
            ($p.embeds[0].fields | Where-Object { $_.inline -ne $true }) | Should -BeNullOrEmpty
        }
    }

    It 'promotes a Mention to top-level content (so Discord pings the role/user)' {
        InModuleScope NotificationManager {
            $p = New-SEBDiscordEmbed -Type Failure -Title t -Message m -Mention '<@&123>'
            $p.content | Should -Be '<@&123>'
        }
    }

    It 'omits content entirely when no mention is supplied' {
        InModuleScope NotificationManager {
            $p = New-SEBDiscordEmbed -Type Info -Title t -Message m
            $p.ContainsKey('content') | Should -BeFalse
        }
    }
}

Describe 'Send-SEBNotification (core sender)' {
    BeforeEach {
        Mock Invoke-WebRequest -ModuleName NotificationManager { [PSCustomObject]@{ StatusCode = 204 } }
        Mock Start-Sleep -ModuleName NotificationManager {}
    }

    It 'posts the embed JSON to the configured webhook URL' {
        Send-SEBNotification -Type Success -Title 'Done' -Message 'ok' -GlobalConfig (New-NotifConfig)
        Should -Invoke Invoke-WebRequest -ModuleName NotificationManager -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and
            $Uri -eq 'https://discord.example/api/webhooks/123/abc' -and
            $ContentType -eq 'application/json'
        }
    }

    It 'serializes a well-formed Discord payload (embed with the right color)' {
        $script:capturedBody = $null
        Mock Invoke-WebRequest -ModuleName NotificationManager {
            $script:capturedBody = $Body
            [PSCustomObject]@{ StatusCode = 204 }
        }
        Send-SEBNotification -Type Failure -Title 'Boom' -Message 'VSS error' -Fields @{ Code = '8' } -GlobalConfig (New-NotifConfig)
        $payload = $script:capturedBody | ConvertFrom-Json
        $payload.embeds[0].title | Should -Be 'Boom'
        $payload.embeds[0].color | Should -Be 0xE74C3C
        ($payload.embeds[0].fields | Where-Object name -eq 'Code').value | Should -Be '8'
    }

    It 'prepends the failure_mention as content ONLY for Failure notifications' {
        $script:bodies = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-WebRequest -ModuleName NotificationManager {
            $script:bodies.Add($Body); [PSCustomObject]@{ StatusCode = 204 }
        }
        Send-SEBNotification -Type Failure -Title f -Message m -GlobalConfig (New-NotifConfig)
        Send-SEBNotification -Type Success -Title s -Message m -GlobalConfig (New-NotifConfig)
        $fail = $script:bodies[0] | ConvertFrom-Json
        $succ = $script:bodies[1] | ConvertFrom-Json
        $fail.content | Should -Be '<@&999>'
        # Success must NOT carry a mention even though failure_mention is configured.
        ($succ.PSObject.Properties.Name -contains 'content') | Should -BeFalse
    }

    It 'skips (no HTTP) when the notifications section is missing' {
        Send-SEBNotification -Type Info -Title t -Message m -GlobalConfig @{} 3>$null
        Should -Invoke Invoke-WebRequest -ModuleName NotificationManager -Times 0 -Exactly
    }

    It 'skips (no HTTP) when notifications.enabled is false' {
        Send-SEBNotification -Type Info -Title t -Message m -GlobalConfig (New-NotifConfig @{ enabled = $false })
        Should -Invoke Invoke-WebRequest -ModuleName NotificationManager -Times 0 -Exactly
    }

    It 'skips (no HTTP) when webhook_url is blank' {
        Send-SEBNotification -Type Info -Title t -Message m -GlobalConfig (New-NotifConfig @{ webhook_url = '' }) 3>$null
        Should -Invoke Invoke-WebRequest -ModuleName NotificationManager -Times 0 -Exactly
    }

    It 'NEVER throws when the transport fails (CLAUDE.md: notifications must not block backups)' {
        Mock Invoke-WebRequest -ModuleName NotificationManager { throw 'connection refused' }
        { Send-SEBNotification -Type Failure -Title t -Message m -GlobalConfig (New-NotifConfig) 3>$null } |
            Should -Not -Throw
    }

    It 'retries on HTTP 429 honoring Retry-After, then succeeds (Start-Sleep mocked -- no real wait)' {
        $script:attempt = 0
        Mock Invoke-WebRequest -ModuleName NotificationManager {
            $script:attempt++
            if ($script:attempt -eq 1) { throw (New-FakeHttpException -Code 429) }
            [PSCustomObject]@{ StatusCode = 204 }
        }
        { Send-SEBNotification -Type Info -Title t -Message m -GlobalConfig (New-NotifConfig) 3>$null } | Should -Not -Throw
        # First attempt 429, second attempt 204 => exactly two posts and exactly one backoff sleep.
        Should -Invoke Invoke-WebRequest -ModuleName NotificationManager -Times 2 -Exactly
        Should -Invoke Start-Sleep -ModuleName NotificationManager -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
    }

    It 'does not loop forever: a persistent 429 stops after the retry budget and never throws' {
        Mock Invoke-WebRequest -ModuleName NotificationManager { throw (New-FakeHttpException -Code 429) }
        { Send-SEBNotification -Type Info -Title t -Message m -GlobalConfig (New-NotifConfig) 3>$null } | Should -Not -Throw
        # maxRetries = 3 -> three POST attempts total.
        Should -Invoke Invoke-WebRequest -ModuleName NotificationManager -Times 3 -Exactly
    }

    It 'does not retry a non-429 HTTP error (single attempt, no throw)' {
        Mock Invoke-WebRequest -ModuleName NotificationManager { throw (New-FakeHttpException -Code 500) }
        { Send-SEBNotification -Type Info -Title t -Message m -GlobalConfig (New-NotifConfig) 3>$null } | Should -Not -Throw
        Should -Invoke Invoke-WebRequest -ModuleName NotificationManager -Times 1 -Exactly
    }
}

Describe 'Send-SEBBackupNotification (summary builder + gating)' {
    BeforeEach {
        # Intercept the core sender so we assert the derived Type/Title/Fields without HTTP.
        Mock Send-SEBNotification -ModuleName NotificationManager {}
    }

    It 'sends a Success notification for a clean backup result' {
        $result = [PSCustomObject]@{ Type = 'Full'; Duration = 135.0; ArchiveSize = 2GB; FilesChanged = 12; Success = $true; ErrorMessage = $null }
        Send-SEBBackupNotification -InstanceName 'PvPArena' -BackupResult $result -GlobalConfig (New-NotifConfig)
        Should -Invoke Send-SEBNotification -ModuleName NotificationManager -Times 1 -Exactly -ParameterFilter {
            $Type -eq 'Success' -and $Title -like '*PvPArena*'
        }
    }

    It 'derives Failure (not Success) when the result reports Success=$false' {
        $result = [PSCustomObject]@{ Type = 'Incremental'; Duration = 5.0; ArchiveSize = 0; FilesChanged = 0; Success = $false; ErrorMessage = 'VSS timed out' }
        Send-SEBBackupNotification -InstanceName 'Creative01' -BackupResult $result -GlobalConfig (New-NotifConfig)
        Should -Invoke Send-SEBNotification -ModuleName NotificationManager -Times 1 -Exactly -ParameterFilter {
            $Type -eq 'Failure' -and $Message -like '*VSS timed out*'
        }
    }

    It 'derives Warning when the backup succeeded but carries an ErrorMessage' {
        $result = [PSCustomObject]@{ Type = 'Full'; Duration = 60.0; ArchiveSize = 1MB; FilesChanged = 3; Success = $true; ErrorMessage = 'one file skipped' }
        Send-SEBBackupNotification -InstanceName 'Srv' -BackupResult $result -GlobalConfig (New-NotifConfig)
        Should -Invoke Send-SEBNotification -ModuleName NotificationManager -Times 1 -Exactly -ParameterFilter { $Type -eq 'Warning' }
    }

    It 'does NOT send when the matching on_* flag is disabled (Success suppressed)' {
        $result = [PSCustomObject]@{ Type = 'Full'; Duration = 1; ArchiveSize = 1; FilesChanged = 0; Success = $true }
        Send-SEBBackupNotification -InstanceName 'Srv' -BackupResult $result -GlobalConfig (New-NotifConfig @{ on_success = $false })
        Should -Invoke Send-SEBNotification -ModuleName NotificationManager -Times 0 -Exactly
    }

    It 'a failure is still suppressed when on_failure is false (per-type gating, not just enabled)' {
        $result = [PSCustomObject]@{ Type = 'Full'; Duration = 1; ArchiveSize = 0; FilesChanged = 0; Success = $false; ErrorMessage = 'x' }
        Send-SEBBackupNotification -InstanceName 'Srv' -BackupResult $result -GlobalConfig (New-NotifConfig @{ on_failure = $false })
        Should -Invoke Send-SEBNotification -ModuleName NotificationManager -Times 0 -Exactly
    }

    It 'formats duration (m/s) and a human-readable size, and accepts the canonical result shape' {
        # Canonical Invoke-SEBBackup shape: BackupType / ArchiveSizeBytes / FileCount.
        $result = [PSCustomObject]@{ BackupType = 'Full'; Duration = [timespan]::FromSeconds(125); ArchiveSizeBytes = [long](2.5 * 1GB); FileCount = 7; Success = $true }
        Send-SEBBackupNotification -InstanceName 'Srv' -BackupResult $result -GlobalConfig (New-NotifConfig)
        Should -Invoke Send-SEBNotification -ModuleName NotificationManager -Times 1 -Exactly -ParameterFilter {
            $Fields['Type'] -eq 'Full' -and
            $Fields['Duration'] -eq '2m 5s' -and
            $Fields['Size'] -match 'GB' -and
            $Fields['Files Changed'] -eq '7'
        }
    }

    It 'never throws even if the core sender blows up (defense in depth)' {
        Mock Send-SEBNotification -ModuleName NotificationManager { throw 'unexpected' }
        $result = [PSCustomObject]@{ Type = 'Full'; Duration = 1; ArchiveSize = 1; FilesChanged = 0; Success = $true }
        { Send-SEBBackupNotification -InstanceName 'Srv' -BackupResult $result -GlobalConfig (New-NotifConfig) 3>$null } |
            Should -Not -Throw
    }
}

Describe 'Send-SEBRestoreNotification' {
    BeforeEach {
        Mock Send-SEBNotification -ModuleName NotificationManager {}
    }

    It 'sends a Restore-typed notification with the instance/restore-point/initiator fields' {
        Send-SEBRestoreNotification -InstanceName 'PvPArena' -RestorePoint '2026-02-27_Full' -InitiatedBy 'Admin:Jane' -GlobalConfig (New-NotifConfig)
        Should -Invoke Send-SEBNotification -ModuleName NotificationManager -Times 1 -Exactly -ParameterFilter {
            $Type -eq 'Restore' -and
            $Title -like '*PvPArena*' -and
            $Fields['Restore Point'] -eq '2026-02-27_Full' -and
            $Fields['Initiated By'] -eq 'Admin:Jane'
        }
    }

    It 'defaults Initiated By to "CLI" when not supplied' {
        Send-SEBRestoreNotification -InstanceName 'Srv' -RestorePoint 'rp1' -GlobalConfig (New-NotifConfig)
        Should -Invoke Send-SEBNotification -ModuleName NotificationManager -Times 1 -Exactly -ParameterFilter {
            $Fields['Initiated By'] -eq 'CLI'
        }
    }

    It 'sends by default when on_restore is absent (absent means "default on")' {
        $cfg = New-NotifConfig
        $cfg.notifications.Remove('on_restore')
        Send-SEBRestoreNotification -InstanceName 'Srv' -RestorePoint 'rp1' -GlobalConfig $cfg
        Should -Invoke Send-SEBNotification -ModuleName NotificationManager -Times 1 -Exactly
    }

    It 'is suppressed only when on_restore is explicitly the boolean $false' {
        Send-SEBRestoreNotification -InstanceName 'Srv' -RestorePoint 'rp1' -GlobalConfig (New-NotifConfig @{ on_restore = $false }) 3>$null
        Should -Invoke Send-SEBNotification -ModuleName NotificationManager -Times 0 -Exactly
    }

    It 'never throws if the core sender fails' {
        Mock Send-SEBNotification -ModuleName NotificationManager { throw 'boom' }
        { Send-SEBRestoreNotification -InstanceName 'Srv' -RestorePoint 'rp1' -GlobalConfig (New-NotifConfig) 3>$null } |
            Should -Not -Throw
    }
}

Describe 'Test-SEBNotificationConfig (diagnostic check)' {
    It 'returns $true on a 2xx response from a well-formed config' {
        Mock Invoke-WebRequest -ModuleName NotificationManager { [PSCustomObject]@{ StatusCode = 204 } }
        Test-SEBNotificationConfig -GlobalConfig (New-NotifConfig) | Should -BeTrue
        Should -Invoke Invoke-WebRequest -ModuleName NotificationManager -Times 1 -Exactly
    }

    It 'returns $false when the notifications section is missing (no HTTP)' {
        Mock Invoke-WebRequest -ModuleName NotificationManager { [PSCustomObject]@{ StatusCode = 204 } }
        Test-SEBNotificationConfig -GlobalConfig @{} 3>$null | Should -BeFalse
        Should -Invoke Invoke-WebRequest -ModuleName NotificationManager -Times 0 -Exactly
    }

    It 'returns $false when webhook_url is blank (no HTTP)' {
        Mock Invoke-WebRequest -ModuleName NotificationManager { [PSCustomObject]@{ StatusCode = 204 } }
        Test-SEBNotificationConfig -GlobalConfig (New-NotifConfig @{ webhook_url = '   ' }) 3>$null | Should -BeFalse
        Should -Invoke Invoke-WebRequest -ModuleName NotificationManager -Times 0 -Exactly
    }

    It 'returns $false (does not throw) when the transport fails' {
        Mock Invoke-WebRequest -ModuleName NotificationManager { throw 'unreachable' }
        $result = $null
        { $script:tc = Test-SEBNotificationConfig -GlobalConfig (New-NotifConfig) 3>$null } | Should -Not -Throw
        $script:tc | Should -BeFalse
    }
}
