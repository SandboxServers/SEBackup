<#
.SYNOPSIS
    Provides functions for running SEBackup operations in background PowerShell runspaces.

.DESCRIPTION
    This module contains helper functions that enable the SEBackup GUI to run long-running
    operations (backups, restores, integrity checks, etc.) in background PowerShell runspaces
    without freezing the WPF UI thread.

    Background operations use Dispatcher.Invoke() to safely update UI elements from the
    background thread when the operation completes or needs to report progress.

.NOTES
    File:    RunspaceHelper.ps1
    Project: SEBackup - Space Engineers Torch Server Backup & Restore System
#>

function Start-SEBBackgroundOperation {
    <#
    .SYNOPSIS
        Starts a long-running operation in a background PowerShell runspace.

    .DESCRIPTION
        Creates a new PowerShell runspace, starts the given ScriptBlock asynchronously,
        and sets up a callback that uses the WPF Dispatcher to safely update the UI
        when the operation completes.

        The returned operation object can be used to check status or stop the operation
        via Stop-SEBBackgroundOperation.

    .PARAMETER ScriptBlock
        The PowerShell script block to execute in the background runspace. This code
        runs on a separate thread and must not directly access WPF UI elements.

    .PARAMETER ArgumentList
        An optional array of arguments to pass to the ScriptBlock. These are available
        as $args inside the ScriptBlock, or use param() to name them.

    .PARAMETER OnComplete
        A script block that is invoked on the UI thread (via Dispatcher.Invoke) when
        the background operation finishes. Receives two parameters: $Result (the output
        from the background ScriptBlock) and $Error (any error that occurred, or $null).

    .PARAMETER Dispatcher
        The WPF Dispatcher object from the main window, used to marshal the OnComplete
        callback back to the UI thread. Typically obtained from $Window.Dispatcher.

    .PARAMETER ModulesToImport
        Optional array of module names or paths to import into the background runspace.
        The SEBackup module path is added by default.

    .EXAMPLE
        $op = Start-SEBBackgroundOperation -ScriptBlock {
            param($InstanceName)
            Import-Module SEBackup
            Invoke-SEBBackup -InstanceName $InstanceName
        } -ArgumentList @('PvPArena') -OnComplete {
            param($Result, $Error)
            if ($Error) {
                [System.Windows.MessageBox]::Show("Backup failed: $Error")
            } else {
                [System.Windows.MessageBox]::Show("Backup complete!")
            }
        } -Dispatcher $Window.Dispatcher

    .EXAMPLE
        # Stop a running operation
        Stop-SEBBackgroundOperation -Operation $op

    .OUTPUTS
        PSCustomObject
        An object with properties: Id, PowerShell, AsyncResult, Runspace, Status, StartedAt,
        and a Stop() method.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [object[]]$ArgumentList,

        [Parameter()]
        [scriptblock]$OnComplete,

        [Parameter(Mandatory)]
        [object]$Dispatcher,

        [Parameter()]
        [string[]]$ModulesToImport
    )

    # Generate a unique operation ID
    $operationId = [guid]::NewGuid().ToString('N').Substring(0, 8)

    # Create the runspace
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $runspace.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    # Resolve the SEBackup module path and add to the runspace
    $sebModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules'
    $sebModulePath = (Resolve-Path -Path $sebModulePath -ErrorAction SilentlyContinue).Path
    if ($sebModulePath) {
        $runspace.SessionStateProxy.SetVariable('SEBModulePath', $sebModulePath)
    }

    # Create the PowerShell instance
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    # Add the user's script block
    $ps.AddScript($ScriptBlock.ToString())

    # Add arguments if provided
    if ($ArgumentList) {
        foreach ($arg in $ArgumentList) {
            $ps.AddArgument($arg)
        }
    }

    # Build the operation object
    $operation = [PSCustomObject]@{
        Id          = $operationId
        PowerShell  = $ps
        AsyncResult = $null
        Runspace    = $runspace
        Status      = 'Running'
        StartedAt   = [datetime]::UtcNow
        CompletedAt = $null
        Error       = $null
    }

    # Add a Stop() method
    $operation | Add-Member -MemberType ScriptMethod -Name 'Stop' -Value {
        Stop-SEBBackgroundOperation -Operation $this
    }

    # Start the async operation with a completion callback
    $operation.AsyncResult = $ps.BeginInvoke()

    # Set up a timer to poll for completion (WPF-friendly approach)
    # Using a DispatcherTimer so the callback runs on the UI thread automatically
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [timespan]::FromMilliseconds(250)

    # Store references for the closure
    $timerState = @{
        Timer      = $timer
        Operation  = $operation
        OnComplete = $OnComplete
        Dispatcher = $Dispatcher
        PS         = $ps
    }

    $timer.Add_Tick({
        $state = $timerState

        if ($state.Operation.AsyncResult.IsCompleted) {
            # Stop polling
            $state.Timer.Stop()

            $result = $null
            $opError = $null

            try {
                $result = $state.PS.EndInvoke($state.Operation.AsyncResult)

                # Check for errors in the PowerShell streams
                if ($state.PS.HadErrors -and $state.PS.Streams.Error.Count -gt 0) {
                    $opError = $state.PS.Streams.Error[0].Exception.Message
                }
            }
            catch {
                $opError = $_.Exception.Message
            }

            # Update operation status
            $state.Operation.Status = if ($opError) { 'Failed' } else { 'Completed' }
            $state.Operation.CompletedAt = [datetime]::UtcNow
            $state.Operation.Error = $opError

            # Invoke the OnComplete callback on the UI thread
            if ($state.OnComplete) {
                try {
                    $state.Dispatcher.Invoke([action]{
                        & $state.OnComplete $result $opError
                    })
                }
                catch {
                    Write-Warning "SEBBackgroundOperation [$($state.Operation.Id)]: OnComplete callback error: $_"
                }
            }

            # Cleanup
            try {
                $state.PS.Dispose()
                $state.Operation.Runspace.Close()
                $state.Operation.Runspace.Dispose()
            }
            catch {
                # Silently ignore cleanup errors
            }
        }
    }.GetNewClosure())

    $timer.Start()

    Write-Verbose "Started background operation [$operationId]"

    return $operation
}

function Stop-SEBBackgroundOperation {
    <#
    .SYNOPSIS
        Stops and cleans up a background SEBackup operation.

    .DESCRIPTION
        Stops a running background PowerShell operation that was started with
        Start-SEBBackgroundOperation. Sends a stop signal to the PowerShell
        instance, waits briefly for graceful termination, then forcefully
        disposes of the runspace if needed.

    .PARAMETER Operation
        The operation object returned by Start-SEBBackgroundOperation.

    .EXAMPLE
        $op = Start-SEBBackgroundOperation -ScriptBlock { Start-Sleep 60 } -Dispatcher $Window.Dispatcher
        Stop-SEBBackgroundOperation -Operation $op

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Operation
    )

    if ($null -eq $Operation) {
        Write-Warning "Stop-SEBBackgroundOperation: Operation is null."
        return
    }

    if ($Operation.Status -ne 'Running') {
        Write-Verbose "Stop-SEBBackgroundOperation [$($Operation.Id)]: Operation is already $($Operation.Status)."
        return
    }

    Write-Verbose "Stop-SEBBackgroundOperation [$($Operation.Id)]: Stopping operation..."

    try {
        # Signal the PowerShell instance to stop
        if ($Operation.PowerShell) {
            $Operation.PowerShell.Stop()
        }
    }
    catch {
        Write-Warning "Stop-SEBBackgroundOperation [$($Operation.Id)]: Error during Stop(): $_"
    }

    # Allow a brief grace period for the stop to take effect
    Start-Sleep -Milliseconds 500

    try {
        # Dispose the PowerShell instance
        if ($Operation.PowerShell) {
            $Operation.PowerShell.Dispose()
        }
    }
    catch {
        # Ignore disposal errors
    }

    try {
        # Close and dispose the runspace
        if ($Operation.Runspace -and $Operation.Runspace.RunspaceStateInfo.State -eq 'Opened') {
            $Operation.Runspace.Close()
        }
        if ($Operation.Runspace) {
            $Operation.Runspace.Dispose()
        }
    }
    catch {
        # Ignore disposal errors
    }

    $Operation.Status = 'Stopped'
    $Operation.CompletedAt = [datetime]::UtcNow

    Write-Verbose "Stop-SEBBackgroundOperation [$($Operation.Id)]: Operation stopped."
}
