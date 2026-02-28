function Remove-SEBShadowCopy {
    <#
    .SYNOPSIS
        Removes a VSS shadow copy from a remote Windows node.

    .DESCRIPTION
        Deletes a previously created Volume Shadow Copy Service (VSS) snapshot
        on a remote Windows node. The shadow copy is identified by its unique
        ShadowID and removed via the Win32_ShadowCopy WMI class.

        This function should be called as part of cleanup after a backup
        operation completes, whether successfully or not. Failing to remove
        shadow copies can consume significant disk space over time.

        The operation is executed on the remote node via Invoke-Command.

    .PARAMETER ShadowID
        The unique identifier of the shadow copy to remove. This is the
        ShadowID returned by New-SEBShadowCopy.

    .PARAMETER Session
        An active PSSession to the remote Windows node where the shadow copy
        exists. The session must have administrative privileges.

    .EXAMPLE
        $shadow = New-SEBShadowCopy -Volume 'C:\' -Session $session
        # ... perform backup operations ...
        Remove-SEBShadowCopy -ShadowID $shadow.ShadowID -Session $session

    .EXAMPLE
        Remove-SEBShadowCopy -ShadowID '{B3A7C1E2-4F5D-6A8B-9C0E-1D2F3A4B5C6D}' -Session $session -Verbose

    .OUTPUTS
        System.Boolean
        $true if the shadow copy was successfully removed, $false if removal
        failed or the shadow copy was not found.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ShadowID,

        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    Write-Verbose "VSSManager: Removing shadow copy $ShadowID on $($Session.ComputerName)"

    try {
        $result = Invoke-Command -Session $Session -ScriptBlock {
            param($TargetShadowID)

            try {
                $shadow = Get-CimInstance -ClassName Win32_ShadowCopy |
                    Where-Object { $_.ID -eq $TargetShadowID }

                if (-not $shadow) {
                    return @{
                        Success = $false
                        Error   = "Shadow copy with ID '$TargetShadowID' not found"
                    }
                }

                $shadow | Remove-CimInstance

                return @{
                    Success = $true
                    Error   = $null
                }
            }
            catch {
                return @{
                    Success = $false
                    Error   = $_.Exception.Message
                }
            }
        } -ArgumentList $ShadowID -ErrorAction Stop

        if ($result.Success) {
            Write-Verbose "VSSManager: Shadow copy $ShadowID removed successfully"
            return $true
        }
        else {
            Write-Warning "VSSManager: Failed to remove shadow copy $ShadowID on $($Session.ComputerName): $($result.Error)"
            return $false
        }
    }
    catch {
        Write-Warning "VSSManager: Error removing shadow copy $ShadowID on $($Session.ComputerName): $($_.Exception.Message)"
        return $false
    }
}
