function Expand-SEBArchive {
    <#
    .SYNOPSIS
        Extracts a backup archive to a destination directory using 7-Zip or .NET.

    .DESCRIPTION
        Extracts the contents of an archive file to the specified destination path.
        Auto-detects the appropriate compression engine based on file extension:

        - .7z files are extracted using 7-Zip (7z.exe)
        - .zip files are extracted using the built-in Expand-Archive cmdlet

        The Engine parameter can override auto-detection. When a PSSession is provided,
        extraction runs entirely on the remote node.

        Creates the destination directory if it does not exist. Uses the -y flag with
        7-Zip to automatically overwrite existing files during extraction.

        Zip-slip containment: before any file is written, every archive entry is resolved against
        the destination root and rejected if it would land outside that root (a '..' traversal or
        a rooted/absolute entry). The extraction aborts -- and removes a freshly created
        destination directory -- rather than writing a single escaping entry. This guards the
        production node against arbitrary-write via a crafted or manifest-supplied archive. The
        check runs in the same (local or remote) runspace as the extraction itself.

    .PARAMETER ArchivePath
        The full path to the archive file to extract. Must exist on the target system
        (local or remote depending on Session parameter).

    .PARAMETER DestinationPath
        The directory to extract the archive contents into. Will be created if it
        does not exist.

    .PARAMETER Engine
        The compression engine to use for extraction: "auto" (default), "7zip", or
        "dotnet". When "auto", the engine is chosen based on the archive file extension.

    .PARAMETER Session
        An optional PSSession to a remote node. When specified, extraction runs on
        the remote machine.

    .EXAMPLE
        Expand-SEBArchive -ArchivePath "D:\Backups\backup.7z" -DestinationPath "C:\Restore\Instance1"

    .EXAMPLE
        $session = New-PSSession -ComputerName "GameNode01"
        Expand-SEBArchive -ArchivePath "D:\Backups\backup.zip" -DestinationPath "C:\Restore\Instance1" -Session $session

    .OUTPUTS
        PSCustomObject
        An object with properties: ArchivePath, DestinationPath, Engine, Duration.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$ArchivePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter()]
        [ValidateSet('auto', '7zip', 'dotnet')]
        [string]$Engine = 'auto',

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    # Resolve engine from file extension if auto
    $resolvedEngine = $Engine
    if ($resolvedEngine -eq 'auto') {
        $extension = [System.IO.Path]::GetExtension($ArchivePath).ToLower()
        if ($extension -eq '.7z') {
            $resolvedEngine = '7zip'
        }
        else {
            $resolvedEngine = 'dotnet'
        }
        Write-Verbose "Auto-detected extraction engine '$resolvedEngine' from extension '$extension'."
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($resolvedEngine -eq '7zip') {
        $extractScript = {
            param(
                [string]$Archive,
                [string]$Destination
            )

            # Track whether WE created the destination, so a zip-slip abort can clean up a directory
            # that did not exist before this call (avoid leaving an empty dir behind on rejection).
            # -LiteralPath so a destination containing wildcard metacharacters can't match a
            # DIFFERENT existing directory and wrongly report the dir as pre-existing.
            $destPreexisted = Test-Path -LiteralPath $Destination -PathType Container

            # Create destination if needed
            if (-not $destPreexisted) {
                New-Item -Path $Destination -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

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
                throw '7z.exe not found on the node.'
            }

            # --- Zip-slip containment (pre-extraction) ---
            # 7-Zip's 'x' restores full stored paths, so an entry named '..\evil' or a rooted path
            # would be written OUTSIDE $Destination. List the entries first ('l -slt', the same
            # machine-parseable listing Get-SEBArchiveContents uses) and resolve each against the
            # destination root; if ANY entry escapes, abort BEFORE writing anything.
            $destRoot = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            # The containment prefix comparison must match the filesystem's case sensitivity. On
            # Windows paths are case-insensitive, so an entry differing only in case is the same
            # location and OrdinalIgnoreCase is correct. On a case-sensitive filesystem (Linux),
            # OrdinalIgnoreCase would WRONGLY accept an entry that differs in case from $destRoot
            # yet resolves to a different (escaping) directory -- so use a case-sensitive Ordinal
            # comparison there.
            $cmp = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
            $listOutput = & $sevenZip l -slt $Archive 2>&1
            if ($LASTEXITCODE -ne 0) {
                if (-not $destPreexisted -and (Test-Path -LiteralPath $Destination -PathType Container)) {
                    Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
                }
                throw "7-Zip listing failed (exit code $LASTEXITCODE); cannot verify archive entries before extraction."
            }

            # In '-slt' output the archive's OWN header block (which carries a 'Path = <full archive
            # path>' line) comes BEFORE the '----------' separator; the per-file entry blocks come
            # after it. Only evaluate 'Path =' lines that appear after the separator so the archive's
            # own absolute path is never mistaken for an escaping entry.
            $inEntries = $false
            $offending = $null
            # Fail-closed accounting: if 7-Zip ever emits a listing WITHOUT the '----------' separator,
            # $inEntries would stay false and NO entry path would be checked -- silently handing a
            # traversal archive to '7z x'. Track evidence that the listing described actual file
            # content (a 'Path =' line beyond the archive's own header line, or per-entry 'Size ='/
            # 'Folder =' metadata) so a separator-less listing of a non-empty archive can be detected
            # and aborted below, rather than allowed through.
            $pathLineCount = 0
            $sawEntryMetadata = $false
            foreach ($line in $listOutput) {
                $lineStr = $line.ToString()
                if ($lineStr -match '^Path = (.+)$') { $pathLineCount++ }
                elseif ($lineStr -match '^(Size|Folder) = ') { $sawEntryMetadata = $true }
                if (-not $inEntries) {
                    if ($lineStr -match '^-{5,}\s*$') { $inEntries = $true }
                    continue
                }
                if ($lineStr -match '^Path = (.+)$') {
                    $entryPath = $Matches[1].Trim()
                    # Path.Combine resolves a rooted entry by DISCARDING $Destination, so a rooted
                    # entry lands outside $destRoot and is correctly rejected. '..' segments are
                    # collapsed by GetFullPath, catching traversal. Folder entries are checked too:
                    # a '..' directory entry is just as unsafe to recreate as a file.
                    $resolved = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Destination, $entryPath))
                    if (-not $resolved.StartsWith($destRoot, $cmp)) {
                        $offending = $entryPath
                        break
                    }
                }
            }

            if ($null -ne $offending) {
                if (-not $destPreexisted -and (Test-Path -LiteralPath $Destination -PathType Container)) {
                    Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
                }
                throw "Refusing to extract '$Archive': entry '$offending' would escape the destination '$Destination' (zip-slip/path traversal)."
            }

            # Fail closed on a malformed listing: the parse completed but never reached the entries
            # section ('----------' separator never seen), yet the listing clearly described file
            # content (an entry 'Path =' beyond the archive's own header line, or per-entry Size/Folder
            # metadata). In that case NO entry was containment-checked, so refuse to extract rather
            # than trust an unverified archive -- mirroring the LASTEXITCODE!=0 abort above. An empty
            # archive (only the header 'Path =', no entry metadata) is NOT penalised: there is nothing
            # to extract that could escape.
            if (-not $inEntries -and ($pathLineCount -gt 1 -or $sawEntryMetadata)) {
                if (-not $destPreexisted -and (Test-Path -LiteralPath $Destination -PathType Container)) {
                    Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
                }
                throw "Refusing to extract '$Archive': 7-Zip listing did not delimit its entry section, so archive entries could not be verified for path traversal before extraction."
            }

            $args7z = @('x', $Archive, "-o$Destination", '-y')

            $process = Start-Process -FilePath $sevenZip -ArgumentList $args7z `
                -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\seb_7z_out.txt" `
                -RedirectStandardError "$env:TEMP\seb_7z_err.txt"

            $stderr = if (Test-Path "$env:TEMP\seb_7z_err.txt") { Get-Content "$env:TEMP\seb_7z_err.txt" -Raw } else { '' }

            Remove-Item -Path "$env:TEMP\seb_7z_out.txt", "$env:TEMP\seb_7z_err.txt" -Force -ErrorAction SilentlyContinue

            if ($process.ExitCode -ne 0) {
                throw "7-Zip extraction failed (exit code $($process.ExitCode)). Stderr: $stderr"
            }
        }

        if ($Session) {
            Invoke-Command -Session $Session -ScriptBlock $extractScript `
                -ArgumentList $ArchivePath, $DestinationPath -ErrorAction Stop
        }
        else {
            & $extractScript -Archive $ArchivePath -Destination $DestinationPath
        }
    }
    else {
        # .NET / Expand-Archive engine
        $extractScript = {
            param(
                [string]$Archive,
                [string]$Destination
            )

            # Track whether WE created the destination so a zip-slip abort can clean up a directory
            # that did not exist before this call. -LiteralPath so a destination containing wildcard
            # metacharacters can't match a DIFFERENT existing directory and skew this check.
            $destPreexisted = Test-Path -LiteralPath $Destination -PathType Container

            # Create destination if needed
            if (-not $destPreexisted) {
                New-Item -Path $Destination -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

            # --- Zip-slip containment (pre-extraction) ---
            # Expand-Archive will happily honour a '..' or rooted entry path and write outside
            # $Destination. Enumerate the entries via System.IO.Compression first, resolve each
            # against the destination root, and abort BEFORE writing anything if one escapes.
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $destRoot = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            # Match the filesystem's case sensitivity for the containment prefix check: Windows
            # paths are case-insensitive (OrdinalIgnoreCase), but on a case-sensitive filesystem
            # OrdinalIgnoreCase would wrongly accept a case-differing entry that resolves outside
            # $destRoot, so compare case-sensitively (Ordinal) there.
            $cmp = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
            $offending = $null
            $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
            try {
                foreach ($entry in $zip.Entries) {
                    # A pure directory entry has an empty Name (FullName ends with '/'); it writes no
                    # file by itself, but a '..' directory entry is still suspect, so resolve every
                    # entry uniformly. Path.Combine discards $Destination for a rooted entry (so it
                    # falls outside $destRoot), and GetFullPath collapses '..' traversal.
                    $resolved = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Destination, $entry.FullName))
                    if (-not $resolved.StartsWith($destRoot, $cmp)) {
                        $offending = $entry.FullName
                        break
                    }
                }
            }
            finally {
                $zip.Dispose()
            }

            if ($null -ne $offending) {
                if (-not $destPreexisted -and (Test-Path -LiteralPath $Destination -PathType Container)) {
                    Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
                }
                throw "Refusing to extract '$Archive': entry '$offending' would escape the destination '$Destination' (zip-slip/path traversal)."
            }

            Expand-Archive -Path $Archive -DestinationPath $Destination -Force -ErrorAction Stop
        }

        if ($Session) {
            Invoke-Command -Session $Session -ScriptBlock $extractScript `
                -ArgumentList $ArchivePath, $DestinationPath -ErrorAction Stop
        }
        else {
            & $extractScript -Archive $ArchivePath -Destination $DestinationPath
        }
    }

    $stopwatch.Stop()

    $output = [PSCustomObject]@{
        ArchivePath     = $ArchivePath
        DestinationPath = $DestinationPath
        Engine          = $resolvedEngine
        Duration        = $stopwatch.Elapsed
    }

    Write-Verbose "Extraction complete: engine=$resolvedEngine, duration=$($stopwatch.Elapsed)."

    return $output
}
