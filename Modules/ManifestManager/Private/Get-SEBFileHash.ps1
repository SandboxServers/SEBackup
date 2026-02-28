function Get-SEBFileHash {
    <#
    .SYNOPSIS
        Computes the SHA256 hash of a file, optionally on a remote node.

    .DESCRIPTION
        Calculates the SHA256 hash of the specified file using Get-FileHash. When a
        PSSession is provided, the hash computation runs on the remote node via
        Invoke-Command, avoiding the need to transfer file contents across the network.

        Returns the hash as a lowercase hexadecimal string, consistent with the manifest
        format used throughout SEBackup.

    .PARAMETER Path
        The full path to the file to hash. When used with -Session, this path must be
        valid on the remote node.

    .PARAMETER Session
        An optional PSSession to a remote node. When specified, the hash is computed
        on the remote machine rather than locally.

    .EXAMPLE
        Get-SEBFileHash -Path "C:\Servers\Instance1\Sandbox.sbc"
        # Returns: "a1b2c3d4e5f6..."

    .EXAMPLE
        $session = New-PSSession -ComputerName "GameNode01"
        Get-SEBFileHash -Path "C:\Servers\Instance1\Sandbox.sbc" -Session $session

    .OUTPUTS
        System.String
        A lowercase hexadecimal SHA256 hash string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $hashScript = {
        param([string]$FilePath)
        $result = Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction Stop
        return $result.Hash.ToLower()
    }

    try {
        if ($Session) {
            $hash = Invoke-Command -Session $Session -ScriptBlock $hashScript -ArgumentList $Path -ErrorAction Stop
        }
        else {
            $hash = & $hashScript -FilePath $Path
        }
        return $hash
    }
    catch {
        Write-Error "Failed to compute SHA256 hash for '$Path': $_"
        throw
    }
}
