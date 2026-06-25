function New-SEBSession {
    <#
    .SYNOPSIS
        Creates or retrieves a cached PSSession to a remote SEBackup node.

    .DESCRIPTION
        Establishes a new PowerShell remoting session (PSSession) to the specified
        node using stored DPAPI-encrypted credentials from the CredentialManager
        module. Sessions are cached in a module-scoped hashtable keyed by NodeName.

        If a cached session already exists for the node and is still ALIVE
        (State=Opened and Availability != None, per Test-SEBSessionAlive), the
        existing session is returned instead of creating a new one. A session that
        is Busy because another caller is mid-command on the shared per-node handle
        still counts as alive and is reused -- it is NOT torn down.

        If a cached session exists but is dead (Broken, Closed, Disconnected, or
        otherwise not in the Opened state), it is removed and a fresh session is
        created.

        When a NodeConfig-less (re)create is required, the ComputerName falls back
        to the host this node last successfully connected to (remembered in a
        module-scoped map), NOT the bare friendly alias, so a reconnect after a
        cache miss/death still targets the pinned hostname/IP.

        The session is configured with appropriate timeouts for long-running
        backup operations:
        - OperationTimeout: 5 minutes (300,000 ms)
        - IdleTimeout: 30 minutes (1,800,000 ms)
        - OpenTimeout: 30 seconds (30,000 ms)

    .PARAMETER NodeName
        The name of the remote node to connect to. This is used both as the
        ComputerName for the PSSession and as the key for credential lookup.

    .PARAMETER NodeConfig
        An optional hashtable containing node configuration. If provided, the
        'hostname' key is used as the ComputerName instead of NodeName. This
        allows the NodeName to be a friendly alias while connecting to the
        actual hostname or IP address.

        If omitted, the ComputerName resolves to the host this node last
        successfully connected to (remembered across calls), or NodeName if the
        node has never been connected before. Callers that already hold the node
        config should keep passing it; the remembered-host fallback is the safety
        net for refresh/reconnect sites that do not have it.

        Expected keys:
        - hostname: The actual hostname or IP address to connect to.

    .EXAMPLE
        $session = New-SEBSession -NodeName "GameServer01"
        Invoke-Command -Session $session -ScriptBlock { Get-Process }
        # Creates a session using stored credentials and executes a remote command.

    .EXAMPLE
        $config = @{ hostname = "192.168.1.100" }
        $session = New-SEBSession -NodeName "GameServer01" -NodeConfig $config
        # Connects to the IP address while using "GameServer01" as the credential lookup key.

    .EXAMPLE
        $session = New-SEBSession -NodeName "GameServer01"
        $session2 = New-SEBSession -NodeName "GameServer01"
        $session -eq $session2  # True -- returns the cached session.

    .OUTPUTS
        System.Management.Automation.Runspaces.PSSession
        An open PSSession to the remote node.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Runspaces.PSSession])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter(Position = 1)]
        [hashtable]$NodeConfig
    )

    # Check for a cached session that is still ALIVE. Reuse is decided by
    # Test-SEBSessionAlive (State=Opened AND Availability != None), NOT by
    # Test-SEBSessionUsable: a cached session that is Busy because ANOTHER caller is
    # mid-command on the shared per-node handle is still alive and must NOT be torn
    # down and rebuilt (that would abort the in-flight command and re-key the cache
    # under a fresh connection). We only remove + recreate when the entry is genuinely
    # dead/never-opened. The narrower "can accept a command NOW" question
    # (Test-SEBSessionUsable) is the wrapper's concern, not session creation's.
    if ($script:SEBSessions.ContainsKey($NodeName)) {
        $existingSession = $script:SEBSessions[$NodeName]
        if (Test-SEBSessionAlive -Session $existingSession) {
            Write-Verbose "Returning cached session for node '$NodeName' (ID: $($existingSession.Id), Availability=$($existingSession.Availability))"
            return $existingSession
        }
        else {
            Write-Verbose "Cached session for node '$NodeName' is not alive (State=$($existingSession.State), Availability=$($existingSession.Availability)). Removing and creating a new session."
            try { Remove-PSSession -Session $existingSession -ErrorAction SilentlyContinue } catch {}
            $script:SEBSessions.Remove($NodeName)
        }
    }

    # Determine the target computer name. Precedence:
    #   1. -NodeConfig.hostname (the caller passed the pinned host explicitly).
    #   2. The host this node last successfully connected to ($script:SEBSessionHosts) --
    #      the safety net so a NodeConfig-less (re)create never silently reconnects to the
    #      bare friendly alias. alias != hostname is the documented standard deployment;
    #      connecting to the alias could fail to resolve or, worse, resolve to a DIFFERENT
    #      machine and present this node's stored credential there.
    #   3. The NodeName itself (no NodeConfig, and this node was never connected before).
    $computerName = $NodeName
    if ($NodeConfig -and $NodeConfig.ContainsKey('hostname')) {
        $computerName = $NodeConfig['hostname']
        Write-Verbose "Using hostname '$computerName' from node configuration for '$NodeName'."
    }
    elseif ($script:SEBSessionHosts.ContainsKey($NodeName)) {
        $computerName = $script:SEBSessionHosts[$NodeName]
        Write-Verbose "No NodeConfig supplied; reusing pinned host '$computerName' for '$NodeName' from the session-host map."
    }

    # Retrieve stored credentials
    $credential = Get-SEBCredential -NodeName $NodeName

    # Configure session options for long-running backup operations
    $sessionOption = New-PSSessionOption `
        -OperationTimeout  300000  `
        -IdleTimeout      1800000  `
        -OpenTimeout        30000  `
        -NoMachineProfile

    try {
        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Creating PSSession to node '$NodeName' ($computerName)" -Level INFO
        }

        $session = New-PSSession `
            -ComputerName  $computerName `
            -Credential    $credential `
            -SessionOption $sessionOption `
            -Name          "SEBackup-$NodeName" `
            -ErrorAction   Stop

        $script:SEBSessions[$NodeName] = $session
        # Pin the resolved connection target so a later NodeConfig-less (re)create for this
        # node reuses the real host instead of the bare alias (see the precedence note above).
        $script:SEBSessionHosts[$NodeName] = $computerName
        Write-Verbose "PSSession created for node '$NodeName' (ID: $($session.Id), ComputerName: $computerName)"

        return $session
    }
    catch {
        throw "Failed to create PSSession to node '$NodeName' ($computerName): $_"
    }
}
