function Compress-SEBArchive {
    <#
    .SYNOPSIS
        Compresses files or directories into a backup archive using 7-Zip or .NET.

    .DESCRIPTION
        Creates a compressed archive from the specified source path(s). Supports two
        compression engines:

        - 7zip:  Uses 7z.exe to create a .7z archive with configurable compression
                 level. Preferred for large Space Engineers save files due to superior
                 compression ratios and speed.
        - dotnet: Uses the built-in Compress-Archive cmdlet to create a .zip archive.
                  Always available as a fallback.

        When Engine is "auto" (the default), the function checks for 7-Zip availability
        and uses it if found, otherwise falls back to .NET compression.

        Compression runs on the remote node via Invoke-Command when a PSSession is
        provided, keeping all I/O local to the node and avoiding network transfer
        of uncompressed data.

    .PARAMETER SourcePath
        One or more paths (files or directories) to include in the archive. When used
        with -Session, these paths must be valid on the remote node.

    .PARAMETER DestinationPath
        The full path for the output archive file. The file extension should match
        the engine: .7z for 7-Zip, .zip for .NET. The parent directory must exist.

    .PARAMETER CompressionLevel
        The compression level from 1 (fastest, least compression) to 9 (slowest,
        best compression). Maps to 7-Zip's -mx switch. For .NET, levels 1-3 map to
        Fastest, 4-6 to Optimal, and 7-9 to SmallestSize (PowerShell 7.4+) or
        Optimal. Defaults to 5 if not specified.

    .PARAMETER Engine
        The compression engine to use: "auto" (default), "7zip", or "dotnet".
        When "auto", 7-Zip is used if available, otherwise falls back to .NET.

    .PARAMETER Session
        An optional PSSession to a remote node. When specified, the compression runs
        entirely on the remote machine.

    .EXAMPLE
        Compress-SEBArchive -SourcePath "E:\Shadow\Instance1" -DestinationPath "D:\Backups\backup.7z" -Session $session

    .EXAMPLE
        Compress-SEBArchive -SourcePath @("E:\Save\Sandbox.sbc", "E:\Save\YOURWORLD") `
            -DestinationPath "D:\Backups\backup.zip" -Engine "dotnet" -CompressionLevel 3

    .OUTPUTS
        PSCustomObject
        An object with properties: ArchivePath, SizeBytes, Engine, Duration.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string[]]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter()]
        [ValidateRange(1, 9)]
        [int]$CompressionLevel = 5,

        [Parameter()]
        [ValidateSet('auto', '7zip', 'dotnet')]
        [string]$Engine = 'auto',

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    # Resolve the engine to use
    $resolvedEngine = $Engine
    if ($resolvedEngine -eq 'auto') {
        $engineInfo = Get-SEBCompressionEngine -Session $Session
        $resolvedEngine = $engineInfo.Engine
        Write-Verbose "Auto-detected compression engine: $resolvedEngine."
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($resolvedEngine -eq '7zip') {
        $compressScript = {
            param(
                [string[]]$Sources,
                [string]$Destination,
                [int]$Level
            )

            # Find 7z.exe
            $sevenZip = $null
            $candidates = @(
                (Join-Path -Path $env:ProgramFiles -ChildPath '7-Zip\7z.exe')
                (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath '7-Zip\7z.exe')
            )
            foreach ($c in $candidates) {
                if ($c -and (Test-Path -Path $c -PathType Leaf)) {
                    $sevenZip = $c
                    break
                }
            }
            if (-not $sevenZip) {
                $cmd = Get-Command -Name '7z.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($cmd) { $sevenZip = $cmd.Source }
            }
            if (-not $sevenZip) {
                throw '7z.exe not found on the remote node.'
            }

            # Build argument list
            $args7z = @('a', '-t7z', "-mx=$Level", $Destination)
            $args7z += $Sources

            $process = Start-Process -FilePath $sevenZip -ArgumentList $args7z `
                -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\seb_7z_out.txt" `
                -RedirectStandardError "$env:TEMP\seb_7z_err.txt"

            $stdout = if (Test-Path "$env:TEMP\seb_7z_out.txt") { Get-Content "$env:TEMP\seb_7z_out.txt" -Raw } else { '' }
            $stderr = if (Test-Path "$env:TEMP\seb_7z_err.txt") { Get-Content "$env:TEMP\seb_7z_err.txt" -Raw } else { '' }

            # Clean up temp files
            Remove-Item -Path "$env:TEMP\seb_7z_out.txt", "$env:TEMP\seb_7z_err.txt" -Force -ErrorAction SilentlyContinue

            if ($process.ExitCode -ne 0) {
                throw "7-Zip compression failed (exit code $($process.ExitCode)). Stderr: $stderr"
            }

            # Return archive size
            $archiveInfo = Get-Item -Path $Destination -ErrorAction Stop
            return @{
                SizeBytes = $archiveInfo.Length
            }
        }

        if ($Session) {
            $result = Invoke-Command -Session $Session -ScriptBlock $compressScript `
                -ArgumentList @(, $SourcePath), $DestinationPath, $CompressionLevel -ErrorAction Stop
        }
        else {
            $result = & $compressScript -Sources $SourcePath -Destination $DestinationPath -Level $CompressionLevel
        }
    }
    else {
        # .NET / Compress-Archive engine
        $compressScript = {
            param(
                [string[]]$Sources,
                [string]$Destination,
                [int]$Level
            )

            # Map numeric level to .NET CompressionLevel
            if ($Level -le 3) {
                $dotnetLevel = 'Fastest'
            }
            elseif ($Level -le 6) {
                $dotnetLevel = 'Optimal'
            }
            else {
                # PowerShell 7.4+ supports SmallestSize; fall back to Optimal
                $dotnetLevel = 'Optimal'
                try {
                    [System.IO.Compression.CompressionLevel]::SmallestSize | Out-Null
                    $dotnetLevel = 'SmallestSize'
                }
                catch {
                    # SmallestSize not available in this runtime
                }
            }

            Compress-Archive -Path $Sources -DestinationPath $Destination `
                -CompressionLevel $dotnetLevel -Force -ErrorAction Stop

            $archiveInfo = Get-Item -Path $Destination -ErrorAction Stop
            return @{
                SizeBytes = $archiveInfo.Length
            }
        }

        if ($Session) {
            $result = Invoke-Command -Session $Session -ScriptBlock $compressScript `
                -ArgumentList @(, $SourcePath), $DestinationPath, $CompressionLevel -ErrorAction Stop
        }
        else {
            $result = & $compressScript -Sources $SourcePath -Destination $DestinationPath -Level $CompressionLevel
        }
    }

    $stopwatch.Stop()

    $output = [PSCustomObject]@{
        ArchivePath = $DestinationPath
        SizeBytes   = $result.SizeBytes
        Engine      = $resolvedEngine
        Duration    = $stopwatch.Elapsed
    }

    Write-Verbose "Compression complete: engine=$resolvedEngine, size=$($result.SizeBytes) bytes, duration=$($stopwatch.Elapsed)."

    return $output
}
