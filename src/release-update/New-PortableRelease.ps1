param(
    [string]$SourceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'payload'),
    [string]$DestinationRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'release'),
    [string]$ReleaseParentRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateRange(60, 1800)]
    [int]$LauncherSelfTestTimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$releaseArchiveManifestEntry = 'portable-package-manifest.json'
$releaseDescriptorPath = 'CodexData/portable-release.json'
$githubReleaseAssetMaximumBytes = 2GB - 1
$releaseDescriptorFiles = @(
    'CodexPortable.exe',
    'CodexData/README.txt',
    'CodexData/THIRD_PARTY.txt',
    'CodexData/tools/launchers/CodexPortable.x86.exe',
    'CodexData/tools/launchers/CodexPortable.x64.exe',
    'CodexData/tools/launchers/CodexPortable.arm64.exe',
    'CodexData/packages/LFPortable-common.zip',
    'CodexData/packages/LFPortable-x64.msix',
    'CodexData/packages/LFPortable-arm64.msix'
)
$releaseArchiveCanonicalFiles = @($releaseDescriptorFiles) + @($releaseDescriptorPath)
$officialMsixIdentityName = 'OpenAI.Codex'
$officialMsixPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$bundledPluginCatalog = 'openai-bundled'
$bundledPluginMsixPrefix = 'app/resources/plugins/openai-bundled/plugins/'
$hydratedBundledPlugins = @('sites', 'deep-research')
$minimumSevenZipVersion = [version]'24.9'
$sevenZipCompressionProfile = 'ZIP Deflate ultra: mx=9, fast-bytes=258, passes=15; precompressed release payloads stored'
$sevenZipUltraArguments = @(
    '-tzip', '-mx=9', '-mm=Deflate', '-mfb=258', '-mpass=15', '-mmt=on', '-scsUTF-8',
    '-mtc=off', '-mta=off', '-mtm=off', '-sns-', '-sse', '-bd', '-bb0', '-bso0', '-bse1', '-bsp0'
)
$sevenZipStoreArguments = @(
    '-tzip', '-mx=0', '-mm=Copy', '-mtc=off', '-mta=off', '-mtm=off', '-sns-',
    '-sse', '-bd', '-bb0', '-bso0', '-bse1', '-bsp0'
)

function Test-PathWithin([string]$candidate, [string]$root) {
    $normalizedCandidate = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
    $normalizedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
    $normalizedCandidate.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $normalizedCandidate.StartsWith($normalizedRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePointInAncestry([string]$path) {
    $current = [IO.Path]::GetFullPath($path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($current).TrimEnd('\')
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Protected release path is or is beneath a reparse point: $current"
            }
        }
        if ($current.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = $parent.TrimEnd('\')
    }
}

function Test-TransientFileSystemContention([Exception]$exception) {
    $current = $exception
    while ($null -ne $current) {
        if ($current -is [IO.IOException]) {
            # ERROR_SHARING_VIOLATION and ERROR_LOCK_VIOLATION are the only
            # transient Windows errors retried by the release transaction.
            $win32Error = ([int]$current.HResult) -band 0xFFFF
            if ($win32Error -eq 32 -or $win32Error -eq 33) { return $true }
        }
        $current = $current.InnerException
    }
    return $false
}

function Invoke-TransientFileSystemRetry([string]$operation, [scriptblock]$action) {
    # Endpoint and antivirus scanners can retain a just-created archive or
    # manifest briefly after its writer closes. Keep retries narrow to the two
    # documented Windows lock errors, but give that handoff a bounded window.
    [int]$maximumAttempts = 8
    for ([int]$attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            return & $action
        }
        catch [IO.IOException] {
            if ($attempt -ge $maximumAttempts -or -not (Test-TransientFileSystemContention $_.Exception)) {
                throw
            }
            [int]$delayMilliseconds = [Math]::Min(5000, 250 * [Math]::Pow(2, $attempt - 1))
            Write-Verbose "$operation encountered a transient file-sharing conflict; retrying in $delayMilliseconds ms (attempt $attempt of $maximumAttempts)."
            Start-Sleep -Milliseconds $delayMilliseconds
        }
    }
}

function Set-AtomicFileBytes([string]$path, [byte[]]$bytes) {
    $full = [IO.Path]::GetFullPath($path)
    $temporary = $full + '.tmp-' + [guid]::NewGuid().ToString('N')
    $replacementBackup = $null
    try {
        [IO.File]::WriteAllBytes($temporary, $bytes)
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $replacementBackup = $full + '.replace-backup-' + [guid]::NewGuid().ToString('N')
            Invoke-TransientFileSystemRetry "Atomic file replacement ($full)" {
                [IO.File]::Replace($temporary, $full, $replacementBackup, $true)
            }
        }
        else {
            Invoke-TransientFileSystemRetry "Atomic file move ($full)" {
                [IO.File]::Move($temporary, $full)
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $replacementBackup -and (Test-Path -LiteralPath $replacementBackup -PathType Leaf)) {
            Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Move-DirectoryAtomically([string]$source, [string]$destination) {
    $sourceFull = [IO.Path]::GetFullPath($source).TrimEnd('\')
    $destinationFull = [IO.Path]::GetFullPath($destination).TrimEnd('\')
    if (-not [IO.Path]::GetPathRoot($sourceFull).Equals(
        [IO.Path]::GetPathRoot($destinationFull), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Atomic release directory moves must remain on one volume: $sourceFull -> $destinationFull"
    }
    if (-not [IO.Directory]::Exists($sourceFull)) {
        throw "Atomic release move source is missing: $sourceFull"
    }
    if ([IO.Directory]::Exists($destinationFull) -or [IO.File]::Exists($destinationFull)) {
        throw "Atomic release move destination already exists: $destinationFull"
    }
    # Directory.Move maps to the native same-volume rename operation. PowerShell
    # Move-Item recursively moved long trees entry-by-entry and could split a
    # canonical release when a deeply nested path failed partway through.
    Invoke-TransientFileSystemRetry "Atomic directory move ($sourceFull -> $destinationFull)" {
        [IO.Directory]::Move($sourceFull, $destinationFull)
    }
}

function Get-StrictJson([string]$path) {
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    [IO.File]::ReadAllText($path, $strictUtf8) | ConvertFrom-Json -ErrorAction Stop
}

function Get-StrictJsonText([string]$text, [string]$label) {
    if ([string]::IsNullOrWhiteSpace($text) -or $text[0] -eq [char]0xFEFF) {
        throw "$label is empty or is not UTF-8 without a byte-order mark."
    }
    try { $text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "$label is invalid JSON: $($_.Exception.Message)" }
}

function Get-FileSha256([string]$path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToUpperInvariant()
}

function ConvertTo-WindowsCommandLineArgument([string]$value) {
    if ($null -eq $value -or $value.Length -eq 0) { return '""' }
    if ($value.IndexOfAny([char[]]@(' ', "`t", "`r", "`n", '"')) -lt 0) { return $value }

    $quoted = New-Object Text.StringBuilder
    [void]$quoted.Append('"')
    $backslashCount = 0
    for ($index = 0; $index -lt $value.Length; $index++) {
        $character = $value[$index]
        if ($character -eq [char]92) {
            $backslashCount++
            continue
        }
        if ($character -eq '"') {
            [void]$quoted.Append([char]92, ($backslashCount * 2 + 1))
            [void]$quoted.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$quoted.Append([char]92, $backslashCount)
            $backslashCount = 0
        }
        [void]$quoted.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$quoted.Append([char]92, ($backslashCount * 2))
    }
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Invoke-PortableManifestGenerator([string]$powerShellPath, [string]$scriptPath,
    [string]$sourceRoot, [string]$outputPath) {
    $childArguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath, '-SourceRoot', $sourceRoot, '-OutputPath', $outputPath
    )
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $powerShellPath
    $info.Arguments = (($childArguments | ForEach-Object {
        ConvertTo-WindowsCommandLineArgument ([string]$_)
    }) -join ' ')
    $info.WorkingDirectory = Split-Path -Parent $scriptPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw "Unable to start manifest generator: $powerShellPath" }

    try {
        # Begin both reads before waiting so a large diagnostic stream cannot
        # block the child process before it reaches its exit code.
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    if ($exitCode -ne 0) {
        $details = New-Object 'System.Collections.Generic.List[string]'
        if (-not [string]::IsNullOrWhiteSpace($standardOutput)) {
            $details.Add("stdout:$([Environment]::NewLine)$standardOutput")
        }
        if (-not [string]::IsNullOrWhiteSpace($standardError)) {
            $details.Add("stderr:$([Environment]::NewLine)$standardError")
        }
        $diagnostic = if ($details.Count -eq 0) { '' } else { [Environment]::NewLine + ($details -join [Environment]::NewLine) }
        throw "Portable package manifest generator failed with exit code $exitCode.$diagnostic"
    }

    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw "Portable package manifest generator exited successfully without creating: $outputPath"
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        StandardOutput = $standardOutput
        StandardError = $standardError
    }
}

function Assert-ExactPropertySet([object]$value, [string[]]$expected, [string]$label) {
    $actual = @($value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actual.Count -ne $expected.Count -or
        @($expected | Where-Object { -not ($actual -ccontains $_) }).Count -ne 0 -or
        @($actual | Where-Object { -not ($expected -ccontains $_) }).Count -ne 0) {
        throw "$label has an unsupported property set: $($actual -join ', ')"
    }
}

function Assert-PortableReleaseDescriptor([object]$descriptor, [hashtable]$expectedMetadata,
    [string]$expectedReleaseVersion, [string]$label) {
    Assert-ExactPropertySet $descriptor @('SchemaVersion', 'ReleaseVersion', 'LauncherVersion', 'Files') $label
    if ([int]$descriptor.SchemaVersion -ne 1) {
        throw "$label SchemaVersion must be 1."
    }
    if ($expectedReleaseVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' -or
        -not ([string]$descriptor.ReleaseVersion).Equals($expectedReleaseVersion, [StringComparison]::Ordinal) -or
        -not ([string]$descriptor.LauncherVersion).Equals($expectedReleaseVersion, [StringComparison]::Ordinal)) {
        throw "$label ReleaseVersion and LauncherVersion must equal $expectedReleaseVersion."
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $files = @($descriptor.Files)
    if ($files.Count -ne $releaseDescriptorFiles.Count) {
        throw "$label must contain exactly $($releaseDescriptorFiles.Count) file entries."
    }
    foreach ($entry in $files) {
        Assert-ExactPropertySet $entry @('Path', 'Length', 'Sha256') "$label file entry"
        $path = [string]$entry.Path
        $length = [long]$entry.Length
        $sha256 = [string]$entry.Sha256
        if (-not ($releaseDescriptorFiles -ccontains $path) -or -not $seen.Add($path)) {
            throw "$label contains an unexpected or duplicate file entry: $path"
        }
        if ($length -le 0 -or $sha256 -notmatch '^[A-F0-9]{64}$') {
            throw "$label has invalid metadata for $path"
        }
        $expected = $expectedMetadata[$path]
        if ($null -eq $expected -or [long]$expected.Length -ne $length -or
            -not ([string]$expected.Sha256).Equals($sha256, [StringComparison]::Ordinal)) {
            throw "$label does not match the verified file metadata for $path"
        }
    }
    foreach ($path in $releaseDescriptorFiles) {
        if (-not $seen.Contains($path)) { throw "$label is missing $path" }
    }
}

function New-PortableReleaseDescriptor([string]$sourceRoot, [string]$releaseVersion) {
    if ($releaseVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "Cannot create portable-release.json with an invalid launcher version: $releaseVersion"
    }
    $metadata = @{}
    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($relative in $releaseDescriptorFiles) {
        $path = Join-Path $sourceRoot ($relative.Replace('/', [string][char]92))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Cannot create portable-release.json; staged file is missing: $relative"
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0) {
            throw "Cannot create portable-release.json from an unsafe or empty file: $relative"
        }
        $entry = [pscustomobject][ordered]@{
            Path = $relative
            Length = [long]$item.Length
            Sha256 = Get-FileSha256 $path
        }
        $metadata[$relative] = $entry
        [void]$files.Add($entry)
    }
    $descriptor = [ordered]@{
        SchemaVersion = 1
        ReleaseVersion = $releaseVersion
        LauncherVersion = $releaseVersion
        Files = $files.ToArray()
    }
    $descriptorPath = Join-Path $sourceRoot ($releaseDescriptorPath.Replace('/', [string][char]92))
    $descriptorBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($descriptor | ConvertTo-Json -Depth 6))
    Set-AtomicFileBytes $descriptorPath $descriptorBytes
    $verified = Get-StrictJson $descriptorPath
    Assert-PortableReleaseDescriptor $verified $metadata $releaseVersion 'Generated portable-release.json'
    [pscustomobject]@{
        Path = $descriptorPath
        Length = [long](Get-Item -LiteralPath $descriptorPath -Force).Length
        Sha256 = Get-FileSha256 $descriptorPath
        SchemaVersion = 1
    }
}

function Get-ZipEntrySha256([IO.Compression.ZipArchiveEntry]$entry) {
    $stream = $entry.Open()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-ZipEntryStrictJson([IO.Compression.ZipArchiveEntry]$entry, [string]$label) {
    if ($entry.Length -le 0 -or $entry.Length -gt 1048576) {
        throw "$label has an invalid JSON entry length: $($entry.FullName)"
    }
    $stream = $entry.Open()
    try {
        # AppxManifest.xml in the official MSIX is valid UTF-8 with a BOM.
        # Detect it here while retaining strict invalid-byte handling.
        $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false, $true)), $true)
        try { Get-StrictJsonText $reader.ReadToEnd() $label }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Resolve-SevenZip() {
    $commands = @(
        Get-Command 7z.exe -CommandType Application -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Source) -and
                (Test-Path -LiteralPath $_.Source -PathType Leaf) } |
            Select-Object -First 1
    )
    if ($commands.Count -ne 1) {
        throw '7-Zip 24.09 or later is required to create compact LF release archives.'
    }
    $path = [string]$commands[0].Source
    $output = @(& $path i -bd -bb0 -bso1 -bse1 -bsp0 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "7-Zip inspection failed (exit code $exitCode): $((@($output | Select-Object -Last 20) -join [Environment]::NewLine))"
    }
    $banner = @($output | ForEach-Object { [string]$_ } |
        Where-Object { $_ -match '^7-Zip [0-9]+\.[0-9]+' } |
        Select-Object -First 1)
    if ($banner.Count -ne 1) {
        throw "The installed 7-Zip executable did not report a supported version: $path"
    }
    $match = [regex]::Match($banner[0], '^7-Zip (?<Version>[0-9]+\.[0-9]+)')
    if (-not $match.Success) {
        throw "The installed 7-Zip executable did not report a parseable version: $path"
    }
    $version = [version]$match.Groups['Version'].Value
    if ($version -lt $minimumSevenZipVersion) {
        throw "7-Zip $minimumSevenZipVersion or later is required; found $version at $path."
    }
    [pscustomobject]@{
        Path = $path
        Version = $version.ToString()
    }
}

function Invoke-SevenZipCommand(
    [string]$sevenZipPath,
    [string]$workingDirectory,
    [string]$label,
    [string[]]$arguments
) {
    if (-not (Test-Path -LiteralPath $sevenZipPath -PathType Leaf)) {
        throw "7-Zip executable is missing: $sevenZipPath"
    }
    if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
        throw "7-Zip working directory is missing: $workingDirectory"
    }
    $pushed = $false
    try {
        Push-Location -LiteralPath $workingDirectory
        $pushed = $true
        $output = @(& $sevenZipPath @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($pushed) { Pop-Location }
    }
    if ($exitCode -ne 0) {
        $detail = @($output | Select-Object -Last 20 | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        throw "$label failed through 7-Zip (exit code $exitCode): $detail"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Get-SevenZipCompressionSummary([string]$sevenZipPath, [string]$archivePath, [string]$label) {
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "$label is missing: $archivePath"
    }
    $lines = @(Invoke-SevenZipCommand $sevenZipPath (Split-Path -Parent $archivePath) "$label listing" @(
            'l', '-slt', '-ba', '-bd', '-bb0', '-bso1', '-bse1', '-bsp0', '--', $archivePath
        ))
    $methodsByPath = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $currentPath = $null
    foreach ($line in $lines) {
        if ($line.StartsWith('Path = ', [StringComparison]::Ordinal)) {
            if ($null -ne $currentPath) {
                throw "$label has an incomplete 7-Zip listing entry for: $currentPath"
            }
            $currentPath = $line.Substring(7)
            continue
        }
        if (-not $line.StartsWith('Method = ', [StringComparison]::Ordinal)) { continue }
        if ($null -eq $currentPath) {
            throw "$label has a compression method without a matching entry path."
        }
        $method = $line.Substring(9)
        if ($method -notin @('Store', 'Deflate')) {
            throw "$label uses an unsupported ZIP compression method '$method' for $currentPath."
        }
        $normalizedPath = $currentPath.Replace('\', '/')
        if ($methodsByPath.ContainsKey($normalizedPath)) {
            throw "$label has a duplicate 7-Zip listing entry: $normalizedPath"
        }
        [void]$methodsByPath.Add($normalizedPath, $method)
        $currentPath = $null
    }
    if ($null -ne $currentPath) {
        throw "$label has an incomplete 7-Zip listing entry for: $currentPath"
    }
    $zip = [IO.Compression.ZipFile]::OpenRead((Convert-ToExtendedPath $archivePath))
    try {
        [long]$uncompressedBytes = 0
        [long]$compressedEntryBytes = 0
        foreach ($entry in @($zip.Entries)) {
            if ($uncompressedBytes -gt ([long]::MaxValue - [long]$entry.Length) -or
                $compressedEntryBytes -gt ([long]::MaxValue - [long]$entry.CompressedLength)) {
                throw "$label size totals overflow Int64."
            }
            $uncompressedBytes += [long]$entry.Length
            $compressedEntryBytes += [long]$entry.CompressedLength
        }
        if ($methodsByPath.Count -ne $zip.Entries.Count) {
            throw "$label 7-Zip listing count $($methodsByPath.Count) does not match ZIP entry count $($zip.Entries.Count)."
        }
    }
    finally { $zip.Dispose() }
    $archiveInfo = Get-Item -LiteralPath $archivePath -Force
    [int]$storeEntries = @($methodsByPath.Values | Where-Object { $_ -ceq 'Store' }).Count
    [int]$deflateEntries = @($methodsByPath.Values | Where-Object { $_ -ceq 'Deflate' }).Count
    [pscustomobject]@{
        ArchiveBytes = [long]$archiveInfo.Length
        EntryCount = [int]$methodsByPath.Count
        UncompressedBytes = $uncompressedBytes
        CompressedEntryBytes = $compressedEntryBytes
        StoreEntries = $storeEntries
        DeflateEntries = $deflateEntries
        MethodsByPath = $methodsByPath
    }
}

function Assert-ExtremeZipCompression(
    [string]$sevenZipPath,
    [string]$archivePath,
    [string]$label,
    [string[]]$requiredStoredPaths = @()
) {
    Invoke-SevenZipCommand $sevenZipPath (Split-Path -Parent $archivePath) "$label integrity test" @(
        't', '-bd', '-bb0', '-bso0', '-bse1', '-bsp0', '--', $archivePath
    ) | Out-Null
    $summary = Get-SevenZipCompressionSummary $sevenZipPath $archivePath $label
    if ($summary.ArchiveBytes -ge $summary.UncompressedBytes) {
        throw "$label was not compacted: archive size $($summary.ArchiveBytes) must be below its $($summary.UncompressedBytes)-byte input."
    }
    if ($summary.DeflateEntries -le 0) {
        throw "$label has no Deflate entries after the required maximum-compression pass."
    }
    foreach ($path in $requiredStoredPaths) {
        if (-not $summary.MethodsByPath.ContainsKey($path) -or $summary.MethodsByPath[$path] -cne 'Store') {
            throw "$label must store the already-compressed payload entry: $path"
        }
    }
    return $summary
}

function New-ExtremeZipArchive(
    [string]$sevenZipPath,
    [string]$workingDirectory,
    [string]$outputPath,
    [string]$label,
    [string[]]$deflateInputs,
    [string[]]$storedInputs = @()
) {
    if (Test-Path -LiteralPath $outputPath) { throw "$label output already exists: $outputPath" }
    if ($deflateInputs.Count -eq 0) { throw "$label has no inputs for the Deflate pass." }
    Invoke-SevenZipCommand $sevenZipPath $workingDirectory "$label Deflate pass" @(
        @('a') + $sevenZipUltraArguments + @($outputPath, '--') + $deflateInputs
    ) | Out-Null
    if ($storedInputs.Count -ne 0) {
        Invoke-SevenZipCommand $sevenZipPath $workingDirectory "$label store pass" @(
            @('a') + $sevenZipStoreArguments + @($outputPath, '--') + $storedInputs
        ) | Out-Null
    }
    return Assert-ExtremeZipCompression $sevenZipPath $outputPath $label $storedInputs
}

function New-ExtremeZipArchiveFromFiles(
    [string]$sevenZipPath,
    [string]$workingDirectory,
    [string]$outputPath,
    [string]$label,
    [string[]]$inputRoots
) {
    if ($inputRoots.Count -eq 0) { throw "$label has no file roots." }
    $workingFull = [IO.Path]::GetFullPath($workingDirectory).TrimEnd('\')
    $relativeFiles = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in $inputRoots) {
        $rootPath = Join-Path $workingFull $root
        if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
            throw "$label input root is missing: $root"
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $rootPath -Force -Recurse -File -ErrorAction Stop)) {
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$label input file is a reparse point: $($file.FullName)"
            }
            $full = [IO.Path]::GetFullPath($file.FullName)
            if (-not $full.StartsWith($workingFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "$label input file escapes its source root: $full"
            }
            $relative = $full.Substring($workingFull.Length + 1)
            if ($relative.StartsWith('@') -or $relative.StartsWith('-') -or $relative.Contains("`r") -or $relative.Contains("`n")) {
                throw "$label input file has an unsafe response-list path: $relative"
            }
            # 7-Zip response lists split unquoted whitespace even when it is
            # inside a Windows filename, so quote every already-validated item.
            $relativeFiles.Add('"' + $relative + '"')
        }
    }
    if ($relativeFiles.Count -eq 0) { throw "$label has no files to archive." }
    $relativeFiles.Sort([StringComparer]::Ordinal)
    $listName = '.zip-files-' + [guid]::NewGuid().ToString('N') + '.txt'
    $listPath = Join-Path $workingFull $listName
    try {
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllLines($listPath, [string[]]$relativeFiles, $utf8)
        # 7-Zip parses a response-list filename before normal Windows path
        # handling, so a drive-qualified rooted name is not valid. Keep the
        # list beside the source and pass its leaf name relative to the working directory.
        # The -- switch also disables @file expansion, so this branch invokes
        # the already-validated response list directly.
        if (Test-Path -LiteralPath $outputPath) { throw "$label output already exists: $outputPath" }
        Invoke-SevenZipCommand $sevenZipPath $workingFull "$label Deflate pass" @(
            @('a') + $sevenZipUltraArguments + @($outputPath, ('@' + $listName))
        ) | Out-Null
        return Assert-ExtremeZipCompression $sevenZipPath $outputPath $label
    }
    finally {
        if (Test-Path -LiteralPath $listPath -PathType Leaf) {
            Remove-Item -LiteralPath $listPath -Force -ErrorAction Stop
        }
    }
}

function Get-ZipEntryAttributes([IO.Compression.ZipArchiveEntry]$entry) {
    # ExternalAttributes is signed on some supported .NET Framework builds.
    [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
}

function Get-SafeReleaseArchiveEntryPath([string]$name) {
    $backslash = [string][char]92
    if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.StartsWith($backslash) -or
        $name.Contains(':') -or $name -match '[\x00-\x1F]') {
        throw "LFPortable-release.zip contains an unsafe entry path: $name"
    }
    $isDirectory = $name.EndsWith('/') -or $name.EndsWith($backslash)
    $clean = $name.Replace($backslash, '/').TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($clean) -or
        @($clean.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) {
        throw "LFPortable-release.zip contains an unsafe entry path: $name"
    }
    foreach ($segment in $clean.Split('/')) {
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ') -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "LFPortable-release.zip contains a Windows-unsafe entry path: $name"
        }
    }
    [pscustomobject]@{ Path = $clean; IsDirectory = $isDirectory }
}

function Assert-ReleaseArchiveEntryAttributes([IO.Compression.ZipArchiveEntry]$entry) {
    $attributes = Get-ZipEntryAttributes $entry
    $unixType = ($attributes -shr 16) -band 0xF000
    if ($unixType -eq 0xA000 -or (($attributes -band 0x400) -ne 0)) {
        throw "LFPortable-release.zip contains a symbolic link or reparse-point entry: $($entry.FullName)"
    }
}

function Assert-ReleaseArchiveManifest([object]$manifest, [string]$label) {
    if ([int]$manifest.SchemaVersion -ne 4 -or [string]$manifest.Package -cne 'Codex Portable USB' -or
        [string]$manifest.Packaging -cne 'CompressedFirstRun') {
        throw "$label has an unsupported compact release manifest."
    }
    $launcherVersion = [string]$manifest.LauncherVersion
    $releaseVersion = [string]$manifest.ReleaseVersion
    if ($launcherVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' -or
        -not $releaseVersion.Equals($launcherVersion, [StringComparison]::Ordinal)) {
        throw "$label ReleaseVersion must be the exact four-part LauncherVersion."
    }
    if ([int]$manifest.FileCount -ne $releaseArchiveCanonicalFiles.Count -or
        [int]$manifest.ManagedSummary.FileCount -ne $releaseArchiveCanonicalFiles.Count) {
        throw "$label does not declare the required compact file count."
    }

    $entries = @{}
    foreach ($entry in @($manifest.Files)) {
        $path = [string]$entry.Path
        $length = [long]$entry.Length
        $sha256 = [string]$entry.Sha256
        if (-not ($releaseArchiveCanonicalFiles -ccontains $path)) {
            throw "$label declares an unexpected archive file: $path"
        }
        if ($entries.ContainsKey($path)) { throw "$label declares a duplicate archive file: $path" }
        if ($length -le 0 -or $sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "$label has invalid archive metadata for $path"
        }
        $entries[$path] = [pscustomobject]@{ Length = $length; Sha256 = $sha256.ToUpperInvariant() }
    }
    if ($entries.Count -ne $releaseArchiveCanonicalFiles.Count) {
        throw "$label does not declare every compact release file."
    }
    foreach ($path in $releaseArchiveCanonicalFiles) {
        if (-not $entries.ContainsKey($path)) { throw "$label is missing archive metadata for $path" }
    }
    if (-not ([string]$manifest.LauncherSha256).Equals(
            [string]$entries['CodexPortable.exe'].Sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$label launcher hash does not match CodexPortable.exe metadata."
    }
    if ($null -eq $manifest.PortableReleaseDescriptor) {
        throw "$label is missing PortableReleaseDescriptor metadata."
    }
    $descriptorMetadata = $manifest.PortableReleaseDescriptor
    Assert-ExactPropertySet $descriptorMetadata @(
        'Path', 'SchemaVersion', 'ReleaseVersion', 'LauncherVersion', 'FileCount', 'Length', 'Sha256'
    ) "$label PortableReleaseDescriptor"
    $descriptorEntry = $entries[$releaseDescriptorPath]
    if ([string]$descriptorMetadata.Path -cne $releaseDescriptorPath -or
        [int]$descriptorMetadata.SchemaVersion -ne 1 -or
        [int]$descriptorMetadata.FileCount -ne $releaseDescriptorFiles.Count -or
        -not ([string]$descriptorMetadata.ReleaseVersion).Equals($releaseVersion, [StringComparison]::Ordinal) -or
        -not ([string]$descriptorMetadata.LauncherVersion).Equals($launcherVersion, [StringComparison]::Ordinal) -or
        [long]$descriptorMetadata.Length -ne [long]$descriptorEntry.Length -or
        -not ([string]$descriptorMetadata.Sha256).Equals([string]$descriptorEntry.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$label PortableReleaseDescriptor metadata does not match $releaseDescriptorPath."
    }
    [pscustomobject]@{
        LauncherVersion = $launcherVersion
        ReleaseVersion = $releaseVersion
        Entries = $entries
    }
}

function Assert-PortableReleaseArchive([string]$archivePath, [string]$manifestPath) {
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "LF release archive is missing: $archivePath"
    }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "LF release archive manifest is missing: $manifestPath"
    }
    $manifest = Get-StrictJson $manifestPath
    $contract = Assert-ReleaseArchiveManifest $manifest 'Release archive manifest'
    $manifestInfo = Get-Item -LiteralPath $manifestPath -Force
    $manifestHash = Get-FileSha256 $manifestPath
    $expectedPaths = @($releaseArchiveManifestEntry) + @($releaseArchiveCanonicalFiles)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $zip = [IO.Compression.ZipFile]::OpenRead((Convert-ToExtendedPath $archivePath))
    try {
        if ($zip.Entries.Count -ne $expectedPaths.Count) {
            throw "LFPortable-release.zip has $($zip.Entries.Count) entries; expected $($expectedPaths.Count)."
        }
        foreach ($entry in @($zip.Entries)) {
            Assert-ReleaseArchiveEntryAttributes $entry
            $safe = Get-SafeReleaseArchiveEntryPath $entry.FullName
            if ($safe.IsDirectory -or $entry.FullName -cne $safe.Path) {
                throw "LFPortable-release.zip must not contain directory or non-normalized entries: $($entry.FullName)"
            }
            if (-not ($expectedPaths -ccontains $safe.Path)) {
                throw "LFPortable-release.zip contains an unexpected entry: $($entry.FullName)"
            }
            if (-not $seen.Add($safe.Path)) {
                throw "LFPortable-release.zip contains a duplicate entry: $($entry.FullName)"
            }
            if ($safe.Path -ceq $releaseArchiveManifestEntry) {
                if ([long]$entry.Length -ne [long]$manifestInfo.Length -or
                    -not (Get-ZipEntrySha256 $entry).Equals($manifestHash, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'LFPortable-release.zip embedded manifest does not match the canonical manifest.'
                }
                continue
            }
            $metadata = $contract.Entries[$safe.Path]
            if ([long]$entry.Length -ne [long]$metadata.Length -or
                -not (Get-ZipEntrySha256 $entry).Equals([string]$metadata.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw "LFPortable-release.zip entry does not match the manifest: $($entry.FullName)"
            }
            if ($safe.Path -ceq $releaseDescriptorPath) {
                $descriptor = Get-ZipEntryStrictJson $entry 'LFPortable-release.zip portable-release.json'
                $descriptorMetadata = @{}
                foreach ($path in $releaseDescriptorFiles) {
                    $descriptorMetadata[$path] = $contract.Entries[$path]
                }
                Assert-PortableReleaseDescriptor $descriptor $descriptorMetadata $contract.ReleaseVersion `
                    'LFPortable-release.zip portable-release.json'
            }
        }
        foreach ($path in $expectedPaths) {
            if (-not $seen.Contains($path)) { throw "LFPortable-release.zip is missing $path" }
        }
    }
    finally { $zip.Dispose() }
    $archiveInfo = Get-Item -LiteralPath $archivePath -Force
    if ($archiveInfo.Length -le 0) { throw "LFPortable-release.zip is empty: $archivePath" }
    [pscustomobject]@{
        ArchivePath = $archiveInfo.FullName
        ArchiveSha256 = Get-FileSha256 $archivePath
        ArchiveBytes = [long]$archiveInfo.Length
        ArchiveEntryCount = $expectedPaths.Count
        ReleaseVersion = $contract.ReleaseVersion
        ManifestSha256 = $manifestHash
    }
}

function New-PortableReleaseArchive(
    [string]$sourceRoot,
    [string]$manifestPath,
    [string]$outputPath,
    [string]$sevenZipPath
) {
    if (Test-Path -LiteralPath $outputPath) { throw "LF release archive output already exists: $outputPath" }
    $manifest = Get-StrictJson $manifestPath
    Assert-ReleaseArchiveManifest $manifest 'Staged release manifest' | Out-Null
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $embeddedManifestPath = Join-Path $sourceRoot $releaseArchiveManifestEntry
    if (Test-Path -LiteralPath $embeddedManifestPath) {
        throw "Staged release unexpectedly already contains $releaseArchiveManifestEntry."
    }
    $storedPayloads = @(
        'CodexData/packages/LFPortable-common.zip',
        'CodexData/packages/LFPortable-x64.msix',
        'CodexData/packages/LFPortable-arm64.msix'
    )
    $deflateInputs = @($releaseArchiveManifestEntry) + @($releaseArchiveCanonicalFiles |
        Where-Object { $storedPayloads -cnotcontains $_ })
    $compression = $null
    try {
        # 7-Zip's Deflate level 0 is still larger than Store for nested MSIX
        # and ZIP payloads. Add the small files at maximum Deflate settings,
        # then explicitly store those already-compressed package entries.
        Set-AtomicFileBytes $embeddedManifestPath $manifestBytes
        foreach ($relative in @($deflateInputs) + @($storedPayloads)) {
            $sourcePath = Join-Path $sourceRoot ($relative.Replace('/', [string][char]92))
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "Staged release file is missing while creating LFPortable-release.zip: $relative"
            }
        }
        $compression = New-ExtremeZipArchive $sevenZipPath $sourceRoot $outputPath 'LFPortable-release.zip' `
            $deflateInputs $storedPayloads
    }
    finally {
        if (Test-Path -LiteralPath $embeddedManifestPath -PathType Leaf) {
            Remove-Item -LiteralPath $embeddedManifestPath -Force -ErrorAction Stop
        }
    }
    $archive = Assert-PortableReleaseArchive $outputPath $manifestPath
    $archive | Add-Member -NotePropertyName Compression -NotePropertyValue $compression
    return $archive
}

function Convert-ToExtendedPath([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    if ($full.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $full }
    if ($full.StartsWith('\\', [StringComparison]::Ordinal)) {
        return '\\?\UNC\' + $full.Substring(2)
    }
    '\\?\' + $full
}

function Get-PortableFiles([string]$path) {
    # The runtime includes valid plugin asset paths close to MAX_PATH.  Use
    # the extended prefix consistently so a release scan cannot mistake a
    # long, existing directory for a missing or incomplete cache.
    @(Get-ChildItem -LiteralPath (Convert-ToExtendedPath $path) -Recurse -Force -File -ErrorAction Stop)
}

function Assert-SourceIsNotUsb([string]$path) {
    # A USB installation is a runtime target, never a release input.  Besides
    # preventing accidental publication of user data, this catches the exact
    # failure mode where an incomplete cache on the drive gets promoted as the
    # canonical release.  CODEX_USB is the synchronizer's reserved label; a
    # removable drive is rejected even when somebody changed that label.
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    if ($full -notmatch '^[A-Za-z]:') { return }
    $driveLetter = $full.Substring(0, 1)
    $driveInfo = $null
    try {
        # DriveInfo works without the WMI/CIM permissions that are commonly
        # denied in Windows Sandbox, CI, and locked-down corporate hosts.
        $driveInfo = New-Object IO.DriveInfo($driveLetter + ':')
        if (-not $driveInfo.IsReady) { throw 'Source drive is not ready.' }
    }
    catch {
        throw "Unable to determine the source volume type for $full; refusing an unverified release source."
    }
    if ($driveInfo.DriveType -eq [IO.DriveType]::Removable -or
        [string]::Equals([string]$driveInfo.VolumeLabel, 'CODEX_USB', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release source '$full' is on a removable/CODEX_USB volume. Build from a separate verified staging directory; never use the USB installation as the release source."
    }
}

function Get-PeMachine([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "PE file is missing: $path"
    }
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        if ($stream.Length -lt 64) { throw "PE file is too small: $path" }
        $stream.Position = 0
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "PE file has no MZ header: $path" }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        if ($offset -lt 0 -or $offset -gt ($stream.Length - 6)) { throw "PE header offset is invalid: $path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "PE file has no signature: $path" }
        [int]$reader.ReadUInt16()
    }
    finally { $stream.Dispose() }
}

function Assert-PeMachine([string]$path, [int]$expected, [string]$label) {
    $actual = Get-PeMachine $path
    if ($actual -ne $expected) {
        throw ("{0} has PE machine 0x{1:X4}; expected 0x{2:X4}." -f $label, $actual, $expected)
    }
}

function Get-DeclaredLauncherVersion([string]$launcherProjectRoot) {
    $sourceFiles = @(
        (Join-Path $launcherProjectRoot 'CodexPortable.cs'),
        (Join-Path $launcherProjectRoot 'CodexPortableBootstrap.cs')
    )
    $versions = New-Object 'System.Collections.Generic.List[string]'
    foreach ($sourceFile in $sourceFiles) {
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
            throw "Launcher version source is missing: $sourceFile"
        }
        $text = [IO.File]::ReadAllText($sourceFile, [Text.Encoding]::UTF8)
        $assemblyVersionMatches = @([regex]::Matches($text,
            '\[assembly:\s*AssemblyVersion\("(?<version>[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"\)\]'))
        $fileVersionMatches = @([regex]::Matches($text,
            '\[assembly:\s*AssemblyFileVersion\("(?<version>[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"\)\]'))
        if ($assemblyVersionMatches.Count -ne 1 -or $fileVersionMatches.Count -ne 1) {
            throw "Launcher source version declaration is missing or ambiguous: $sourceFile"
        }
        $assemblyVersion = [string]$assemblyVersionMatches[0].Groups['version'].Value
        $fileVersion = [string]$fileVersionMatches[0].Groups['version'].Value
        if (-not $assemblyVersion.Equals($fileVersion, [StringComparison]::Ordinal)) {
            throw "Launcher assembly and file versions differ in source: $sourceFile"
        }
        $versions.Add($fileVersion)
    }
    if ($versions.Count -ne 2 -or -not $versions[0].Equals($versions[1], [StringComparison]::Ordinal)) {
        throw 'Launcher core and bootstrapper source versions differ.'
    }
    return $versions[0]
}

function Stop-LauncherCommandProcessTree([Diagnostics.Process]$process) {
    if ($null -eq $process) { return }
    try {
        if ($process.HasExited) { return }
        $taskKill = Join-Path $env:WINDIR 'System32\taskkill.exe'
        if (Test-Path -LiteralPath $taskKill -PathType Leaf) {
            $killInfo = New-Object Diagnostics.ProcessStartInfo
            $killInfo.FileName = $taskKill
            $killInfo.Arguments = '/PID ' + $process.Id + ' /T /F'
            $killInfo.UseShellExecute = $false
            $killInfo.CreateNoWindow = $true
            $killProcess = [Diagnostics.Process]::Start($killInfo)
            if ($null -ne $killProcess) {
                try {
                    if (-not $killProcess.WaitForExit(5000)) { $killProcess.Kill() }
                }
                finally { $killProcess.Dispose() }
            }
        }
    }
    catch {
        Write-Warning "Could not terminate launcher command process tree $($process.Id): $($_.Exception.Message)"
    }
    finally {
        try {
            if (-not $process.HasExited) { $process.Kill() }
        }
        catch {
        }
    }
}

function Invoke-LauncherCommand([string]$launcher, [string]$root, [string[]]$arguments,
    [int]$TimeoutSeconds) {
    $quoted = New-Object System.Collections.Generic.List[string]
    $quoted.Add('--portable-root')
    $quoted.Add($root)
    foreach ($argument in $arguments) { $quoted.Add($argument) }
    $escaped = foreach ($argument in $quoted) {
        if ($argument.IndexOfAny([char[]]@(' ', "`t", "`n", '"')) -lt 0) { $argument }
        else { '"' + $argument.Replace('"', '\"') + '"' }
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $launcher
    $info.Arguments = ($escaped -join ' ')
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw "Unable to start launcher command: $launcher" }
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-LauncherCommandProcessTree $process
            throw "Launcher command timed out after $TimeoutSeconds seconds: $launcher $($arguments -join ' ')"
        }
        if ($process.ExitCode -ne 0) {
            throw "Launcher command failed with exit code $($process.ExitCode): $launcher $($arguments -join ' ')"
        }
    }
    catch {
        Stop-LauncherCommandProcessTree $process
        throw
    }
    finally { $process.Dispose() }
}

function Invoke-OfficialCompatibilityGate([string]$gatePath, [string]$referenceLauncher,
    [switch]$RunLauncherSelfTest, [int]$TimeoutSeconds = 900) {
    $parameters = @{}
    if ($RunLauncherSelfTest) {
        if ([string]::IsNullOrWhiteSpace($referenceLauncher)) {
            throw 'An x64 launcher is required for the official compatibility self-test.'
        }
        $parameters.ReferenceLauncherPath = $referenceLauncher
        $parameters.RunLauncherSelfTest = $true
        $parameters.LauncherSelfTestTimeoutSeconds = $TimeoutSeconds
    }
    elseif (-not [string]::IsNullOrWhiteSpace($referenceLauncher)) {
        throw 'A reference launcher is only valid for an official compatibility self-test.'
    }

    $results = @(& $gatePath @parameters)
    if ($results.Count -ne 1) {
        throw "Official Codex compatibility gate returned $($results.Count) results; expected exactly one."
    }
    $result = $results[0]
    if ([string]$result.Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw 'Official Codex compatibility gate returned an invalid package version.'
    }
    $expectedSelfTest = if ($RunLauncherSelfTest) { 'Passed' } else { 'NotRequested' }
    if (-not ([string]$result.LauncherSelfTest).Equals(
            $expectedSelfTest, [StringComparison]::Ordinal)) {
        throw "Official Codex compatibility gate did not report $expectedSelfTest."
    }
    foreach ($architecture in @('X64', 'Arm64')) {
        $pathProperty = $architecture + 'Path'
        $hashProperty = $architecture + 'SHA256'
        $lengthProperty = $architecture + 'Length'
        $etagProperty = $architecture + 'ETag'
        $packagePath = [string]$result.PSObject.Properties[$pathProperty].Value
        if ([string]::IsNullOrWhiteSpace($packagePath) -or
            -not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
            throw "Official Codex compatibility gate returned a missing $architecture package: $packagePath"
        }
        if ([string]$result.PSObject.Properties[$hashProperty].Value -notmatch '^[A-F0-9]{64}$' -or
            [long]$result.PSObject.Properties[$lengthProperty].Value -le 0 -or
            [string]::IsNullOrWhiteSpace([string]$result.PSObject.Properties[$etagProperty].Value)) {
            throw "Official Codex compatibility gate returned invalid $architecture package metadata."
        }
        Assert-NoReparsePointInAncestry $packagePath
    }
    return $result
}

function Assert-OfficialCompatibilitySnapshotUnchanged([object]$before, [object]$after) {
    foreach ($property in @(
        'Version',
        'X64Path', 'X64SHA256', 'X64Length', 'X64ETag',
        'Arm64Path', 'Arm64SHA256', 'Arm64Length', 'Arm64ETag'
    )) {
        $beforeValue = [string]$before.PSObject.Properties[$property].Value
        $afterValue = [string]$after.PSObject.Properties[$property].Value
        $comparison = if ($property.EndsWith('Path', [StringComparison]::Ordinal) -or
            $property.EndsWith('SHA256', [StringComparison]::Ordinal)) {
            [StringComparison]::OrdinalIgnoreCase
        }
        else {
            [StringComparison]::Ordinal
        }
        if (-not $beforeValue.Equals($afterValue, $comparison)) {
            throw "Official Codex package metadata changed during the release build ($property). Restart the release build."
        }
    }
}

function Resolve-LauncherArtifacts([string]$launcherProjectRoot, [string]$buildRoot) {
    $builder = Join-Path $launcherProjectRoot 'build-launcher-matrix.ps1'
    $expectedSourceVersion = Get-DeclaredLauncherVersion $launcherProjectRoot
    if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) {
        throw "Launcher matrix builder is missing: $builder"
    }
    if (Test-Path -LiteralPath $buildRoot) {
        throw "Fresh launcher matrix build root already exists: $buildRoot"
    }

    $buildResults = @(& $builder -OutputRoot $buildRoot)
    if ($buildResults.Count -ne 1 -or [int]$buildResults[0].BuildCount -ne 4 -or
        [string]$buildResults[0].OfficialPackageSelfTest -ne 'x64-msix+arm64-msix:passed' -or
        -not ([IO.Path]::GetFullPath([string]$buildResults[0].OutputRoot).TrimEnd('\')).Equals(
            [IO.Path]::GetFullPath($buildRoot).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fresh launcher matrix build did not return the required compatibility-gated four-artifact result.'
    }

    $paths = [ordered]@{
        Bootstrapper = Join-Path $buildRoot 'CodexPortable.exe'
        X86 = Join-Path $buildRoot 'CodexData\tools\launchers\CodexPortable.x86.exe'
        X64 = Join-Path $buildRoot 'CodexData\tools\launchers\CodexPortable.x64.exe'
        Arm64 = Join-Path $buildRoot 'CodexData\tools\launchers\CodexPortable.arm64.exe'
        BuildRoot = $buildRoot
    }
    foreach ($entry in @($paths.GetEnumerator())) {
        if ($entry.Key -eq 'BuildRoot') { continue }
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
            throw "Required launcher artifact is missing: $($entry.Value)"
        }
    }
    Assert-PeMachine $paths.Bootstrapper 0x014c 'x86 architecture bootstrapper'
    Assert-PeMachine $paths.X86 0x014c 'x86 launcher core'
    Assert-PeMachine $paths.X64 0x8664 'x64 launcher core'
    Assert-PeMachine $paths.Arm64 0xAA64 'ARM64 launcher core'
    $bootstrapVersion = [string](Get-Item -LiteralPath $paths.Bootstrapper).VersionInfo.FileVersion
    if ([string]::IsNullOrWhiteSpace($bootstrapVersion)) {
        throw "Bootstrapper has no file version: $($paths.Bootstrapper)"
    }
    if (-not $bootstrapVersion.Equals($expectedSourceVersion, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Bootstrapper version $bootstrapVersion does not match current launcher source version $expectedSourceVersion."
    }
    foreach ($core in @($paths.GetEnumerator() | Where-Object { $_.Key -in @('X86', 'X64', 'Arm64') })) {
        $coreVersion = [string](Get-Item -LiteralPath $core.Value).VersionInfo.FileVersion
        if (-not $coreVersion.Equals($bootstrapVersion, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Launcher version mismatch: bootstrapper $bootstrapVersion, $($core.Key) core $coreVersion."
        }
    }
    [pscustomobject]$paths
}

function Get-FileSystemProcessInventory([string]$label) {
    try {
        $inventory = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        if ($inventory.Count -eq 0 -or
            @($inventory | Where-Object { [int]$_.ProcessId -eq $PID }).Count -ne 1) {
            throw 'The current PowerShell process is absent from the CIM inventory.'
        }
        return $inventory | ForEach-Object {
            [pscustomobject]@{
                ProcessId = [int]$_.ProcessId
                Name = [string]$_.Name
                ExecutablePath = [string]$_.ExecutablePath
            }
        }
    }
    catch {
        $cimError = $_.Exception.Message
        $fallback = @(
            Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
                $path = $null
                try { $path = [string]$_.Path }
                catch { }
                [pscustomobject]@{
                    ProcessId = [int]$_.Id
                    Name = [string]$_.ProcessName
                    ExecutablePath = $path
                }
            }
        )
        if ($fallback.Count -eq 0 -or
            @($fallback | Where-Object { [int]$_.ProcessId -eq $PID }).Count -ne 1) {
            throw "$label process inventory is unavailable. CIM: $cimError"
        }
        return $fallback
    }
}

function Assert-NoProcessesFromRoot([string]$root, [string]$label) {
    $inventory = @(Get-FileSystemProcessInventory $label)
    $running = @(
        $inventory | Where-Object {
            [int]$_.ProcessId -ne $PID -and
                -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
                (Test-PathWithin ([string]$_.ExecutablePath) $root)
        }
    )
    if ($running.Count -ne 0) {
        throw "$label processes must be stopped: $($running.Name -join ', ')"
    }
}

function Get-ArchiveSafePath([string]$path, [string]$label) {
    if ([string]::IsNullOrWhiteSpace($path) -or $path.StartsWith('/') -or $path.StartsWith('\\') -or
        $path.Contains(':') -or $path -match '[\x00-\x1F]') {
        throw "$label contains an unsafe entry path: $path"
    }
    $normalized = $path.Replace('\\', '/')
    if ($normalized -ne $path -or $normalized.EndsWith('/')) {
        throw "$label contains a non-file or non-normalized entry path: $path"
    }
    $segments = @($normalized.Split('/'))
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) {
        throw "$label contains an unsafe entry path: $path"
    }
    foreach ($segment in $segments) {
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment -match '[<>"|?*]' -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "$label contains a Windows-unsafe entry path: $path"
        }
    }
    return $normalized
}

function Assert-ArchiveEntryIsRegular([IO.Compression.ZipArchiveEntry]$entry, [string]$label) {
    $attributes = Get-ZipEntryAttributes $entry
    $unixType = ($attributes -shr 16) -band 0xF000
    if ($unixType -eq 0xA000 -or (($attributes -band 0x400) -ne 0)) {
        throw "$label contains a symbolic link or reparse-point entry: $($entry.FullName)"
    }
}

function Read-StrictZipEntryText([IO.Compression.ZipArchiveEntry]$entry, [string]$label) {
    if ($null -eq $entry -or $entry.Length -le 0 -or $entry.Length -gt 4MB) {
        throw "$label has an invalid text entry length."
    }
    $stream = $entry.Open()
    try {
        # AppxManifest.xml in the official MSIX is valid UTF-8 with a BOM.
        # Detect it here while retaining strict invalid-byte handling.
        $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false, $true)), $true)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Open-OfficialX64MsixPluginArchive([string]$msixPath) {
    if (-not (Test-Path -LiteralPath $msixPath -PathType Leaf)) {
        throw "Signed x64 MSIX is missing: $msixPath"
    }
    $item = Get-Item -LiteralPath $msixPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt 100MB -or $item.Length -gt 3GB) {
        throw "Signed x64 MSIX is unsafe or has an unsupported size: $msixPath"
    }
    $signature = Get-AuthenticodeSignature -FilePath $msixPath
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        -not [string]::Equals([string]$signature.SignerCertificate.Subject, $officialMsixPublisher,
            [StringComparison]::Ordinal)) {
        throw "Signed x64 MSIX Authenticode validation failed: $msixPath"
    }

    return [IO.Compression.ZipFile]::OpenRead((Convert-ToExtendedPath $msixPath))
}

function Get-OfficialX64MsixPluginPackages([IO.Compression.ZipArchive]$zip) {
    if ($null -eq $zip) { throw 'Signed x64 MSIX archive is unavailable.' }
    $entries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($zip.Entries)) {
        Assert-ArchiveEntryIsRegular $entry 'Signed x64 MSIX'
        $path = Get-ArchiveSafePath $entry.FullName 'Signed x64 MSIX'
        if (-not $seen.Add($path)) {
            throw "Signed x64 MSIX contains a duplicate entry path: $path"
        }
        [void]$entries.Add($path, $entry)
    }
    $manifestEntry = $null
    if (-not $entries.TryGetValue('AppxManifest.xml', [ref]$manifestEntry)) {
        throw 'Signed x64 MSIX is missing AppxManifest.xml.'
    }
    $manifestText = Read-StrictZipEntryText $manifestEntry 'Signed x64 MSIX AppxManifest.xml'
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $document = New-Object Xml.XmlDocument
    $document.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader($manifestText)), $settings)
    try { $document.Load($reader) }
    finally { $reader.Dispose() }
    $identity = $document.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Identity"]')
    if ($null -eq $identity -or
        [string]$identity.GetAttribute('Name') -cne $officialMsixIdentityName -or
        [string]$identity.GetAttribute('Publisher') -cne $officialMsixPublisher -or
        [string]$identity.GetAttribute('ProcessorArchitecture') -cne 'x64' -or
        [string]$identity.GetAttribute('Version') -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw 'Signed x64 MSIX identity is not the supported official OpenAI.Codex x64 package.'
    }

    $plugins = @{}
    foreach ($plugin in $hydratedBundledPlugins) {
        $prefix = $bundledPluginMsixPrefix + $plugin + '/'
        $pluginEntries = @($entries.GetEnumerator() | Where-Object {
            $_.Key.StartsWith($prefix, [StringComparison]::Ordinal)
        } | Sort-Object Key)
        if ($pluginEntries.Count -eq 0) {
            throw "Signed x64 MSIX is missing bundled plugin entries: $plugin"
        }
        $manifestPath = $prefix + '.codex-plugin/plugin.json'
        $pluginManifestEntry = $null
        if (-not $entries.TryGetValue($manifestPath, [ref]$pluginManifestEntry)) {
            throw "Signed x64 MSIX is missing bundled plugin manifest: $plugin"
        }
        try {
            $pluginManifest = Read-StrictZipEntryText $pluginManifestEntry "Signed x64 MSIX $plugin manifest" |
                ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Signed x64 MSIX has an invalid bundled plugin manifest for ${plugin}: $($_.Exception.Message)"
        }
        $name = [string]$pluginManifest.name
        $version = [string]$pluginManifest.version
        if (-not $name.Equals($plugin, [StringComparison]::Ordinal) -or
            [string]::IsNullOrWhiteSpace($version) -or
            $version.Equals('latest', [StringComparison]::OrdinalIgnoreCase) -or
            $version -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') {
            throw "Signed x64 MSIX bundled plugin manifest is unsafe or inconsistent: $plugin"
        }
        $plugins[$plugin] = [pscustomobject]@{
            Name = $name
            Version = $version
            Prefix = $prefix
            Entries = $pluginEntries
        }
    }
    return $plugins
}

function Test-BundledPluginCacheRoot([string]$cacheCatalogRoot, [object]$pluginPackage) {
    $pluginRoot = Join-Path $cacheCatalogRoot $pluginPackage.Name
    if (-not (Test-Path -LiteralPath $pluginRoot -PathType Container)) { return $false }
    $pluginRootItem = Get-Item -LiteralPath $pluginRoot -Force -ErrorAction Stop
    if (($pluginRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    try {
        $pluginChildren = @(Get-ChildItem -LiteralPath $pluginRoot -Force -ErrorAction Stop)
    }
    catch { return $false }
    if (@($pluginChildren | Where-Object {
                -not $_.PSIsContainer -or (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            }).Count -ne 0) {
        return $false
    }
    $versions = @($pluginChildren | Where-Object { $_.PSIsContainer })
    if ($versions.Count -ne 1 -or -not $versions[0].Name.Equals($pluginPackage.Version, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $versionRoot = $versions[0].FullName
    $cacheFiles = @{}
    $cacheDirectories = @{}
    try {
        $versionItem = Get-Item -LiteralPath $versionRoot -Force -ErrorAction Stop
        if (($versionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        foreach ($directory in @(Get-ChildItem -LiteralPath $versionRoot -Recurse -Force -Directory -ErrorAction Stop)) {
            if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            $relative = $directory.FullName.Substring($versionRoot.Length).TrimStart('\').Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($relative) -or $cacheDirectories.ContainsKey($relative)) { return $false }
            $cacheDirectories[$relative] = $true
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $versionRoot -Recurse -Force -File -ErrorAction Stop)) {
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            $relative = $file.FullName.Substring($versionRoot.Length).TrimStart('\').Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($relative) -or $cacheFiles.ContainsKey($relative)) { return $false }
            $cacheFiles[$relative] = $file
        }
    }
    catch { return $false }

    $sourceFiles = @{}
    $sourceDirectories = @{}
    foreach ($entry in $pluginPackage.Entries) {
        $relative = $entry.Key.Substring($pluginPackage.Prefix.Length)
        try {
            $safeRelative = Get-ArchiveSafePath $relative "Bundled plugin $($pluginPackage.Name)"
        }
        catch { return $false }
        if (-not $safeRelative.Equals($relative, [StringComparison]::Ordinal)) {
            return $false
        }
        if ($sourceFiles.ContainsKey($relative)) { return $false }
        $sourceFiles[$relative] = $entry.Value
        $separator = $relative.LastIndexOf('/')
        while ($separator -gt 0) {
            $directory = $relative.Substring(0, $separator)
            $sourceDirectories[$directory] = $true
            $separator = $directory.LastIndexOf('/')
        }
    }
    if ($sourceFiles.Count -ne $cacheFiles.Count -or $sourceDirectories.Count -ne $cacheDirectories.Count) { return $false }
    foreach ($relative in $sourceDirectories.Keys) {
        if (-not $cacheDirectories.ContainsKey($relative)) { return $false }
    }
    foreach ($relative in $sourceFiles.Keys) {
        if (-not $cacheFiles.ContainsKey($relative)) { return $false }
        $sourceEntry = $sourceFiles[$relative]
        $cacheFile = $cacheFiles[$relative]
        if ([long]$sourceEntry.Length -ne [long]$cacheFile.Length -or
            -not (Get-ZipEntrySha256 $sourceEntry).Equals((Get-FileSha256 $cacheFile.FullName),
                [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    $manifestPath = Join-Path $versionRoot '.codex-plugin\plugin.json'
    try {
        $manifest = Read-SourcePluginManifest $manifestPath "Cached bundled plugin $($pluginPackage.Name)"
        return $manifest.Name.Equals($pluginPackage.Name, [StringComparison]::Ordinal) -and
            $manifest.Version.Equals($pluginPackage.Version, [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Copy-ZipPluginEntry([IO.Compression.ZipArchiveEntry]$entry, [string]$destination, [string]$label) {
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    $input = $entry.Open()
    $output = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $buffer = New-Object byte[] (1024 * 1024)
        [long]$written = 0
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($written -gt [long]::MaxValue - $read) { throw "$label length overflows Int64: $($entry.FullName)" }
            $output.Write($buffer, 0, $read)
            $written += $read
        }
        if ($written -ne [long]$entry.Length) { throw "$label length verification failed: $($entry.FullName)" }
    }
    finally {
        $output.Dispose()
        $input.Dispose()
    }
}

function Hydrate-RequiredBundledPluginCache([string]$sourceRoot, [string]$x64MsixPath) {
    $cacheCatalogRoot = Join-Path $sourceRoot ('CodexData\data\profile\.codex\plugins\cache\' + $bundledPluginCatalog)
    if (-not (Test-Path -LiteralPath $cacheCatalogRoot -PathType Container)) {
        throw "Release source bundled plugin cache catalog is missing: $cacheCatalogRoot"
    }
    $catalogItem = Get-Item -LiteralPath $cacheCatalogRoot -Force -ErrorAction Stop
    if (($catalogItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Release source bundled plugin cache catalog is a reparse point: $cacheCatalogRoot"
    }
    Assert-NoProcessesFromRoot $sourceRoot 'Release source hydration'

    $zip = Open-OfficialX64MsixPluginArchive $x64MsixPath
    try {
        $packages = Get-OfficialX64MsixPluginPackages $zip
        $changes = New-Object 'System.Collections.Generic.List[string]'
        $repairs = New-Object 'System.Collections.Generic.List[object]'
        foreach ($plugin in $hydratedBundledPlugins) {
            $package = $packages[$plugin]
            if (Test-BundledPluginCacheRoot $cacheCatalogRoot $package) { continue }

            $target = Join-Path $cacheCatalogRoot $plugin
            if (Test-Path -LiteralPath $target) {
                $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction Stop
                if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Release source bundled plugin cache target is a reparse point: $target"
                }
            }
            [void]$repairs.Add([pscustomobject]@{
                    Package = $package
                    Target = $target
                    Backup = $null
                    TargetKind = $null
                    Activated = $false
                })
        }
        if ($repairs.Count -eq 0) { return $changes.ToArray() }

        $transaction = Join-Path $cacheCatalogRoot ('.h-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
        $stageCatalogRoot = Join-Path $transaction '.s'
        try {
            New-Item -ItemType Directory -Path $stageCatalogRoot -Force -ErrorAction Stop | Out-Null
            $transactionItem = Get-Item -LiteralPath $transaction -Force -ErrorAction Stop
            if (($transactionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Bundled plugin hydration transaction is a reparse point: $transaction"
            }
            foreach ($repair in $repairs) {
                $package = $repair.Package
                $stagePlugin = Join-Path $stageCatalogRoot $package.Name
                $stageVersion = Join-Path $stagePlugin $package.Version
                foreach ($entry in $package.Entries) {
                    $relative = $entry.Key.Substring($package.Prefix.Length)
                    $safeRelative = Get-ArchiveSafePath $relative "Signed x64 MSIX $($package.Name) plugin"
                    if (-not $safeRelative.Equals($relative, [StringComparison]::Ordinal)) {
                        throw "Signed x64 MSIX $($package.Name) plugin path changed during validation: $relative"
                    }
                    $destination = Join-Path $stageVersion ($relative.Replace('/', '\'))
                    $stageFull = [IO.Path]::GetFullPath($stageVersion).TrimEnd('\')
                    $destinationFull = [IO.Path]::GetFullPath($destination)
                    if (-not $destinationFull.StartsWith($stageFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Signed x64 MSIX $($package.Name) plugin path escapes staging: $relative"
                    }
                    Copy-ZipPluginEntry $entry.Value $destination "Signed x64 MSIX $($package.Name) plugin"
                }
                if (-not (Test-BundledPluginCacheRoot $stageCatalogRoot $package)) {
                    throw "Staged bundled plugin tree is incomplete or does not match the signed x64 MSIX: $($package.Name)"
                }
            }

            Assert-NoProcessesFromRoot $sourceRoot 'Release source hydration'
            foreach ($repair in $repairs) {
                if (-not (Test-Path -LiteralPath $repair.Target)) { continue }
                $targetItem = Get-Item -LiteralPath $repair.Target -Force -ErrorAction Stop
                if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Release source bundled plugin cache target changed to a reparse point: $($repair.Target)"
                }
                $repair.TargetKind = if ($targetItem.PSIsContainer) { 'Directory' } else { 'File' }
                $repair.Backup = Join-Path $transaction ('.b-' + $repair.Package.Name)
                if ($repair.TargetKind -eq 'Directory') {
                    Invoke-TransientFileSystemRetry "Bundled plugin backup ($($repair.Target))" {
                        [IO.Directory]::Move($repair.Target, $repair.Backup)
                    }
                }
                else {
                    Invoke-TransientFileSystemRetry "Bundled plugin file backup ($($repair.Target))" {
                        [IO.File]::Move($repair.Target, $repair.Backup)
                    }
                }
            }
            foreach ($repair in $repairs) {
                $stagePlugin = Join-Path $stageCatalogRoot $repair.Package.Name
                Invoke-TransientFileSystemRetry "Bundled plugin activation ($($repair.Target))" {
                    [IO.Directory]::Move($stagePlugin, $repair.Target)
                }
                $repair.Activated = $true
            }
            foreach ($repair in $repairs) {
                if (-not (Test-BundledPluginCacheRoot $cacheCatalogRoot $repair.Package)) {
                    throw "Hydrated bundled plugin cache failed source verification: $($repair.Package.Name)"
                }
                $changes.Add($repair.Package.Name)
            }
        }
        catch {
            $failure = $_
            $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
            foreach ($repair in @($repairs | Sort-Object { if ($_.Activated) { 0 } else { 1 } })) {
                try {
                    if ($repair.Activated -and (Test-Path -LiteralPath $repair.Target)) {
                        $failedPlugin = Join-Path $transaction ('.f-' + $repair.Package.Name)
                        Invoke-TransientFileSystemRetry "Bundled plugin rollback isolation ($($repair.Target))" {
                            [IO.Directory]::Move($repair.Target, $failedPlugin)
                        }
                    }
                    if ($null -ne $repair.Backup -and (Test-Path -LiteralPath $repair.Backup) -and
                        -not (Test-Path -LiteralPath $repair.Target)) {
                        if ($repair.TargetKind -eq 'Directory') {
                            Invoke-TransientFileSystemRetry "Bundled plugin rollback restoration ($($repair.Target))" {
                                [IO.Directory]::Move($repair.Backup, $repair.Target)
                            }
                        }
                        else {
                            Invoke-TransientFileSystemRetry "Bundled plugin file rollback restoration ($($repair.Target))" {
                                [IO.File]::Move($repair.Backup, $repair.Target)
                            }
                        }
                    }
                }
                catch { $rollbackErrors.Add("$($repair.Package.Name): $($_.Exception.Message)") }
            }
            if ($rollbackErrors.Count -ne 0) {
                throw "Bundled plugin hydration failed and rollback needs inspection. Original: $($failure.Exception.Message) Rollback: $($rollbackErrors -join ' | ')"
            }
            throw $failure
        }
        finally {
            if (Test-Path -LiteralPath $transaction -PathType Container) {
                Remove-Item -LiteralPath $transaction -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        return $changes.ToArray()
    }
    finally { $zip.Dispose() }
}


function Read-SourcePluginManifest([string]$path, [string]$label) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$label plugin manifest is missing: $path"
    }
    try {
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $manifest = [IO.File]::ReadAllText($path, $strictUtf8) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$label plugin manifest is invalid: $path ($($_.Exception.Message))"
    }
    $name = [string]$manifest.name
    $version = [string]$manifest.version
    if ([string]::IsNullOrWhiteSpace($name) -or
        [string]::IsNullOrWhiteSpace($version) -or
        $version.Equals('latest', [StringComparison]::OrdinalIgnoreCase) -or
        $version -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') {
        throw "$label plugin manifest has an unsafe name or version: $path"
    }
    [pscustomobject]@{ Name = $name; Version = $version }
}

function Assert-CompleteSourcePluginCache([string]$sourceRoot) {
    $cacheRoot = Join-Path $sourceRoot 'CodexData\data\profile\.codex\plugins\cache'
    $catalogs = [ordered]@{
        'openai-bundled' = @('sites', 'browser', 'chrome', 'computer-use', 'latex', 'deep-research', 'visualize')
        'openai-primary-runtime' = @('documents', 'pdf', 'presentations', 'spreadsheets', 'template-creator')
    }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($catalog in $catalogs.Keys) {
        $catalogRoot = Join-Path $cacheRoot $catalog
        if (-not (Test-Path -LiteralPath $catalogRoot -PathType Container)) {
            $missing.Add("CodexData/data/profile/.codex/plugins/cache/$catalog")
            continue
        }
        foreach ($plugin in $catalogs[$catalog]) {
            $pluginRoot = Join-Path $catalogRoot $plugin
            if (-not (Test-Path -LiteralPath $pluginRoot -PathType Container)) {
                $missing.Add("CodexData/data/profile/.codex/plugins/cache/$catalog/$plugin")
                continue
            }
            $versions = @(Get-ChildItem -LiteralPath $pluginRoot -Directory -Force -ErrorAction Stop)
            if ($versions.Count -eq 0) {
                $missing.Add("CodexData/data/profile/.codex/plugins/cache/$catalog/$plugin/<version>")
                continue
            }
            foreach ($versionRoot in $versions) {
                $manifestPath = Join-Path $versionRoot.FullName '.codex-plugin\plugin.json'
                if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                    $missing.Add("$catalog/$plugin/$($versionRoot.Name)/.codex-plugin/plugin.json")
                    continue
                }
                $manifest = Read-SourcePluginManifest $manifestPath "$catalog/$plugin/$($versionRoot.Name)"
                if (-not $manifest.Name.Equals($plugin, [StringComparison]::Ordinal) -or
                    -not $manifest.Version.Equals($versionRoot.Name, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Plugin cache entry '$catalog/$plugin/$($versionRoot.Name)' does not match its manifest."
                }
            }
        }
    }
    if ($missing.Count -ne 0) {
        throw "Complete release source is missing required versioned plugin-cache entries: $($missing -join ', ')"
    }
}

function Assert-CompletePortableSource([string]$sourceRoot) {
    # dist/ contains only launchers.  The source root supplies the clean common
    # runtime and cache; desktop payloads are never copied from it.
    $stalePayload = Join-Path $sourceRoot 'CodexData\app\current'
    if (Test-Path -LiteralPath $stalePayload) { throw "Release source contains an expanded desktop payload: $stalePayload" }
    $requiredFiles = @(
        'CodexData\tools\dotnet\dotnet.exe',
        'CodexData\data\profile\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe',
        'CodexData\data\profile\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
        'CodexData\data\profile\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe',
        'CodexData\data\profile\.codex\offline-marketplaces\openai-primary-runtime\.agents\plugins\marketplace.json'
    )
    $missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $sourceRoot $_) -PathType Leaf) })
    $ghCandidates = @('CodexData\tools\gh\bin\gh.exe', 'CodexData\tools\gh\gh.exe')
    if (@($ghCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $sourceRoot $_) -PathType Leaf }).Count -eq 0) {
        $missing += 'CodexData\tools\gh\(bin\gh.exe or gh.exe)'
    }
    if ($missing.Count -ne 0) {
        throw "Release source is incomplete. Missing: $($missing -join ', '). Build from a clean staging root, not dist/ or a USB installation."
    }
    Assert-CompleteSourcePluginCache $sourceRoot
}

function Assert-NoReparsePointsUnder([string]$root) {
    $extended = Convert-ToExtendedPath $root
    $points = @(Get-ChildItem -LiteralPath $extended -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop)
    if ($points.Count -ne 0) {
        throw "Release source contains $($points.Count) reparse points beneath $root."
    }
}

function Assert-SafeCommonSource([string]$sourceRoot, [string]$rgPath) {
    $dataRoot = Join-Path $sourceRoot 'CodexData'
    $roots = @(
        (Join-Path $dataRoot 'tools\dotnet'),
        (Join-Path $dataRoot 'tools\gh'),
        (Join-Path $dataRoot 'data\profile\.cache\codex-runtimes'),
        (Join-Path $dataRoot 'data\profile\.codex\offline-marketplaces'),
        (Join-Path $dataRoot 'data\profile\.codex\plugins\cache')
    )
    $globs = @(
        '--hidden', '--fixed-strings', '--files-with-matches',
        '--glob', '*.json', '--glob', '*.toml', '--glob', '*.jsonl', '--glob', '*.ini',
        '--glob', '*.txt', '--glob', '*.log', '--glob', '*.old', '--glob', '*.cfg'
    )
    foreach ($needle in @(
        'R:\CodexData', 'R:\\CodexData', 'S:\CodexData', 'S:\\CodexData',
        'portable-vm-dummy-key'
    )) {
        $matches = @(& $rgPath @globs -- $needle $roots 2>$null)
        $exitCode = $LASTEXITCODE
        if ($exitCode -notin @(0, 1)) { throw "Sanitized-source scan failed with rg exit code $exitCode." }
        if ($matches.Count -ne 0) {
            throw "Release source contains forbidden '$needle' material: $($matches -join ', ')"
        }
    }
    $forbiddenNames = @('auth.json', 'api-key.txt', 'api-key.vault', 'api-vault.xml', 'custom-api-url.txt', 'custom-model.txt')
    $credentialFiles = @(
        foreach ($root in $roots) {
            Get-PortableFiles $root |
                Where-Object { $forbiddenNames -ccontains $_.Name }
        }
    )
    if ($credentialFiles.Count -ne 0) {
        throw "Release source contains forbidden credential/config files: $($credentialFiles.FullName -join ', ')"
    }
}

$sourceCandidate = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $sourceCandidate -PathType Container)) {
    throw "Release source is missing: $sourceCandidate. Pass -SourceRoot to a separate verified payload staging root; dist contains launchers only."
}
$source = (Resolve-Path -LiteralPath $sourceCandidate).Path.TrimEnd('\')
$destinationFull = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')
$releaseParentFull = [IO.Path]::GetFullPath($ReleaseParentRoot).TrimEnd('\')
$manifestScript = Join-Path $PSScriptRoot 'New-PortablePackageManifest.ps1'
$manifestPowerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$manifestPath = Join-Path $releaseParentFull 'portable-package-manifest.json'
$releaseArchivePath = Join-Path $releaseParentFull 'LFPortable-release.zip'
$launcherProjectRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'portable-launcher'
$launcherMatrixBuilder = Join-Path $launcherProjectRoot 'build-launcher-matrix.ps1'
$officialCompatibilityGate = Join-Path $launcherProjectRoot 'Assert-OfficialCodexCompatibility.ps1'
if (-not $destinationFull.Equals((Join-Path $releaseParentFull 'release'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Destination must be exactly $(Join-Path $releaseParentFull 'release')"
}
$requiredTools = @($manifestScript, $manifestPowerShellPath, $launcherMatrixBuilder, $officialCompatibilityGate)
foreach ($requiredTool in $requiredTools) {
    if (-not (Test-Path -LiteralPath $requiredTool -PathType Leaf)) {
        throw "Required release tool is missing: $requiredTool"
    }
}
$rgCommand = @(
    Get-Command rg -CommandType Application -ErrorAction Stop |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Source) -and (Test-Path -LiteralPath $_.Source -PathType Leaf) } |
        Select-Object -First 1
)
$rgPath = if ($rgCommand.Count -eq 1) { [string]$rgCommand[0].Source } else { $null }
if ([string]::IsNullOrWhiteSpace($rgPath) -or -not (Test-Path -LiteralPath $rgPath -PathType Leaf)) {
    throw 'The installed rg executable could not be resolved.'
}
$sevenZip = Resolve-SevenZip
$sevenZipPath = [string]$sevenZip.Path
if (-not (Test-Path -LiteralPath $releaseParentFull -PathType Container)) {
    throw "Release parent is missing: $releaseParentFull"
}
if ((Test-PathWithin $source $destinationFull) -or (Test-PathWithin $destinationFull $source)) {
    throw 'Release source and canonical destination must be separate non-nested directories.'
}
Assert-NoReparsePointInAncestry $source
Assert-NoReparsePointsUnder $source
Assert-NoReparsePointInAncestry $releaseParentFull
Assert-NoReparsePointInAncestry $PSScriptRoot
Assert-SourceIsNotUsb $source

$expectedRootEntries = @('CodexData', 'CodexPortable.exe')
$sourceRootEntries = @(Get-ChildItem -LiteralPath $source -Force | Select-Object -ExpandProperty Name | Sort-Object)
if (Compare-Object -ReferenceObject $expectedRootEntries -DifferenceObject $sourceRootEntries) {
    throw "Unexpected source root entries: $($sourceRootEntries -join ', ')"
}

# This happens before source hydration, launcher compilation, or release
# staging. The gate performs fresh official metadata, signature, architecture,
# and package validation for both desktop architectures.
$officialPreflight = Invoke-OfficialCompatibilityGate `
    -gatePath $officialCompatibilityGate `
    -referenceLauncher $null `
    -TimeoutSeconds $LauncherSelfTestTimeoutSeconds
$x64MsixFull = [string]$officialPreflight.X64Path
$arm64MsixFull = [string]$officialPreflight.Arm64Path
Hydrate-RequiredBundledPluginCache $source $x64MsixFull | Out-Null
Assert-CompletePortableSource $source
Assert-SafeCommonSource $source $rgPath
Assert-NoProcessesFromRoot $source 'Portable source'

$nonce = [guid]::NewGuid().ToString('N')
$shortId = $nonce.Substring(0, 8)
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
# Keep transaction roots short. Versioned plugin assets already approach
# MAX_PATH at a drive root; verbose staging names make otherwise valid release
# contents invisible to Windows PowerShell 5 enumeration.
$stageRoot = Join-Path $releaseParentFull ('.s-' + $shortId)
$backupRoot = Join-Path $releaseParentFull ('.b-' + $timestamp + '-' + $shortId)
$failedRoot = Join-Path $releaseParentFull ('.f-' + $shortId)
$validationRoot = Join-Path $releaseParentFull ('.v-' + $shortId)
$stagedManifestPath = Join-Path $releaseParentFull ('.m-' + $shortId + '.json')
$stagedArchivePath = Join-Path $releaseParentFull ('.a-' + $shortId + '.zip')
$archiveBackupPath = Join-Path $releaseParentFull ('.a-prev-' + $timestamp + '-' + $shortId + '.zip')
$failedArchivePath = Join-Path $releaseParentFull ('.a-failed-' + $shortId + '.zip')
$lockPath = Join-Path $releaseParentFull '.release.lock'
$launcherBuildRoot = Join-Path $releaseParentFull ('.l-' + $shortId)
$launcherArtifacts = $null
$canonicalLauncher = $null
foreach ($temporaryPath in @(
    $stageRoot, $backupRoot, $failedRoot, $validationRoot, $stagedManifestPath,
    $stagedArchivePath, $archiveBackupPath, $failedArchivePath
)) {
    if (Test-Path -LiteralPath $temporaryPath) { throw "Release transaction path already exists: $temporaryPath" }
}
if (Test-Path -LiteralPath $releaseArchivePath) {
    if (-not (Test-Path -LiteralPath $releaseArchivePath -PathType Leaf)) {
        throw "LF release archive path is not a regular file: $releaseArchivePath"
    }
    Assert-NoReparsePointInAncestry $releaseArchivePath
}
if (Test-Path -LiteralPath $launcherBuildRoot) {
    throw "Launcher matrix transaction path already exists: $launcherBuildRoot"
}
try {
    $launcherArtifacts = Resolve-LauncherArtifacts $launcherProjectRoot $launcherBuildRoot

    # Validate this transaction's fresh x64 core against the same current
    # official x64 and ARM64 packages before release staging can begin.
    $officialCompatibility = Invoke-OfficialCompatibilityGate `
        -gatePath $officialCompatibilityGate `
        -referenceLauncher $launcherArtifacts.X64 `
        -RunLauncherSelfTest `
        -TimeoutSeconds $LauncherSelfTestTimeoutSeconds
    Assert-OfficialCompatibilitySnapshotUnchanged $officialPreflight $officialCompatibility
}
catch {
    if (Test-Path -LiteralPath $launcherBuildRoot -PathType Container) {
        Remove-Item -LiteralPath $launcherBuildRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}
$canonicalLauncher = $launcherArtifacts.Bootstrapper

$lockStream = $null
try {
    $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
catch {
    throw "Another canonical release publication is active: $lockPath"
}

$previousManifestBytes = $null
$oldMoved = $false
$newMoved = $false
$manifestPublished = $false
$archivePublished = $false
$archiveBackupCreated = $false
$publicationSucceeded = $false
$releaseArchiveInfo = $null

try {
    $previousManifestBytes = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        [IO.File]::ReadAllBytes($manifestPath)
    } else { $null }
    New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop | Out-Null
    $releaseLauncher = Join-Path $stageRoot 'CodexPortable.exe'
    Copy-Item -LiteralPath $canonicalLauncher -Destination $releaseLauncher -Force

    # The root entry is deliberately the x86 bootstrapper. It selects the
    # matching core from CodexData\tools\launchers on the first click.
    $launcherDirectory = Join-Path $stageRoot 'CodexData\tools\launchers'
    New-Item -ItemType Directory -Path $launcherDirectory -Force | Out-Null
    Copy-Item -LiteralPath $launcherArtifacts.X86 -Destination (Join-Path $launcherDirectory 'CodexPortable.x86.exe') -Force
    Copy-Item -LiteralPath $launcherArtifacts.X64 -Destination (Join-Path $launcherDirectory 'CodexPortable.x64.exe') -Force
    Copy-Item -LiteralPath $launcherArtifacts.Arm64 -Destination (Join-Path $launcherDirectory 'CodexPortable.arm64.exe') -Force
    Assert-PeMachine $releaseLauncher 0x014c 'staged bootstrapper'
    Assert-PeMachine (Join-Path $launcherDirectory 'CodexPortable.x86.exe') 0x014c 'staged x86 launcher core'
    Assert-PeMachine (Join-Path $launcherDirectory 'CodexPortable.x64.exe') 0x8664 'staged x64 launcher core'
    Assert-PeMachine (Join-Path $launcherDirectory 'CodexPortable.arm64.exe') 0xAA64 'staged ARM64 launcher core'

    # Keep the canonical image compact. The common roots are validated above,
    # then archived directly from the source with the mandatory maximum-Deflate
    # profile; no expanded copy is ever made in the release transaction.
    $stagedX64Launcher = Join-Path $launcherDirectory 'CodexPortable.x64.exe'
    $packagesDirectory = Join-Path $stageRoot 'CodexData\packages'
    New-Item -ItemType Directory -Path $packagesDirectory -Force | Out-Null
    $commonPackage = Join-Path $packagesDirectory 'LFPortable-common.zip'
    $commonSourceRoot = Join-Path $source 'CodexData'
    $archiveInputs = @(
        'tools\dotnet',
        'tools\gh',
        'data\profile\.cache\codex-runtimes',
        'data\profile\.codex\offline-marketplaces',
        'data\profile\.codex\plugins\cache'
    )
    foreach ($relative in $archiveInputs) {
        if (-not (Test-Path -LiteralPath (Join-Path $commonSourceRoot $relative) -PathType Container)) {
            throw "Sanitized common-package source root is missing: $relative"
        }
    }
    # Archive explicit files through a UTF-8 response list so the common ZIP
    # does not carry thousands of redundant directory records.
    $commonCompression = New-ExtremeZipArchiveFromFiles $sevenZipPath $commonSourceRoot $commonPackage `
        'LFPortable-common.zip' $archiveInputs
    $commonInfo = Get-Item -LiteralPath $commonPackage -Force
    if ([long]$commonCompression.ArchiveBytes -ne [long]$commonInfo.Length) {
        throw 'LFPortable-common.zip changed after its compression profile was verified.'
    }
    if ($commonInfo.Length -lt (100L * 1024L * 1024L) -or $commonInfo.Length -gt (4L * 1024L * 1024L * 1024L)) {
        throw "LFPortable-common.zip has an invalid compressed size: $($commonInfo.Length)"
    }
    $commonPackageHash = (Get-FileHash -LiteralPath $commonPackage -Algorithm SHA256).Hash.ToUpperInvariant()

    $x64Package = Join-Path $packagesDirectory 'LFPortable-x64.msix'
    $x64MsixInfo = Get-Item -LiteralPath $x64MsixFull -Force -ErrorAction Stop
    $x64MsixHash = (Get-FileHash -LiteralPath $x64MsixFull -Algorithm SHA256).Hash.ToUpperInvariant()
    if ([long]$x64MsixInfo.Length -ne [long]$officialPreflight.X64Length -or
        -not $x64MsixHash.Equals([string]$officialPreflight.X64SHA256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The gate-validated official x64 MSIX changed before release staging.'
    }
    Copy-Item -LiteralPath $x64MsixFull -Destination $x64Package -Force
    $stagedX64MsixInfo = Get-Item -LiteralPath $x64Package -Force -ErrorAction Stop
    $stagedX64MsixHash = (Get-FileHash -LiteralPath $x64Package -Algorithm SHA256).Hash.ToUpperInvariant()
    if ([long]$stagedX64MsixInfo.Length -ne [long]$officialPreflight.X64Length -or
        -not $stagedX64MsixHash.Equals([string]$officialPreflight.X64SHA256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staged x64 MSIX does not match the gate-validated official package.'
    }
    $x64MsixHash = $stagedX64MsixHash

    $arm64MsixInfo = Get-Item -LiteralPath $arm64MsixFull -Force -ErrorAction Stop
    $arm64MsixHash = (Get-FileHash -LiteralPath $arm64MsixFull -Algorithm SHA256).Hash.ToUpperInvariant()
    if ([long]$arm64MsixInfo.Length -ne [long]$officialPreflight.Arm64Length -or
        -not $arm64MsixHash.Equals([string]$officialPreflight.Arm64SHA256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The gate-validated official ARM64 MSIX changed before release staging.'
    }
    $arm64Package = Join-Path $packagesDirectory 'LFPortable-arm64.msix'
    Copy-Item -LiteralPath $arm64MsixFull -Destination $arm64Package -Force
    $stagedArm64MsixInfo = Get-Item -LiteralPath $arm64Package -Force -ErrorAction Stop
    $stagedArm64MsixHash = (Get-FileHash -LiteralPath $arm64Package -Algorithm SHA256).Hash.ToUpperInvariant()
    if ([long]$stagedArm64MsixInfo.Length -ne [long]$officialPreflight.Arm64Length -or
        -not $stagedArm64MsixHash.Equals([string]$officialPreflight.Arm64SHA256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staged ARM64 MSIX does not match the gate-validated official package.'
    }
    $arm64MsixHash = $stagedArm64MsixHash

    # Validate both signed packages through the launcher. The command extracts
    # only into the isolated validation root and always removes its staging
    # directory, so no expanded desktop tree can reach the canonical release.
    New-Item -ItemType Directory -Path $validationRoot -Force | Out-Null
    Invoke-LauncherCommand $stagedX64Launcher $validationRoot @('--self-test-msix', $x64Package, 'x64') $LauncherSelfTestTimeoutSeconds
    Invoke-LauncherCommand $stagedX64Launcher $validationRoot @('--self-test-msix', $arm64Package, 'arm64') $LauncherSelfTestTimeoutSeconds
    $runtimeSelfTest = 'x64-msix+arm64-msix:passed'

    $readmeText = @"
LF Portable
===========

This directory is the compact LF release. Start CodexPortable.exe and choose
Start Codex from the launcher. The first start expands the common ZIP and the
MSIX matching the Windows architecture into CodexData.

The canonical release intentionally contains no expanded app/current tree,
profile, credentials, logs, or updater state. Only the launcher, signed MSIX
packages, and the verified common runtime archive are published here.
"@
    $thirdPartyText = @"
LF Portable third-party notices
===============================

This release redistributes the signed OpenAI Codex Desktop MSIX packages and
the runtime/tool/plugin files in LFPortable-common.zip. Their original license
and notice files are retained inside those archives. Copyright and license
terms remain with their respective authors and vendors.
"@
    $utf8 = New-Object Text.UTF8Encoding($false)
    Set-AtomicFileBytes (Join-Path $stageRoot 'CodexData\README.txt') $utf8.GetBytes($readmeText)
    Set-AtomicFileBytes (Join-Path $stageRoot 'CodexData\THIRD_PARTY.txt') $utf8.GetBytes($thirdPartyText)
    $stagedLauncherVersion = [string](Get-Item -LiteralPath $releaseLauncher -Force).VersionInfo.FileVersion
    if ($stagedLauncherVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "Staged bootstrapper has an invalid four-part version: $stagedLauncherVersion"
    }
    $releaseDescriptorInfo = New-PortableReleaseDescriptor $stageRoot $stagedLauncherVersion

    $expectedStageDirectories = @(
        'CodexData', 'CodexData\packages', 'CodexData\tools', 'CodexData\tools\launchers'
    )
    $expectedStageFiles = @(
        'CodexPortable.exe',
        'CodexData\README.txt', 'CodexData\THIRD_PARTY.txt', 'CodexData\portable-release.json',
        'CodexData\tools\launchers\CodexPortable.x86.exe',
        'CodexData\tools\launchers\CodexPortable.x64.exe',
        'CodexData\tools\launchers\CodexPortable.arm64.exe',
        'CodexData\packages\LFPortable-common.zip',
        'CodexData\packages\LFPortable-x64.msix',
        'CodexData\packages\LFPortable-arm64.msix'
    )
    $actualStageDirectories = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -Force -Directory |
        ForEach-Object { $_.FullName.Substring($stageRoot.Length).TrimStart('\') })
    $actualStageFiles = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -Force -File |
        ForEach-Object { $_.FullName.Substring($stageRoot.Length).TrimStart('\') })
    if (Compare-Object -ReferenceObject ($expectedStageDirectories | Sort-Object) -DifferenceObject ($actualStageDirectories | Sort-Object)) {
        throw "Compact release contains unexpected directories: $($actualStageDirectories -join ', ')"
    }
    if (Compare-Object -ReferenceObject ($expectedStageFiles | Sort-Object) -DifferenceObject ($actualStageFiles | Sort-Object)) {
        throw "Compact release contains unexpected files: $($actualStageFiles -join ', ')"
    }
    Assert-NoReparsePointsUnder $stageRoot
    $stageScanGlobs = @('--hidden', '--fixed-strings', '--files-with-matches', '--glob', '*.json', '--glob', '*.toml', '--glob', '*.txt')
    foreach ($needle in @('R:\CodexData', 'R:\\CodexData', 'S:\CodexData', 'S:\\CodexData', 'portable-vm-dummy-key')) {
        $matches = @(& $rgPath @stageScanGlobs -- $needle $stageRoot 2>$null)
        $stageScanExitCode = $LASTEXITCODE
        if ($stageScanExitCode -notin @(0, 1)) { throw "Compact release scan failed with rg exit code $stageScanExitCode." }
        if ($matches.Count -ne 0) { throw "Compact release retains forbidden '$needle' material: $($matches -join ', ')" }
    }
    foreach ($forbiddenDirectory in @('CodexData\app', 'CodexData\data', 'CodexData\logs', 'CodexData\updates', 'CodexData\runtime', 'CodexData\tools\desktop-payloads')) {
        if (Test-Path -LiteralPath (Join-Path $stageRoot $forbiddenDirectory)) {
            throw "Compact release contains an expanded or mutable directory: $forbiddenDirectory"
        }
    }

    $measure = Get-ChildItem -LiteralPath $stageRoot -Recurse -Force -File |
        Measure-Object Length -Sum
    $stageLauncherHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseLauncher).Hash.ToUpperInvariant()

    $manifestInvocation = Invoke-PortableManifestGenerator $manifestPowerShellPath $manifestScript $stageRoot $stagedManifestPath
    # Retain the existing result contract: this field is the manifest
    # generator's standard output, while stderr is included in a failure.
    $manifestOutput = [string]$manifestInvocation.StandardOutput
    if (-not (Test-Path -LiteralPath $stagedManifestPath -PathType Leaf)) {
        throw 'Manifest generator did not create the staged canonical manifest.'
    }
    $manifestHash = (Get-FileHash -LiteralPath $stagedManifestPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $manifest = Get-StrictJson $stagedManifestPath
    if ([int]$manifest.SchemaVersion -ne 4 -or [string]$manifest.Package -ne 'Codex Portable USB' -or
        [string]$manifest.Packaging -cne 'CompressedFirstRun' -or
        -not ([string]$manifest.LauncherSha256).Equals($stageLauncherHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staged compact release manifest is unsupported or does not match the staged launcher.'
    }
    $releaseArchiveContract = Assert-ReleaseArchiveManifest $manifest 'Staged compact release manifest'
    foreach ($requiredPackage in @('CodexData/packages/LFPortable-common.zip', 'CodexData/packages/LFPortable-x64.msix', 'CodexData/packages/LFPortable-arm64.msix')) {
        $entries = @($manifest.Files | Where-Object { [string]$_.Path -ceq $requiredPackage })
        if ($entries.Count -ne 1 -or [string]$entries[0].Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Staged compact release manifest lacks a unique hash for $requiredPackage."
        }
    }
    if ($manifest.Files.Count -ne $expectedStageFiles.Count) {
        throw "Staged compact release manifest has $($manifest.Files.Count) files; expected $($expectedStageFiles.Count)."
    }
    $releaseArchiveInfo = New-PortableReleaseArchive $stageRoot $stagedManifestPath $stagedArchivePath $sevenZipPath
    if ([long]$releaseArchiveInfo.ArchiveBytes -gt $githubReleaseAssetMaximumBytes) {
        throw "LFPortable-release.zip is too large for a GitHub Release asset: $($releaseArchiveInfo.ArchiveBytes) bytes (maximum $githubReleaseAssetMaximumBytes)."
    }
    if ($releaseArchiveInfo.ArchiveEntryCount -ne ($releaseArchiveCanonicalFiles.Count + 1) -or
        -not $releaseArchiveInfo.ReleaseVersion.Equals($releaseArchiveContract.ReleaseVersion, [StringComparison]::Ordinal) -or
        -not $releaseArchiveInfo.ManifestSha256.Equals($manifestHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'LFPortable-release.zip did not verify against the staged release manifest.'
    }

    Assert-NoProcessesFromRoot $destinationFull 'Canonical release'

    if (Test-Path -LiteralPath $destinationFull) {
        Move-DirectoryAtomically $destinationFull $backupRoot
        $oldMoved = $true
    }
    Move-DirectoryAtomically $stageRoot $destinationFull
    $newMoved = $true
    Set-AtomicFileBytes $manifestPath ([IO.File]::ReadAllBytes($stagedManifestPath))
    $manifestPublished = $true

    # Publish only after the embedded manifest and all ten managed files have
    # been read back and hashed. USB deployment is a separate post-Sandbox
    # validation action, so it cannot roll back a valid canonical Release.
    if (Test-Path -LiteralPath $releaseArchivePath -PathType Leaf) {
        Invoke-TransientFileSystemRetry "Release archive replacement ($releaseArchivePath)" {
            [IO.File]::Replace((Convert-ToExtendedPath $stagedArchivePath), (Convert-ToExtendedPath $releaseArchivePath),
                (Convert-ToExtendedPath $archiveBackupPath), $true)
        }
        $archiveBackupCreated = $true
    }
    else {
        Invoke-TransientFileSystemRetry "Release archive move ($releaseArchivePath)" {
            [IO.File]::Move((Convert-ToExtendedPath $stagedArchivePath), (Convert-ToExtendedPath $releaseArchivePath))
        }
    }
    $archivePublished = $true
    $publishedArchiveInfo = Assert-PortableReleaseArchive $releaseArchivePath $manifestPath
    $publishedCompression = Assert-ExtremeZipCompression $sevenZipPath $releaseArchivePath `
        'Published LFPortable-release.zip' @(
            'CodexData/packages/LFPortable-common.zip',
            'CodexData/packages/LFPortable-x64.msix',
            'CodexData/packages/LFPortable-arm64.msix'
        )
    if (-not $publishedArchiveInfo.ArchiveSha256.Equals($releaseArchiveInfo.ArchiveSha256, [StringComparison]::OrdinalIgnoreCase) -or
        $publishedArchiveInfo.ArchiveBytes -ne $releaseArchiveInfo.ArchiveBytes -or
        -not $publishedArchiveInfo.ReleaseVersion.Equals($releaseArchiveContract.ReleaseVersion, [StringComparison]::Ordinal)) {
        throw 'Published LFPortable-release.zip does not match the staged verified archive.'
    }
    $publishedArchiveInfo | Add-Member -NotePropertyName Compression -NotePropertyValue $publishedCompression
    $releaseArchiveInfo = $publishedArchiveInfo

    $releaseResult = [ordered]@{
        Status = 'PublishedPendingZeroStateValidation'
        SourceRoot = $source
        LauncherSource = $canonicalLauncher
        LauncherBootstrapperArchitecture = 'x86'
        LauncherCoreArchitectures = @('x86', 'x64', 'arm64')
        DesktopPayloadArchitectures = @('x64', 'arm64')
        DestinationRoot = $destinationFull
        PreviousReleaseBackup = if ($oldMoved) { $backupRoot } else { $null }
        Packaging = [string]$manifest.Packaging
        ReleaseVersion = [string]$manifest.ReleaseVersion
        ReleaseArchivePath = $releaseArchiveInfo.ArchivePath
        ReleaseArchiveSha256 = $releaseArchiveInfo.ArchiveSha256
        ReleaseArchiveBytes = [long]$releaseArchiveInfo.ArchiveBytes
        ReleaseArchiveEntryCount = [int]$releaseArchiveInfo.ArchiveEntryCount
        CompressionTool = '7-Zip'
        CompressionToolVersion = [string]$sevenZip.Version
        CompressionProfile = $sevenZipCompressionProfile
        ReleaseArchiveStoreEntries = [int]$releaseArchiveInfo.Compression.StoreEntries
        ReleaseArchiveDeflateEntries = [int]$releaseArchiveInfo.Compression.DeflateEntries
        ReleaseArchiveUncompressedBytes = [long]$releaseArchiveInfo.Compression.UncompressedBytes
        FileCount = $measure.Count
        TotalBytes = [long]$measure.Sum
        LauncherSha256 = $stageLauncherHash
        CommonPackageSha256 = $commonPackageHash
        CommonPackageBytes = [long]$commonInfo.Length
        CommonPackageUncompressedBytes = [long]$manifest.PackageArtifacts.Common.UncompressedBytes
        CommonPackageStoreEntries = [int]$commonCompression.StoreEntries
        CommonPackageDeflateEntries = [int]$commonCompression.DeflateEntries
        X64MsixSha256 = $x64MsixHash
        Arm64MsixSha256 = $arm64MsixHash
        ManifestSchemaVersion = [int]$manifest.SchemaVersion
        ManifestSha256 = $manifestHash
        RuntimeSelfTest = $runtimeSelfTest
        PackageArtifacts = $manifest.PackageArtifacts
        ManagedSummary = $manifest.ManagedSummary
        ReparsePointCount = 0
        RemovedDrivePathMatches = 0
        DummyKeyMatches = 0
        UsbProgramSync = 'BlockedPendingZeroStateValidation'
        NextAction = 'Run Invoke-CompactFirstRunSandbox.ps1 against this exact release before invoking Sync-CodexPortableUsb.ps1.'
        ManifestGeneratorOutput = $manifestOutput
    }
    $publicationSucceeded = $true
    [pscustomobject]$releaseResult | ConvertTo-Json -Depth 8
}
catch {
    $publishError = $_
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
    try {
        if ($newMoved -and (Test-Path -LiteralPath $destinationFull)) {
            Move-DirectoryAtomically $destinationFull $failedRoot
            $newMoved = $false
        }
        elseif ((Test-Path -LiteralPath $stageRoot) -and -not (Test-Path -LiteralPath $failedRoot)) {
            Move-DirectoryAtomically $stageRoot $failedRoot
        }
    }
    catch { $rollbackErrors.Add("Failed release isolation: $($_.Exception.Message)") }

    try {
        if ($oldMoved -and -not (Test-Path -LiteralPath $destinationFull) -and (Test-Path -LiteralPath $backupRoot)) {
            Move-DirectoryAtomically $backupRoot $destinationFull
            $oldMoved = $false
        }
    }
    catch { $rollbackErrors.Add("Previous release restoration failed: $($_.Exception.Message)") }

    try {
        if ($archivePublished -and (Test-Path -LiteralPath $releaseArchivePath -PathType Leaf)) {
            Invoke-TransientFileSystemRetry "Failed release archive isolation ($releaseArchivePath)" {
                [IO.File]::Move((Convert-ToExtendedPath $releaseArchivePath), (Convert-ToExtendedPath $failedArchivePath))
            }
            if ($archiveBackupCreated -and (Test-Path -LiteralPath $archiveBackupPath -PathType Leaf)) {
                Invoke-TransientFileSystemRetry "Release archive restoration ($releaseArchivePath)" {
                    [IO.File]::Move((Convert-ToExtendedPath $archiveBackupPath), (Convert-ToExtendedPath $releaseArchivePath))
                }
                $archiveBackupCreated = $false
            }
            $archivePublished = $false
        }
    }
    catch { $rollbackErrors.Add("Previous LF release archive restoration failed: $($_.Exception.Message)") }

    if ($manifestPublished) {
        try {
            if ($null -ne $previousManifestBytes) {
                Set-AtomicFileBytes $manifestPath $previousManifestBytes
            }
            elseif (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                Remove-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
            }
        }
        catch { $rollbackErrors.Add("Previous manifest restoration failed: $($_.Exception.Message)") }
    }

    if ($rollbackErrors.Count -ne 0) {
        throw "Release publication failed and local rollback needs inspection. Original: $($publishError.Exception.Message) Rollback: $($rollbackErrors -join ' | ')"
    }
    throw $publishError
}
finally {
    if (Test-Path -LiteralPath $validationRoot -PathType Container) {
        Remove-Item -LiteralPath $validationRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $stagedManifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $stagedManifestPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $stagedArchivePath -PathType Leaf) {
        Remove-Item -LiteralPath $stagedArchivePath -Force -ErrorAction SilentlyContinue
    }
    if ($publicationSucceeded -and (Test-Path -LiteralPath $archiveBackupPath -PathType Leaf)) {
        try { Remove-Item -LiteralPath $archiveBackupPath -Force -ErrorAction Stop }
        catch { Write-Warning "Could not remove previous LF release archive backup: $archiveBackupPath ($($_.Exception.Message))" }
    }
    if ($null -ne $launcherArtifacts -and $launcherArtifacts.BuildRoot -and
        (Test-Path -LiteralPath $launcherArtifacts.BuildRoot -PathType Container)) {
        Remove-Item -LiteralPath $launcherArtifacts.BuildRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $lockStream) {
        try { $lockStream.Dispose() } catch {}
    }
    try {
        if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
        }
    }
    catch { Write-Warning "Could not remove canonical release lock file: $($_.Exception.Message)" }
}
