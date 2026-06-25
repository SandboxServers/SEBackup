#Requires -Module Pester

# Issue #19 -- unit coverage for the request-signing / auth-header ASSEMBLY in Invoke-SEBVRageRequest.
# New-SEBVRageAuthHeaders.Tests.ps1 already pins the HMAC math (Base64-decoded key, canonical
# message, pinned known-answer signature, URI binding). This file pins how the CALLER wires that
# signature into an HTTP request, with the network boundary (Invoke-RestMethod) mocked so no live
# Torch server is touched:
#   * the endpoint is normalized to the canonical '/vrageremote/v1/...' path WITHOUT double-prefixing;
#   * the signature is bound to that exact path (the Authorization the server would verify is computed
#     over the SAME path the request is sent to);
#   * the Authorization header is assembled as 'nonce:base64(signature)', and a Date header is sent;
#   * a non-Base64 key fails gracefully (returns $null) instead of throwing.
#
# Verifying the field ORDER against a REAL Torch server is issue #29 (the Torch harness) -- NOT done
# here. The one test that would need a live server is tagged 'Integration' and skipped.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # A real, valid Base64 key so New-SEBVRageAuthHeaders (called internally) does not bail.
    $script:key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('0123456789abcdef'))

    # Independent reference signer mirroring the documented canonical scheme, so the test fails if
    # the request path the signature is bound to ever diverges from the path actually requested.
    function Get-ExpectedSignature {
        param([string]$Key, [string]$Uri, [string]$Nonce, [string]$Date)
        $keyBytes = [Convert]::FromBase64String($Key)
        $message = "$Uri`r`n$Nonce`r`n$Date`r`n"
        $hmac = [System.Security.Cryptography.HMACSHA1]::new($keyBytes)
        try { $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($message)) }
        finally { $hmac.Dispose() }
        [Convert]::ToBase64String($hash)
    }
}

Describe 'Invoke-SEBVRageRequest auth-header assembly (HTTP mocked)' {

    Context 'endpoint normalization -> signed request path' {
        BeforeAll {
            # Capture the URL and headers handed to Invoke-RestMethod without making a real call.
            Mock Invoke-RestMethod -ModuleName VRageAPI {
                $script:captured = @{ Uri = $Uri; Headers = $Headers; Method = $Method }
                return @{ ok = $true }
            }
        }

        It "prefixes a bare endpoint to '/vrageremote/v1/<endpoint>'" {
            $null = Invoke-SEBVRageRequest -Hostname 'localhost' -Port 8080 -SecurityKey $script:key -Endpoint 'server/ping'
            $script:captured.Uri | Should -Be 'http://localhost:8080/vrageremote/v1/server/ping'
        }

        It 'does not double-prefix an already-prefixed endpoint' {
            $null = Invoke-SEBVRageRequest -Hostname 'localhost' -Port 8080 -SecurityKey $script:key -Endpoint '/vrageremote/v1/session/save'
            $script:captured.Uri | Should -Be 'http://localhost:8080/vrageremote/v1/session/save'
        }

        It 'tolerates a leading slash on a bare endpoint' {
            $null = Invoke-SEBVRageRequest -Hostname '10.0.0.5' -Port 9000 -SecurityKey $script:key -Endpoint '/server'
            $script:captured.Uri | Should -Be 'http://10.0.0.5:9000/vrageremote/v1/server'
        }
    }

    Context 'Authorization header is bound to the requested path' {
        It 'computes the signature over the SAME path the request targets' {
            # Drive a deterministic nonce/date INTO the signer by mocking it; capture what the request
            # actually sends, then independently re-derive the signature over the URL's path.
            $fixedNonce = 'reqnonce42'
            $fixedDate  = 'Mon, 01 Jan 2024 00:00:00 GMT'

            Mock New-SEBVRageAuthHeaders -ModuleName VRageAPI {
                # Honour the resource-bound contract: sign exactly the -RequestUri the caller passes.
                $sig = (Get-ExpectedSignature -Key $script:key -Uri $RequestUri -Nonce $fixedNonce -Date $fixedDate)
                @{ Date = $fixedDate; Authorization = "${fixedNonce}:${sig}"; Nonce = $fixedNonce }
            }
            Mock Invoke-RestMethod -ModuleName VRageAPI {
                $script:captured = @{ Uri = $Uri; Headers = $Headers }
                return @{ ok = $true }
            }

            $null = Invoke-SEBVRageRequest -Hostname 'host1' -Port 8080 -SecurityKey $script:key -Endpoint 'session/save' -Method PATCH

            # The path the signature was bound to (asserted via the independent re-derivation).
            $expectedPath = '/vrageremote/v1/session/save'
            $expectedSig  = Get-ExpectedSignature -Key $script:key -Uri $expectedPath -Nonce $fixedNonce -Date $fixedDate

            $script:captured.Uri | Should -Be "http://host1:8080$expectedPath"
            $script:captured.Headers['Authorization'] | Should -Be "${fixedNonce}:${expectedSig}"
            $script:captured.Headers['Date'] | Should -Be $fixedDate
        }

        It "assembles the Authorization header as 'nonce:base64(signature)' and sends a Date header" {
            Mock Invoke-RestMethod -ModuleName VRageAPI {
                $script:captured = @{ Headers = $Headers }
                return @{ ok = $true }
            }
            $null = Invoke-SEBVRageRequest -Hostname 'localhost' -Port 8080 -SecurityKey $script:key -Endpoint 'server'

            $script:captured.Headers.ContainsKey('Authorization') | Should -BeTrue
            $script:captured.Headers.ContainsKey('Date')          | Should -BeTrue
            # nonce (hex):base64sig -- exactly two colon-separated parts, the second valid Base64.
            $parts = $script:captured.Headers['Authorization'] -split ':', 2
            $parts.Count | Should -Be 2
            $parts[0] | Should -Not -BeNullOrEmpty
            { [Convert]::FromBase64String($parts[1]) } | Should -Not -Throw
        }
    }

    Context 'request wiring' {
        It 'passes the chosen HTTP method through to Invoke-RestMethod' {
            Mock Invoke-RestMethod -ModuleName VRageAPI {
                $script:captured = @{ Method = $Method }
                return @{ ok = $true }
            }
            $null = Invoke-SEBVRageRequest -Hostname 'h' -Port 8080 -SecurityKey $script:key -Endpoint 'session/save' -Method PATCH
            $script:captured.Method | Should -Be 'PATCH'
        }

        It 'serializes a non-string body to JSON' {
            Mock Invoke-RestMethod -ModuleName VRageAPI {
                $script:captured = @{ Body = $Body }
                return @{ ok = $true }
            }
            $null = Invoke-SEBVRageRequest -Hostname 'h' -Port 8080 -SecurityKey $script:key -Endpoint 'session' -Method POST -Body @{ Prop = 'val' }
            $script:captured.Body | Should -Match '"Prop"'
            ($script:captured.Body | ConvertFrom-Json).Prop | Should -Be 'val'
        }
    }

    Context 'graceful failure (no live server, network mocked)' {
        It 'returns $null on a non-Base64 security key without throwing' {
            # New-SEBVRageAuthHeaders throws on a bad key; the caller must convert that to a $null
            # return (the same contract as a connection failure), not propagate the exception.
            Mock Invoke-RestMethod -ModuleName VRageAPI { @{ ok = $true } }
            $result = Invoke-SEBVRageRequest -Hostname 'h' -Port 8080 -SecurityKey 'not base64!!!' -Endpoint 'server' -WarningAction SilentlyContinue
            $result | Should -BeNullOrEmpty
            Should -Invoke Invoke-RestMethod -ModuleName VRageAPI -Times 0 -Exactly
        }

        It 'returns $null and does not throw when the HTTP call fails' {
            Mock Invoke-RestMethod -ModuleName VRageAPI { throw [System.Net.Http.HttpRequestException]::new('refused') }
            $result = Invoke-SEBVRageRequest -Hostname 'h' -Port 8080 -SecurityKey $script:key -Endpoint 'server' -WarningAction SilentlyContinue
            $result | Should -BeNullOrEmpty
        }
    }

    # Field ORDER against a real Torch server is issue #29; this placeholder documents the deferral
    # and never runs in the offline gate.
    It 'round-trips against a live Torch server (deferred to the Torch harness)' -Tag 'Integration' -Skip {
        Set-ItResult -Skipped -Because 'live Torch field-order verification is issue #29 (Torch harness)'
    }
}

Describe 'New-SEBVRageAuthHeaders deterministic outputs (issue #19 additions)' {

    BeforeAll {
        . "$($script:repoRoot ?? (Resolve-Path "$PSScriptRoot/../..").Path)/Modules/VRageAPI/Private/New-SEBVRageAuthHeaders.ps1"
        $script:k = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('0123456789abcdef'))
    }

    It 'echoes the supplied nonce and date verbatim into the result' {
        $h = New-SEBVRageAuthHeaders -SecurityKey $script:k -RequestUri '/vrageremote/v1/server' -Nonce 'echome' -Date 'Mon, 01 Jan 2024 00:00:00 GMT'
        $h.Nonce | Should -Be 'echome'
        $h.Date  | Should -Be 'Mon, 01 Jan 2024 00:00:00 GMT'
        $h.Authorization | Should -BeLike 'echome:*'
    }

    It 'produces a different signature for a different nonce (same key/uri/date)' {
        $a = New-SEBVRageAuthHeaders -SecurityKey $script:k -RequestUri '/vrageremote/v1/server' -Nonce 'nonceA' -Date 'Mon, 01 Jan 2024 00:00:00 GMT'
        $b = New-SEBVRageAuthHeaders -SecurityKey $script:k -RequestUri '/vrageremote/v1/server' -Nonce 'nonceB' -Date 'Mon, 01 Jan 2024 00:00:00 GMT'
        ($a.Authorization -split ':', 2)[1] | Should -Not -Be (($b.Authorization -split ':', 2)[1])
    }

    It 'is deterministic: identical inputs yield an identical Authorization' {
        $a = New-SEBVRageAuthHeaders -SecurityKey $script:k -RequestUri '/vrageremote/v1/server/ping' -Nonce 'fixed' -Date 'Mon, 01 Jan 2024 00:00:00 GMT'
        $b = New-SEBVRageAuthHeaders -SecurityKey $script:k -RequestUri '/vrageremote/v1/server/ping' -Nonce 'fixed' -Date 'Mon, 01 Jan 2024 00:00:00 GMT'
        $a.Authorization | Should -Be $b.Authorization
    }

    It 'auto-generates a 32-hex-char nonce when none is supplied' {
        $h = New-SEBVRageAuthHeaders -SecurityKey $script:k -RequestUri '/vrageremote/v1/server'
        $h.Nonce | Should -Match '^[0-9a-f]{32}$' -Because '16 random bytes rendered as lowercase hex'
    }
}
