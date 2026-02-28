function Invoke-SEBBackupAll {
    <#
    .SYNOPSIS
        Backs up all Space Engineers Torch server instances across all configured nodes.

    .DESCRIPTION
        Iterates all node configuration files from Config/nodes/*.toml, discovers
        all instances on each node via Get-SEBAllInstanceConfigs, and runs
        Invoke-SEBBackup for each instance.

        By default, all nodes and instances are processed sequentially. When the
        -ParallelNodes switch is specified, nodes are processed in parallel using
        ForEach-Object -Parallel, while instances within each node are still
        processed serially to avoid resource contention.

        Returns an array of result objects from each Invoke-SEBBackup call.

    .PARAMETER SkipLoadCheck
        Skips the load awareness check for all instances.

    .PARAMETER SkipNotify
        Skips sending individual Discord notifications for each instance.

    .PARAMETER ParallelNodes
        Processes nodes in parallel. Instances within each node are still
        processed serially to avoid concurrent backup operations on the same
        machine.

    .EXAMPLE
        $results = Invoke-SEBBackupAll
        $results | Where-Object { -not $_.Success } | ForEach-Object {
            Write-Error "Failed: $($_.InstanceName) on $($_.NodeName): $($_.ErrorMessage)"
        }

    .EXAMPLE
        $results = Invoke-SEBBackupAll -ParallelNodes -SkipLoadCheck

    .EXAMPLE
        $results = Invoke-SEBBackupAll -SkipNotify
        Write-Host "$($results.Count) instance(s) processed, $(@($results | Where-Object Success).Count) succeeded."

    .OUTPUTS
        PSCustomObject[]
        An array of backup result objects, one per instance.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [switch]$SkipLoadCheck,

        [Parameter()]
        [switch]$SkipNotify,

        [Parameter()]
        [switch]$ParallelNodes
    )

    $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue
    $allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($hasLogger) {
        Write-SEBLog -Message '=== Starting backup-all operation ===' -Level INFO
    }

    # Load all node configs
    $nodeConfigs = Get-SEBNodeConfig -All
    if (-not $nodeConfigs -or $nodeConfigs.Count -eq 0) {
        if ($hasLogger) {
            Write-SEBLog -Message 'No node configurations found. Nothing to back up.' -Level WARN
        }
        Write-Warning 'No node configurations found in Config/nodes/. Nothing to back up.'
        return @()
    }

    if ($hasLogger) {
        Write-SEBLog -Message "Found $($nodeConfigs.Count) node(s) to process." -Level INFO
    }

    # Build the work items: each is a node with its discovered instances
    $workItems = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($nodeConfig in $nodeConfigs) {
        $nodeName = $nodeConfig['_NodeName']
        try {
            $session = New-SEBSession -NodeName $nodeName -NodeConfig ($nodeConfig.ContainsKey('node') ? $nodeConfig['node'] : $nodeConfig)
            $instances = Get-SEBAllInstanceConfigs -Session $session

            if (-not $instances -or $instances.Count -eq 0) {
                if ($hasLogger) {
                    Write-SEBLog -Message "No instances found on node '$nodeName'. Skipping." -Level INFO
                }
                continue
            }

            foreach ($inst in $instances) {
                $workItems.Add(@{
                    NodeName     = $nodeName
                    InstanceName = $inst['_InstanceName']
                })
            }

            if ($hasLogger) {
                Write-SEBLog -Message "Node '$nodeName': discovered $($instances.Count) instance(s)." -Level INFO
            }
        }
        catch {
            if ($hasLogger) {
                Write-SEBLog -Message "Failed to discover instances on node '$nodeName': $_" -Level ERROR
            }
            Write-Error "Failed to discover instances on node '$nodeName': $_"

            # Add a failure result for this node
            $allResults.Add([PSCustomObject]@{
                Success          = $false
                InstanceName     = '*'
                NodeName         = $nodeName
                BackupType       = $null
                ArchiveFile      = $null
                ArchiveSizeBytes = 0
                FileCount        = 0
                Duration         = $null
                ManifestFile     = $null
                ChainId          = $null
                ChainSequence    = 0
                IntegrityPassed  = $false
                Warnings         = @()
                ErrorMessage     = "Failed to discover instances on node: $_"
            })
        }
    }

    if ($workItems.Count -eq 0) {
        if ($hasLogger) {
            Write-SEBLog -Message 'No instances discovered across any nodes. Nothing to back up.' -Level WARN
        }
        Write-Warning 'No instances discovered across any nodes.'
        return $allResults.ToArray()
    }

    if ($hasLogger) {
        Write-SEBLog -Message "Total instances to back up: $($workItems.Count)" -Level INFO
    }

    if ($ParallelNodes) {
        # Group work items by node
        $nodeGroups = $workItems | Group-Object -Property { $_.NodeName }

        $parallelResults = $nodeGroups | ForEach-Object -Parallel {
            $nodeGroup = $_
            $nodeName = $nodeGroup.Name
            $nodeResults = [System.Collections.Generic.List[PSCustomObject]]::new()

            # Process instances on this node serially
            foreach ($workItem in $nodeGroup.Group) {
                try {
                    $backupParams = @{
                        NodeName     = $workItem.NodeName
                        InstanceName = $workItem.InstanceName
                    }
                    if ($using:SkipLoadCheck) { $backupParams['SkipLoadCheck'] = $true }
                    if ($using:SkipNotify)    { $backupParams['SkipNotify']    = $true }

                    $backupResult = Invoke-SEBBackup @backupParams
                    $nodeResults.Add($backupResult)
                }
                catch {
                    $nodeResults.Add([PSCustomObject]@{
                        Success          = $false
                        InstanceName     = $workItem.InstanceName
                        NodeName         = $workItem.NodeName
                        BackupType       = $null
                        ArchiveFile      = $null
                        ArchiveSizeBytes = 0
                        FileCount        = 0
                        Duration         = $null
                        ManifestFile     = $null
                        ChainId          = $null
                        ChainSequence    = 0
                        IntegrityPassed  = $false
                        Warnings         = @()
                        ErrorMessage     = "Unhandled error: $_"
                    })
                }
            }

            $nodeResults.ToArray()
        } -ThrottleLimit ([Math]::Max($nodeGroups.Count, 1))

        foreach ($r in $parallelResults) {
            if ($r -is [array]) {
                foreach ($item in $r) { $allResults.Add($item) }
            }
            else {
                $allResults.Add($r)
            }
        }
    }
    else {
        # Sequential processing
        foreach ($workItem in $workItems) {
            try {
                $backupParams = @{
                    NodeName     = $workItem.NodeName
                    InstanceName = $workItem.InstanceName
                }
                if ($SkipLoadCheck) { $backupParams['SkipLoadCheck'] = $true }
                if ($SkipNotify)    { $backupParams['SkipNotify']    = $true }

                $backupResult = Invoke-SEBBackup @backupParams
                $allResults.Add($backupResult)
            }
            catch {
                $allResults.Add([PSCustomObject]@{
                    Success          = $false
                    InstanceName     = $workItem.InstanceName
                    NodeName         = $workItem.NodeName
                    BackupType       = $null
                    ArchiveFile      = $null
                    ArchiveSizeBytes = 0
                    FileCount        = 0
                    Duration         = $null
                    ManifestFile     = $null
                    ChainId          = $null
                    ChainSequence    = 0
                    IntegrityPassed  = $false
                    Warnings         = @()
                    ErrorMessage     = "Unhandled error: $_"
                })
            }
        }
    }

    # Summary
    $successCount = @($allResults | Where-Object { $_.Success }).Count
    $failCount = $allResults.Count - $successCount

    if ($hasLogger) {
        Write-SEBLog -Message "=== Backup-all complete: $successCount/$($allResults.Count) succeeded, $failCount failed ===" -Level $(if ($failCount -gt 0) { 'WARN' } else { 'INFO' })
    }

    return $allResults.ToArray()
}
