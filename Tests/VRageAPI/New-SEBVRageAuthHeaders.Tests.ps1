#Requires -Module Pester

# The VRage Remote API HMAC scheme must (1) Base64-decode the security key to get the HMAC
# key bytes and (2) bind the signature to the request URI. The previous implementation used
# the UTF-8 bytes of the key string and omitted the URI, which a real Torch server rejects.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . "$repoRoot/Modules/VRageAPI/Private/New-SEBVRageAuthHeaders.ps1"

    # Reference signer that mirrors the documented scheme, computed independently here so the
    # test fails if the implementation reverts to UTF-8 keys or drops the URI.
    function Get-ExpectedSignature {
        param([string]$Key, [string]$Uri, [string]$Nonce, [string]$Date)
        $keyBytes = [Convert]::FromBase64String($Key)
        $message = "$Uri`r`n$Nonce`r`n$Date`r`n"
        $hmac = [System.Security.Cryptography.HMACSHA1]::new($keyBytes)
        try { $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($message)) }
        finally { $hmac.Dispose() }
        [Convert]::ToBase64String($hash)
    }

    $script:key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('remote-api-key-32-bytes-padding!!'))
    $script:nonce = 'abc123nonce'
    $script:date = 'Thu, 27 Feb 2026 12:00:00 GMT'
}

Describe 'New-SEBVRageAuthHeaders' {
    It 'signs with the Base64-decoded key over the request URI (deterministic)' {
        $uri = '/vrageremote/v1/session/save'
        $h = New-SEBVRageAuthHeaders -SecurityKey $script:key -RequestUri $uri -Nonce $script:nonce -Date $script:date
        $expectedSig = Get-ExpectedSignature -Key $script:key -Uri $uri -Nonce $script:nonce -Date $script:date
        $h.Authorization | Should -Be "$($script:nonce):$expectedSig"
        $h.Date | Should -Be $script:date
    }

    It 'binds the signature to the URI (different endpoint -> different signature)' {
        $a = New-SEBVRageAuthHeaders -SecurityKey $script:key -RequestUri '/vrageremote/v1/session/save' -Nonce $script:nonce -Date $script:date
        $b = New-SEBVRageAuthHeaders -SecurityKey $script:key -RequestUri '/vrageremote/v1/server' -Nonce $script:nonce -Date $script:date
        $a.Authorization | Should -Not -Be $b.Authorization
    }

    It 'rejects a non-Base64 security key with a clear error' {
        { New-SEBVRageAuthHeaders -SecurityKey 'not valid base64!!!' -RequestUri '/x' } |
            Should -Throw -ExpectedMessage '*Base64*'
    }
}
