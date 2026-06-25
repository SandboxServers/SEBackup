function Test-SEBVSSService {
    <#
    .SYNOPSIS
        Tests that the VSS service is running and functional on a remote node.

    .DESCRIPTION
        Internal helper function that verifies the Volume Shadow Copy Service
        (VSS) is operational on the target remote node. The test is performed
        by creating a temporary shadow copy and immediately deleting it.

        This validates that:
        - The VSS service is running.
        - The executing user has sufficient privileges to create shadow copies.
        - The underlying storage supports VSS snapshots.

        This function is not exported and is intended for use only within the
        VSSManager module.

    .PARAMETER Volume
        The volume to test VSS functionality on (e.g., "C:\").

    .PARAMETER Session
        An active PSSession to the remote Windows node where the VSS test
        should be performed.

    .OUTPUTS
        System.Boolean
        $true if VSS is functional on the remote node, $false otherwise.

    .EXAMPLE
        $session = New-PSSession -ComputerName 'Server01'
        $isWorking = Test-SEBVSSService -Volume 'C:\' -Session $session
        if (-not $isWorking) { Write-Warning "VSS is not functional" }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Volume,

        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    Write-Verbose "VSSManager: Testing VSS service on $($Session.ComputerName) for volume $Volume"

    try {
        # Route through the wrapper for retry/logging/reconnect; the block stays node-local.
        $result = Invoke-SEBRemoteCommand -Session $Session -ScriptBlock {
            param($TestVolume)

            try {
                # Attempt to create a test shadow copy
                $createResult = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{
                    Volume = $TestVolume
                }

                if ($createResult.ReturnValue -ne 0) {
                    return @{
                        Success = $false
                        Error   = "VSS create returned error code: $($createResult.ReturnValue)"
                    }
                }

                $testShadowId = $createResult.ShadowID

                # Immediately clean up the test shadow copy
                $shadow = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $testShadowId }
                if ($shadow) {
                    $shadow | Remove-CimInstance
                }

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
        } -ArgumentList $Volume -ErrorAction Stop

        if ($result.Success) {
            Write-Verbose "VSSManager: VSS service is functional on $($Session.ComputerName)"
            return $true
        }
        else {
            Write-Warning "VSSManager: VSS test failed on $($Session.ComputerName): $($result.Error)"
            return $false
        }
    }
    catch {
        Write-Warning "VSSManager: Could not test VSS on $($Session.ComputerName): $($_.Exception.Message)"
        return $false
    }
}
