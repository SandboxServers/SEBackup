function New-SEBVRageAuthHeaders {
    <#
    .SYNOPSIS
        Generates HMAC-SHA1 authentication headers for VRage Remote API requests.

    .DESCRIPTION
        Internal helper function that creates the authentication headers required
        by the VRage Remote API. The authentication scheme uses HMAC-SHA1 where:

        1. A random nonce is generated from cryptographic random bytes.
        2. The current UTC date is formatted in RFC1123 format.
        3. An HMAC-SHA1 signature is computed over the message (nonce + date)
           using the security key converted to UTF-8 bytes.
        4. The Authorization header is set to "nonce:base64(signature)".

        This function is not exported and is intended for use only within the
        VRageAPI module.

    .PARAMETER SecurityKey
        The 8-character security key configured in the Torch server for VRage
        Remote API authentication.

    .OUTPUTS
        System.Collections.Hashtable
        A hashtable containing 'Date' and 'Authorization' header values, plus
        the 'Nonce' used for the request.

    .EXAMPLE
        $headers = New-SEBVRageAuthHeaders -SecurityKey 'MyKey123'
        # Returns: @{ Date = 'Thu, 27 Feb 2026 12:00:00 GMT'; Authorization = 'a1b2c3...:base64sig'; Nonce = 'a1b2c3...' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SecurityKey
    )

    # Generate random nonce from cryptographic random bytes
    $nonceBytes = [byte[]]::new(16)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($nonceBytes)
    $nonce = ($nonceBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    # Get current UTC date in RFC1123 format
    $date = [DateTime]::UtcNow.ToString('R')

    # Compute HMAC-SHA1 signature: message is nonce concatenated with date string
    $message = "$nonce$date"
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($SecurityKey)
    $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($message)

    $hmacSha1 = [System.Security.Cryptography.HMACSHA1]::new($keyBytes)
    try {
        $hashBytes = $hmacSha1.ComputeHash($messageBytes)
    }
    finally {
        $hmacSha1.Dispose()
    }

    $signature = [Convert]::ToBase64String($hashBytes)

    return @{
        Date          = $date
        Authorization = "${nonce}:${signature}"
        Nonce         = $nonce
    }
}
