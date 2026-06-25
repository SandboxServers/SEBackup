function Copy-SEBThrottled {
    <#
    .SYNOPSIS
        Copies files from source to destination with bandwidth throttling.

    .DESCRIPTION
        The primary copy function for the SEBackup system that respects bandwidth limits.
        It selects the best available transfer method based on the environment and parameters:

        1. If -UseBITS is specified and the BITS service is available, uses Start-BitsTransfer
           with -Priority Low for bandwidth-friendly background transfers.
        2. Else if robocopy is available and an IPG value is configured (or derived from
           MaxBandwidthMbps), uses robocopy with the /IPG switch for inter-packet gap throttling.
        3. Else falls back to Copy-Item with no throttling, logging a warning that bandwidth
           limits could not be enforced.

        Returns a result object containing transfer statistics: source path, destination path,
        size transferred, duration, average throughput, and the method used.

    .PARAMETER Source
        The source file or directory path to copy from. Supports local paths and UNC paths.

    .PARAMETER Destination
        The destination file or directory path to copy to. Supports local paths and UNC paths.

    .PARAMETER MaxBandwidthMbps
        The maximum bandwidth to use for the transfer, in megabits per second. This is
        typically sourced from the global configuration (network.max_bandwidth_mbps).
        When using robocopy, this value is converted to an /IPG value. A value of 0
        disables throttling. Defaults to 0.

    .PARAMETER RobocopyIpgMs
        An explicit inter-packet gap value in milliseconds for robocopy's /IPG switch.
        When specified, this takes precedence over the value computed from MaxBandwidthMbps.
        Sourced from global configuration (network.robocopy_ipg_ms). Defaults to 0.

    .PARAMETER UseBITS
        When specified, the function prefers BITS (Background Intelligent Transfer Service)
        for the transfer. BITS provides built-in bandwidth throttling and is ideal for
        large transfers over network paths. Falls back to robocopy or Copy-Item if BITS
        is not available.

    .PARAMETER Credential
        An optional PSCredential object for authenticating to UNC paths. Passed through
        to the underlying transfer mechanism when needed.

    .EXAMPLE
        Copy-SEBThrottled -Source "C:\Backup\archive.7z" -Destination "\\NAS\Backups\" -UseBITS

    .EXAMPLE
        Copy-SEBThrottled -Source "C:\Backup\archive.7z" -Destination "\\NAS\Backups\" -MaxBandwidthMbps 50

    .EXAMPLE
        $cred = Get-SEBCredential -Name "NAS"
        Copy-SEBThrottled -Source "C:\Temp\data.zip" -Destination "\\FileServer\Share\" -Credential $cred -MaxBandwidthMbps 10

    .OUTPUTS
        PSCustomObject
        An object with properties: Source, Destination, SizeBytes, DurationSeconds, AverageMbps, Method.

    .LINK
        Start-SEBBitsTransfer
        Get-SEBTransferStatus
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Source,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [Parameter()]
        [int]$MaxBandwidthMbps = 0,

        [Parameter()]
        [int]$RobocopyIpgMs = 0,

        [Parameter()]
        [switch]$UseBITS,

        [Parameter()]
        [PSCredential]$Credential
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $method = 'Unknown'
    $sizeBytes = 0

    # Determine source size for reporting
    try {
        if (Test-Path -Path $Source -PathType Leaf) {
            $sizeBytes = (Get-Item -Path $Source -ErrorAction Stop).Length
        }
        elseif (Test-Path -Path $Source -PathType Container) {
            $sizeBytes = (Get-ChildItem -Path $Source -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            if ($null -eq $sizeBytes) { $sizeBytes = 0 }
        }
    }
    catch {
        Write-Verbose "Could not determine source size: $_"
    }

    try {
        # Strategy 1: BITS transfer
        if ($UseBITS -and (Test-BITSAvailable)) {
            Write-Verbose "Using BITS transfer for '$Source' -> '$Destination'"
            $method = 'BITS'

            $bitsParams = @{
                Source      = $Source
                Destination = $Destination
                Priority    = 'Low'
            }
            if ($Credential) {
                $bitsParams['Credential'] = $Credential
            }

            Start-SEBBitsTransfer @bitsParams
        }
        # Strategy 2: Robocopy with /IPG
        elseif ((Get-Command -Name 'robocopy' -ErrorAction SilentlyContinue)) {
            # Determine effective IPG value
            $effectiveIpg = $RobocopyIpgMs
            if ($effectiveIpg -le 0 -and $MaxBandwidthMbps -gt 0) {
                $effectiveIpg = ConvertTo-RobocopyIpg -MaxBandwidthMbps $MaxBandwidthMbps
            }

            if ($effectiveIpg -gt 0) {
                Write-Verbose "Using robocopy with /IPG:$effectiveIpg for '$Source' -> '$Destination'"
                $method = 'Robocopy'

                # Robocopy requires source dir and destination dir for directory copies,
                # or source dir + file pattern for single files
                if (Test-Path -Path $Source -PathType Leaf) {
                    # Robocopy's second argument is the destination DIRECTORY, not a file path.
                    # Passing a file path made robocopy create a directory by that name and copy
                    # the file inside it. Resolve the destination directory robustly: -Destination
                    # may be a directory, a full file path, or a bare filename (GetDirectoryName
                    # returns '' ) -- fall back to the current location so we never hand New-Item
                    # or robocopy an empty path.
                    $sourceDir = [System.IO.Path]::GetDirectoryName($Source)
                    $sourceFile = [System.IO.Path]::GetFileName($Source)
                    $destDir = Resolve-DestinationDirectory -Destination $Destination
                    if (-not (Test-Path -Path $destDir -PathType Container)) {
                        New-Item -Path $destDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    }
                    $robocopyArgs = @($sourceDir, $destDir, $sourceFile, "/IPG:$effectiveIpg", '/R:3', '/W:5', '/NP', '/NDL', '/NJH', '/NJS')
                }
                else {
                    $robocopyArgs = @($Source, $Destination, '/E', "/IPG:$effectiveIpg", '/R:3', '/W:5', '/NP', '/NDL', '/NJH', '/NJS')
                }

                $robocopyResult = & robocopy @robocopyArgs 2>&1
                # Robocopy exit codes 0-7 are success/partial, 8+ are errors
                if ($LASTEXITCODE -ge 8) {
                    $errorOutput = $robocopyResult -join "`n"
                    throw "Robocopy failed with exit code $LASTEXITCODE. Output: $errorOutput"
                }
            }
            else {
                # Robocopy available but no throttling configured - use robocopy anyway for reliability
                Write-Verbose "Using robocopy (no throttling) for '$Source' -> '$Destination'"
                $method = 'Robocopy'

                if (Test-Path -Path $Source -PathType Leaf) {
                    # Robocopy's second argument is the destination DIRECTORY, not a file path.
                    $sourceDir = [System.IO.Path]::GetDirectoryName($Source)
                    $sourceFile = [System.IO.Path]::GetFileName($Source)
                    $destDir = Resolve-DestinationDirectory -Destination $Destination
                    if (-not (Test-Path -Path $destDir -PathType Container)) {
                        New-Item -Path $destDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    }
                    $robocopyArgs = @($sourceDir, $destDir, $sourceFile, '/R:3', '/W:5', '/NP', '/NDL', '/NJH', '/NJS')
                }
                else {
                    $robocopyArgs = @($Source, $Destination, '/E', '/R:3', '/W:5', '/NP', '/NDL', '/NJH', '/NJS')
                }

                $robocopyResult = & robocopy @robocopyArgs 2>&1
                if ($LASTEXITCODE -ge 8) {
                    $errorOutput = $robocopyResult -join "`n"
                    throw "Robocopy failed with exit code $LASTEXITCODE. Output: $errorOutput"
                }
            }
        }
        # Strategy 3: Copy-Item fallback (no throttling)
        else {
            Write-Warning "Neither BITS nor robocopy available. Falling back to Copy-Item with no bandwidth throttling."
            $method = 'CopyItem'

            $copyParams = @{
                Path        = $Source
                Destination = $Destination
                Force       = $true
                ErrorAction = 'Stop'
            }
            if (Test-Path -Path $Source -PathType Container) {
                $copyParams['Recurse'] = $true
            }
            if ($Credential) {
                # Copy-Item supports -Credential for some providers
                $copyParams['Credential'] = $Credential
            }

            Copy-Item @copyParams
        }
    }
    catch {
        $stopwatch.Stop()
        Write-Error "Copy-SEBThrottled failed: $_"
        throw
    }

    $stopwatch.Stop()

    # Robocopy copies a leaf into a directory keeping the source filename. If the requested
    # Destination filename differs, move it into place; then verify the file actually landed
    # (robocopy can report a success-ish exit code while leaving nothing at the expected path).
    if ($method -eq 'Robocopy' -and (Test-Path -Path $Source -PathType Leaf)) {
        # Resolve where robocopy actually placed the file (always <destDir>\<sourceName>) and the
        # final expected path. When -Destination is a directory the file keeps its source name
        # there; otherwise -Destination is the full target path and the landed file may need to
        # be renamed into place.
        $destDir = Resolve-DestinationDirectory -Destination $Destination
        $expectedDest = if ((Test-Path -Path $Destination -PathType Container) -or
            $Destination.EndsWith([System.IO.Path]::DirectorySeparatorChar) -or
            $Destination.EndsWith([System.IO.Path]::AltDirectorySeparatorChar)) {
            Join-Path -Path $destDir -ChildPath ([System.IO.Path]::GetFileName($Source))
        }
        else {
            $Destination
        }

        # Compare fully-resolved paths: for a bare destination like 'backup.zip', $expectedDest is
        # relative while $landed is rooted via $destDir, so a string compare could try to move the
        # file onto itself. Use -LiteralPath so names with [ ] are not treated as wildcards.
        $landed = Join-Path -Path $destDir -ChildPath ([System.IO.Path]::GetFileName($Source))
        $landedFull = [System.IO.Path]::GetFullPath($landed)
        $expectedFull = [System.IO.Path]::GetFullPath($expectedDest)
        if ($landedFull -ne $expectedFull -and (Test-Path -LiteralPath $landed -PathType Leaf)) {
            Move-Item -LiteralPath $landed -Destination $expectedDest -Force -ErrorAction Stop
        }
        if (-not (Test-Path -LiteralPath $expectedDest -PathType Leaf)) {
            throw "Throttled copy did not produce the destination file '$expectedDest'."
        }
    }

    $durationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)

    # Calculate average throughput in Mbps
    $averageMbps = 0.0
    if ($durationSeconds -gt 0 -and $sizeBytes -gt 0) {
        $averageMbps = [math]::Round(($sizeBytes * 8) / ($durationSeconds * 1000000), 2)
    }

    return [PSCustomObject]@{
        Source          = $Source
        Destination     = $Destination
        SizeBytes       = $sizeBytes
        DurationSeconds = $durationSeconds
        AverageMbps     = $averageMbps
        Method          = $method
    }
}
