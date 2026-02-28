<#
.SYNOPSIS
    Provides helper functions for thread-safe WPF UI updates in the SEBackup GUI.

.DESCRIPTION
    When background runspace operations need to update WPF UI elements, they must
    marshal those calls to the UI thread via the Dispatcher. This module provides
    safe, error-handled wrappers around Dispatcher.Invoke() and common UI update
    patterns such as setting the status bar and showing notification dialogs.

.NOTES
    File:    UIDispatcher.ps1
    Project: SEBackup - Space Engineers Torch Server Backup & Restore System
#>

function Update-SEBUIElement {
    <#
    .SYNOPSIS
        Executes an action on the WPF UI thread via Dispatcher.Invoke().

    .DESCRIPTION
        Wraps Dispatcher.Invoke() with error handling to safely update WPF UI
        elements from a background thread. If the Dispatcher is shutting down
        or unavailable, the error is caught and logged rather than crashing the
        background operation.

        This is the low-level building block used by Set-SEBUIStatus and other
        UI helper functions. Use it directly when you need to update arbitrary
        UI elements from a background runspace.

    .PARAMETER Dispatcher
        The WPF Dispatcher object from the main window. Obtained from
        $Window.Dispatcher in the GUI startup script.

    .PARAMETER Action
        A script block containing the UI update code to execute on the UI thread.
        This code has access to all UI element variables in the calling scope.

    .EXAMPLE
        Update-SEBUIElement -Dispatcher $Window.Dispatcher -Action {
            $StatusBarText.Text = "Backup complete!"
        }

    .EXAMPLE
        # Update a progress bar from a background runspace
        Update-SEBUIElement -Dispatcher $Dispatcher -Action {
            $ProgressBar.Value = 75
            $ProgressLabel.Text = "75% complete"
        }

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Dispatcher,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    if ($null -eq $Dispatcher) {
        Write-Warning "Update-SEBUIElement: Dispatcher is null. Cannot update UI."
        return
    }

    try {
        # Check if the dispatcher is still operational
        if ($Dispatcher.HasShutdownStarted -or $Dispatcher.HasShutdownFinished) {
            Write-Verbose "Update-SEBUIElement: Dispatcher has shut down. Skipping UI update."
            return
        }

        # Marshal the action to the UI thread
        $Dispatcher.Invoke(
            [action]$Action,
            [System.Windows.Threading.DispatcherPriority]::Normal
        )
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        # Dispatcher was shut down during the invoke -- expected during window close
        Write-Verbose "Update-SEBUIElement: Dispatcher invoke was cancelled (window closing)."
    }
    catch {
        Write-Warning "Update-SEBUIElement: Failed to update UI element: $_"
    }
}

function Set-SEBUIStatus {
    <#
    .SYNOPSIS
        Updates the SEBackup dashboard status bar safely from any thread.

    .DESCRIPTION
        Sets the status bar text, indicator color, and timestamp in the main window's
        status bar. Uses Update-SEBUIElement internally to ensure thread safety when
        called from background runspaces.

        The status bar has three visual elements:
        - StatusIndicator: A colored ellipse (green/yellow/red) indicating health.
        - StatusBarText: The message text.
        - StatusBarTime: A timestamp showing when the status was last updated.

    .PARAMETER StatusBar
        A hashtable containing references to the status bar UI elements:
        @{
            Indicator = $StatusIndicator   # Ellipse element
            Text      = $StatusBarText     # TextBlock element
            Time      = $StatusBarTime     # TextBlock element
        }

    .PARAMETER Message
        The status message text to display.

    .PARAMETER Type
        The type of status, which determines the indicator color:
        - "Info"    : Blue indicator (default)
        - "Success" : Green indicator
        - "Warning" : Yellow indicator
        - "Error"   : Red indicator

    .PARAMETER Dispatcher
        The WPF Dispatcher object for thread-safe UI updates.

    .EXAMPLE
        Set-SEBUIStatus -StatusBar $statusBarRefs -Message "Backup in progress..." -Type "Info" -Dispatcher $Window.Dispatcher

    .EXAMPLE
        Set-SEBUIStatus -StatusBar $statusBarRefs -Message "Backup failed!" -Type "Error" -Dispatcher $Window.Dispatcher

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$StatusBar,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Type = 'Info',

        [Parameter(Mandatory)]
        [object]$Dispatcher
    )

    # Determine the indicator color based on type
    $colorMap = @{
        'Info'    = '#5B9BD5'  # Blue
        'Success' = '#6BCB77'  # Green
        'Warning' = '#FFD93D'  # Yellow
        'Error'   = '#FF6B6B'  # Red
    }

    $indicatorColor = $colorMap[$Type]
    $timeString = [datetime]::Now.ToString('HH:mm:ss')

    # Reference the status bar elements from the hashtable
    $indicator = $StatusBar.Indicator
    $textBlock = $StatusBar.Text
    $timeBlock = $StatusBar.Time

    Update-SEBUIElement -Dispatcher $Dispatcher -Action {
        if ($indicator) {
            $indicator.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($indicatorColor)
        }
        if ($textBlock) {
            $textBlock.Text = $Message
        }
        if ($timeBlock) {
            $timeBlock.Text = $timeString
        }
    }.GetNewClosure()
}

function Show-SEBUINotification {
    <#
    .SYNOPSIS
        Shows a WPF MessageBox notification with an appropriate icon.

    .DESCRIPTION
        Displays a modal MessageBox dialog to the user with the specified title,
        message, and icon style. This function can be called from any thread as
        it uses Dispatcher.Invoke() when a Dispatcher is provided, or falls back
        to a direct MessageBox call when on the UI thread.

    .PARAMETER Title
        The title text for the MessageBox dialog.

    .PARAMETER Message
        The body message text to display in the MessageBox.

    .PARAMETER Type
        The notification type, which determines the MessageBox icon:
        - "Info"    : Information icon (default)
        - "Warning" : Warning icon
        - "Error"   : Error icon

    .PARAMETER Dispatcher
        Optional WPF Dispatcher for thread-safe invocation. If not provided,
        the MessageBox is shown directly (assumes the caller is on the UI thread).

    .EXAMPLE
        Show-SEBUINotification -Title "Backup Complete" -Message "PvPArena backup finished successfully." -Type "Info"

    .EXAMPLE
        Show-SEBUINotification -Title "Error" -Message "Backup failed: connection timeout" -Type "Error" -Dispatcher $Window.Dispatcher

    .OUTPUTS
        System.Windows.MessageBoxResult
        The result of the MessageBox dialog (OK, Cancel, etc.).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Type = 'Info',

        [Parameter()]
        [object]$Dispatcher
    )

    # Map notification type to MessageBox icon
    $iconMap = @{
        'Info'    = [System.Windows.MessageBoxImage]::Information
        'Warning' = [System.Windows.MessageBoxImage]::Warning
        'Error'   = [System.Windows.MessageBoxImage]::Error
    }
    $icon = $iconMap[$Type]

    $showAction = {
        [System.Windows.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.MessageBoxButton]::OK,
            $icon
        )
    }

    if ($Dispatcher) {
        try {
            $result = $null
            Update-SEBUIElement -Dispatcher $Dispatcher -Action {
                $script:_notifyResult = & $showAction
            }.GetNewClosure()
            return $script:_notifyResult
        }
        catch {
            Write-Warning "Show-SEBUINotification: Failed to show notification via Dispatcher: $_"
        }
    }
    else {
        # Assume we are on the UI thread
        return & $showAction
    }
}

function Show-SEBUIConfirmation {
    <#
    .SYNOPSIS
        Shows a Yes/No confirmation dialog and returns the user's choice.

    .DESCRIPTION
        Displays a modal MessageBox with Yes/No buttons. Returns $true if the user
        clicked Yes, $false otherwise. Useful for confirming destructive operations
        like restores or node removal.

    .PARAMETER Title
        The title text for the confirmation dialog.

    .PARAMETER Message
        The question or confirmation message to display.

    .PARAMETER Type
        The dialog type, which determines the icon:
        - "Info"    : Information icon (default)
        - "Warning" : Warning icon

    .EXAMPLE
        $confirmed = Show-SEBUIConfirmation -Title "Remove Node" -Message "Are you sure you want to remove 'GameServer01'?"
        if ($confirmed) { Remove-NodeConfig ... }

    .OUTPUTS
        System.Boolean
        $true if the user clicked Yes, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Warning')]
        [string]$Type = 'Warning'
    )

    $iconMap = @{
        'Info'    = [System.Windows.MessageBoxImage]::Question
        'Warning' = [System.Windows.MessageBoxImage]::Warning
    }
    $icon = $iconMap[$Type]

    $result = [System.Windows.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::YesNo,
        $icon
    )

    return ($result -eq [System.Windows.MessageBoxResult]::Yes)
}
