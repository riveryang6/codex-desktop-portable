param(
    [string]$SourceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'payload'),
    [string]$DestinationRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'release'),
    [string]$ReleaseParentRoot = (Split-Path -Parent $PSScriptRoot),
    # LauncherPath is retained for callers that already built a bootstrapper.
    # When omitted, the release transaction builds an architecture matrix from
    # portable-launcher/build-launcher-matrix.ps1 and uses its x86 bootstrapper.
    [string]$LauncherPath,
    [string]$X86LauncherPath,
    [string]$X64LauncherPath,
    [string]$Arm64LauncherPath,
    [string]$LauncherMatrixRoot,
    [string]$Arm64MsixPath,
    [string]$Arm64MsixUrl = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-arm64.msix',
    [string]$Arm64MsixCachePath,
    [switch]$SkipUsbSync,
    [ValidateRange(0, 86400)]
    [int]$WaitForPortableExitSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Set-AtomicFileBytes([string]$path, [byte[]]$bytes) {
    $full = [IO.Path]::GetFullPath($path)
    $temporary = $full + '.tmp-' + [guid]::NewGuid().ToString('N')
    $replacementBackup = $null
    try {
        [IO.File]::WriteAllBytes($temporary, $bytes)
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $replacementBackup = $full + '.replace-backup-' + [guid]::NewGuid().ToString('N')
            [IO.File]::Replace($temporary, $full, $replacementBackup, $true)
        }
        else {
            [IO.File]::Move($temporary, $full)
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
    [IO.Directory]::Move($sourceFull, $destinationFull)
}

function Get-StrictJson([string]$path) {
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    [IO.File]::ReadAllText($path, $strictUtf8) | ConvertFrom-Json -ErrorAction Stop
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

function Assert-PortablePayload([string]$payloadRoot, [int]$expectedMachine, [string]$architecture) {
    $official = Join-Path $payloadRoot 'ChatGPT.exe'
    $alias = Join-Path $payloadRoot 'CodexDesktop.exe'
    $codex = Join-Path $payloadRoot 'resources\codex.exe'
    $asar = Join-Path $payloadRoot 'resources\app.asar'
    $marker = Join-Path $payloadRoot '.portable-package.txt'
    foreach ($required in @($official, $alias, $codex, $asar, $marker)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "$architecture payload is incomplete; missing $required"
        }
    }
    Assert-PeMachine $official $expectedMachine "$architecture ChatGPT.exe"
    Assert-PeMachine $alias $expectedMachine "$architecture CodexDesktop.exe"
    Assert-PeMachine $codex $expectedMachine "$architecture resources/codex.exe"
    $officialHash = (Get-FileHash -LiteralPath $official -Algorithm SHA256).Hash
    $aliasHash = (Get-FileHash -LiteralPath $alias -Algorithm SHA256).Hash
    if (-not $officialHash.Equals($aliasHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$architecture CodexDesktop.exe is not byte-identical to ChatGPT.exe."
    }
    if ((Get-Item -LiteralPath $asar).Length -lt 1024) {
        throw "$architecture app.asar is unexpectedly small: $asar"
    }
    $markerLines = [IO.File]::ReadAllLines($marker, (New-Object Text.UTF8Encoding($false, $true)))
    if ($markerLines.Length -lt 5 -or
        -not [string]::Equals($markerLines[0].Trim(), 'OpenAI.Codex', [StringComparison]::Ordinal) -or
        -not [string]::Equals($markerLines[1].Trim(), 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B', [StringComparison]::Ordinal) -or
        -not [string]::Equals($markerLines[3].Trim(), $architecture, [StringComparison]::OrdinalIgnoreCase) -or
        $markerLines[4].Trim() -notmatch '^sha256=[A-Fa-f0-9]{64}$') {
        throw "$architecture payload package marker is invalid: $marker"
    }
}

function Invoke-LauncherCommand([string]$launcher, [string]$root, [string[]]$arguments) {
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
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Launcher command failed with exit code $($process.ExitCode): $launcher $($arguments -join ' ')"
        }
    }
    finally { $process.Dispose() }
}

function Resolve-LauncherArtifacts([string]$explicitBootstrapper, [string]$explicitX86,
    [string]$explicitX64, [string]$explicitArm64, [string]$matrixRoot,
    [string]$launcherProjectRoot, [string]$buildRoot) {
    $builder = Join-Path $launcherProjectRoot 'build-launcher-matrix.ps1'
    if (-not [string]::IsNullOrWhiteSpace($explicitBootstrapper)) {
        $bootstrap = (Resolve-Path -LiteralPath $explicitBootstrapper).Path
        $variantDirectory = Join-Path (Split-Path -Parent $bootstrap) 'CodexData\tools\launchers'
        $paths = [ordered]@{
            Bootstrapper = $bootstrap
            X86 = if ([string]::IsNullOrWhiteSpace($explicitX86)) { Join-Path $variantDirectory 'CodexPortable.x86.exe' } else { (Resolve-Path -LiteralPath $explicitX86).Path }
            X64 = if ([string]::IsNullOrWhiteSpace($explicitX64)) { Join-Path $variantDirectory 'CodexPortable.x64.exe' } else { (Resolve-Path -LiteralPath $explicitX64).Path }
            Arm64 = if ([string]::IsNullOrWhiteSpace($explicitArm64)) { Join-Path $variantDirectory 'CodexPortable.arm64.exe' } else { (Resolve-Path -LiteralPath $explicitArm64).Path }
            BuildRoot = $null
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($matrixRoot)) {
            $matrixRoot = Join-Path $launcherProjectRoot 'matrix-output'
        }
        $candidateFiles = @(
            (Join-Path $matrixRoot 'CodexPortable.exe'),
            (Join-Path $matrixRoot 'CodexData\tools\launchers\CodexPortable.x86.exe'),
            (Join-Path $matrixRoot 'CodexData\tools\launchers\CodexPortable.x64.exe'),
            (Join-Path $matrixRoot 'CodexData\tools\launchers\CodexPortable.arm64.exe')
        )
        if (@($candidateFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -ne 0) {
            if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) {
                throw "Launcher matrix is incomplete and builder is missing: $builder"
            }
            & $builder -OutputRoot $buildRoot | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Launcher matrix build failed with exit code $LASTEXITCODE." }
            $matrixRoot = $buildRoot
        }
        $paths = [ordered]@{
            Bootstrapper = Join-Path $matrixRoot 'CodexPortable.exe'
            X86 = Join-Path $matrixRoot 'CodexData\tools\launchers\CodexPortable.x86.exe'
            X64 = Join-Path $matrixRoot 'CodexData\tools\launchers\CodexPortable.x64.exe'
            Arm64 = Join-Path $matrixRoot 'CodexData\tools\launchers\CodexPortable.arm64.exe'
            BuildRoot = if ($matrixRoot.Equals($buildRoot, [StringComparison]::OrdinalIgnoreCase)) { $buildRoot } else { $null }
        }
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
    [pscustomobject]$paths
}

function Get-Arm64Msix([string]$requestedPath, [string]$url, [string]$cachePath) {
    if (-not [string]::IsNullOrWhiteSpace($requestedPath)) {
        $resolved = (Resolve-Path -LiteralPath $requestedPath).Path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "ARM64 MSIX is missing: $requestedPath" }
        return $resolved
    }
    if ([string]::IsNullOrWhiteSpace($cachePath)) {
        $cachePath = Join-Path $releaseParentFull 'downloads\ChatGPT-arm64.msix'
    }
    $cacheDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($cachePath))
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        if ([string]::IsNullOrWhiteSpace($url)) { throw 'ARM64 MSIX path and download URL are both empty.' }
        $temporary = $cachePath + '.download-' + [guid]::NewGuid().ToString('N')
        try {
            Invoke-WebRequest -Uri $url -OutFile $temporary -UseBasicParsing
            if ((Get-Item -LiteralPath $temporary).Length -lt 100MB) {
                throw 'Downloaded ARM64 MSIX is unexpectedly small.'
            }
            [IO.File]::Move($temporary, $cachePath)
        }
        finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        }
    }
    (Resolve-Path -LiteralPath $cachePath).Path
}

function Expand-MsixPayload([string]$msixPath, [string]$destinationRoot) {
    $tar = Join-Path $env:WINDIR 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) { throw "Windows tar.exe is unavailable: $tar" }
    New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $tar
    $info.Arguments = '-xf "' + $msixPath.Replace('"', '\"') + '" -C "' + $destinationRoot.Replace('"', '\"') + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw 'Unable to start tar.exe for ARM64 MSIX extraction.' }
    try {
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "ARM64 MSIX extraction failed: $errorText" }
    }
    finally { $process.Dispose() }
    $nested = Join-Path $destinationRoot 'app'
    if (Test-Path -LiteralPath (Join-Path $nested 'ChatGPT.exe') -PathType Leaf) { return $nested }
    if (Test-Path -LiteralPath (Join-Path $destinationRoot 'ChatGPT.exe') -PathType Leaf) { return $destinationRoot }
    throw 'Extracted ARM64 MSIX does not contain ChatGPT.exe.'
}

function Decode-MsixNames([string]$root) {
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Sort-Object @{ Expression = { $_.FullName.Length }; Descending = $true })
    foreach ($item in $files) {
        if ($item.Name.IndexOf('%') -lt 0) { continue }
        $decoded = [Uri]::UnescapeDataString($item.Name)
        if ([string]::Equals($item.Name, $decoded, [StringComparison]::Ordinal)) { continue }
        if ([string]::IsNullOrWhiteSpace($decoded) -or $decoded -in @('.', '..') -or
            $decoded.EndsWith('.') -or $decoded.EndsWith(' ') -or
            $decoded.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "Unsafe URI-escaped MSIX file name: $($item.Name)"
        }
        $target = Join-Path $item.DirectoryName $decoded
        if (Test-Path -LiteralPath $target) { throw "MSIX file name collision after URI decoding: $target" }
        [IO.File]::Move($item.FullName, $target)
    }
    $directories = @(Get-ChildItem -LiteralPath $root -Recurse -Force -Directory |
        Sort-Object @{ Expression = { ($_.FullName -split '[\\/]').Count }; Descending = $true },
            @{ Expression = { $_.FullName.Length }; Descending = $true })
    foreach ($item in $directories) {
        if ($item.Name.IndexOf('%') -lt 0) { continue }
        $decoded = [Uri]::UnescapeDataString($item.Name)
        if ([string]::Equals($item.Name, $decoded, [StringComparison]::Ordinal)) { continue }
        if ([string]::IsNullOrWhiteSpace($decoded) -or $decoded -in @('.', '..') -or
            $decoded.EndsWith('.') -or $decoded.EndsWith(' ') -or
            $decoded.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "Unsafe URI-escaped MSIX directory name: $($item.Name)"
        }
        $target = Join-Path $item.Parent.FullName $decoded
        if (Test-Path -LiteralPath $target) { throw "MSIX directory name collision after URI decoding: $target" }
        [IO.Directory]::Move($item.FullName, $target)
    }
}

function Get-ValidatedAppxIdentity([string]$manifestPath, [string]$expectedArchitecture) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Extracted MSIX manifest is missing: $manifestPath"
    }
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    $document = New-Object Xml.XmlDocument
    $document.PreserveWhitespace = $true
    $document.LoadXml([IO.File]::ReadAllText($manifestPath, $strictUtf8))
    $identity = $document.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']")
    if ($null -eq $identity) { throw 'Extracted MSIX manifest has no package identity.' }
    $result = [ordered]@{
        Name = [string]$identity.GetAttribute('Name')
        Publisher = [string]$identity.GetAttribute('Publisher')
        Version = [string]$identity.GetAttribute('Version')
        Architecture = [string]$identity.GetAttribute('ProcessorArchitecture')
    }
    $parsedVersion = $null
    if (-not [string]::Equals($result.Name, 'OpenAI.Codex', [StringComparison]::Ordinal) -or
        -not [string]::Equals($result.Publisher, 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B', [StringComparison]::Ordinal) -or
        -not [string]::Equals($result.Architecture, $expectedArchitecture, [StringComparison]::OrdinalIgnoreCase) -or
        -not [Version]::TryParse($result.Version, [ref]$parsedVersion)) {
        throw 'Extracted MSIX identity, publisher, version, or architecture is invalid.'
    }
    [pscustomobject]$result
}

$source = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
$destinationFull = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')
$releaseParentFull = [IO.Path]::GetFullPath($ReleaseParentRoot).TrimEnd('\')
$readmeTemplate = Join-Path $PSScriptRoot 'CodexData-README.txt'
$manifestScript = Join-Path $PSScriptRoot 'New-PortablePackageManifest.ps1'
$syncScript = Join-Path $PSScriptRoot 'Sync-CodexPortableUsb.ps1'
$manifestPath = Join-Path $PSScriptRoot 'portable-package-manifest.json'
$syncReceiptPath = Join-Path $PSScriptRoot 'last-usb-program-sync.json'
$launcherProjectRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'portable-launcher'
$launcherMatrixBuilder = Join-Path $launcherProjectRoot 'build-launcher-matrix.ps1'
if (-not $destinationFull.Equals((Join-Path $releaseParentFull 'release'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Destination must be exactly $(Join-Path $releaseParentFull 'release')"
}
if (-not (Test-Path -LiteralPath $readmeTemplate -PathType Leaf)) {
    throw "Portable README template is missing: $readmeTemplate"
}
foreach ($requiredTool in @($manifestScript, $syncScript, $launcherMatrixBuilder)) {
    if (-not (Test-Path -LiteralPath $requiredTool -PathType Leaf)) {
        throw "Required release tool is missing: $requiredTool"
    }
}
if (-not (Test-Path -LiteralPath $releaseParentFull -PathType Container)) {
    throw "Release parent is missing: $releaseParentFull"
}
if ((Test-PathWithin $source $destinationFull) -or (Test-PathWithin $destinationFull $source)) {
    throw 'Release source and canonical destination must be separate non-nested directories.'
}
Assert-NoReparsePointInAncestry $source
Assert-NoReparsePointInAncestry $releaseParentFull
Assert-NoReparsePointInAncestry $PSScriptRoot

$expectedRootEntries = @('CodexData', 'CodexPortable.exe')
$sourceRootEntries = @(Get-ChildItem -LiteralPath $source -Force | Select-Object -ExpandProperty Name | Sort-Object)
if (Compare-Object -ReferenceObject $expectedRootEntries -DifferenceObject $sourceRootEntries) {
    throw "Unexpected source root entries: $($sourceRootEntries -join ', ')"
}
$processInventory = @(Get-CimInstance Win32_Process -ErrorAction Stop)
if ($processInventory.Count -eq 0 -or @($processInventory | Where-Object { [int]$_.ProcessId -eq $PID }).Count -ne 1) {
    throw 'Unable to establish a complete current-process inventory; release build refused.'
}
$sourceProcesses = @(
    $processInventory | Where-Object {
        [int]$_.ProcessId -ne $PID -and
            -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
            (Test-PathWithin ([string]$_.ExecutablePath) $source)
    }
)
if ($sourceProcesses.Count -ne 0) {
    throw "Portable source processes must be stopped: $($sourceProcesses.Name -join ', ')"
}

$nonce = [guid]::NewGuid().ToString('N')
$shortId = $nonce.Substring(0, 8)
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$stageRoot = Join-Path $releaseParentFull ('release.stage-' + $shortId)
$backupRoot = Join-Path $releaseParentFull ('release.backup-' + $timestamp + '-' + $shortId)
$failedRoot = Join-Path $releaseParentFull ('release.failed-' + $shortId)
$stagedManifestPath = Join-Path $releaseParentFull ('.portable-package-manifest-' + $shortId + '.json')
$lockPath = Join-Path $releaseParentFull '.portable-release.lock'
$launcherBuildRoot = Join-Path $releaseParentFull ('.launcher-matrix-' + $shortId)
$launcherArtifacts = $null
$canonicalLauncher = $null
foreach ($temporaryPath in @($stageRoot, $backupRoot, $failedRoot, $stagedManifestPath)) {
    if (Test-Path -LiteralPath $temporaryPath) { throw "Release transaction path already exists: $temporaryPath" }
}
if (Test-Path -LiteralPath $launcherBuildRoot) {
    throw "Launcher matrix transaction path already exists: $launcherBuildRoot"
}
try {
    $launcherArtifacts = Resolve-LauncherArtifacts $LauncherPath $X86LauncherPath $X64LauncherPath $Arm64LauncherPath `
        $LauncherMatrixRoot $launcherProjectRoot $launcherBuildRoot
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

try {
    $previousManifestBytes = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        [IO.File]::ReadAllBytes($manifestPath)
    } else { $null }
    New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop | Out-Null

    & robocopy.exe $source $stageRoot /E /COPY:DAT /DCOPY:DAT /R:3 /W:2 /MT:16 /XJ /NFL /NDL /NP
    $copyExitCode = $LASTEXITCODE
    if ($copyExitCode -ge 8) {
        throw "Release copy failed with robocopy exit code $copyExitCode."
    }

    $releaseLauncher = Join-Path $stageRoot 'CodexPortable.exe'
    Copy-Item -LiteralPath $canonicalLauncher -Destination $releaseLauncher -Force

    # The root entry is deliberately the x86 bootstrapper. It is the only
    # executable that is safe to double-click before Windows architecture is
    # known; the matching core is selected from CodexData\tools\launchers.
    $launcherDirectory = Join-Path $stageRoot 'CodexData\tools\launchers'
    New-Item -ItemType Directory -Path $launcherDirectory -Force | Out-Null
    Copy-Item -LiteralPath $launcherArtifacts.X86 -Destination (Join-Path $launcherDirectory 'CodexPortable.x86.exe') -Force
    Copy-Item -LiteralPath $launcherArtifacts.X64 -Destination (Join-Path $launcherDirectory 'CodexPortable.x64.exe') -Force
    Copy-Item -LiteralPath $launcherArtifacts.Arm64 -Destination (Join-Path $launcherDirectory 'CodexPortable.arm64.exe') -Force
    Assert-PeMachine $releaseLauncher 0x014c 'staged bootstrapper'
    Assert-PeMachine (Join-Path $launcherDirectory 'CodexPortable.x86.exe') 0x014c 'staged x86 launcher core'
    Assert-PeMachine (Join-Path $launcherDirectory 'CodexPortable.x64.exe') 0x8664 'staged x64 launcher core'
    Assert-PeMachine (Join-Path $launcherDirectory 'CodexPortable.arm64.exe') 0xAA64 'staged ARM64 launcher core'

    $payloadRoot = Join-Path $stageRoot 'CodexData\app\current'
    $stagedX64Launcher = Join-Path $launcherDirectory 'CodexPortable.x64.exe'
    Invoke-LauncherCommand $stagedX64Launcher $stageRoot @('--prepare-payload', $payloadRoot)
    Assert-PortablePayload $payloadRoot 0x8664 'x64'

    $arm64Msix = Get-Arm64Msix $Arm64MsixPath $Arm64MsixUrl $Arm64MsixCachePath
    # Validate the Authenticode signature and the pinned Appx identity,
    # then extract only into the transaction staging tree. The x64 core
    # performs the same WinVerifyTrust/manifest checks used by updates and
    # accepts an explicit arm64 expectation for cross-architecture builds.
    Invoke-LauncherCommand $stagedX64Launcher $stageRoot @('--self-test-msix', $arm64Msix, 'arm64')
    $arm64Extraction = Join-Path $stageRoot '.arm64-msix-extract'
    $arm64ExtractedRoot = Expand-MsixPayload $arm64Msix $arm64Extraction
    Decode-MsixNames $arm64Extraction
    $arm64Identity = Get-ValidatedAppxIdentity (Join-Path $arm64Extraction 'AppxManifest.xml') 'arm64'
    $arm64ExtractedRoot = if (Test-Path -LiteralPath (Join-Path $arm64Extraction 'app\ChatGPT.exe') -PathType Leaf) {
        Join-Path $arm64Extraction 'app'
    } else { $arm64Extraction }
    $arm64PayloadRoot = Join-Path $stageRoot 'CodexData\tools\desktop-payloads\arm64\current'
    New-Item -ItemType Directory -Path (Split-Path -Parent $arm64PayloadRoot) -Force | Out-Null
    if (Test-Path -LiteralPath $arm64PayloadRoot) {
        throw "ARM64 payload destination unexpectedly exists: $arm64PayloadRoot"
    }
    [IO.Directory]::Move([IO.Path]::GetFullPath($arm64ExtractedRoot), [IO.Path]::GetFullPath($arm64PayloadRoot))
    $arm64MsixHash = (Get-FileHash -LiteralPath $arm64Msix -Algorithm SHA256).Hash.ToUpperInvariant()
    $arm64MarkerText = $arm64Identity.Name + "`r`n" + $arm64Identity.Publisher + "`r`n" +
        $arm64Identity.Version + "`r`n" + $arm64Identity.Architecture + "`r`nsha256=" + $arm64MsixHash + "`r`n"
    Set-AtomicFileBytes (Join-Path $arm64PayloadRoot '.portable-package.txt') `
        ((New-Object Text.UTF8Encoding($false)).GetBytes($arm64MarkerText))
    if (Test-Path -LiteralPath $arm64Extraction) {
        Remove-Item -LiteralPath $arm64Extraction -Recurse -Force
    }
    Invoke-LauncherCommand $stagedX64Launcher $stageRoot @('--prepare-payload', $arm64PayloadRoot)
    Assert-PortablePayload $arm64PayloadRoot 0xAA64 'ARM64'
    Copy-Item -LiteralPath $readmeTemplate -Destination (Join-Path $stageRoot 'CodexData\README.txt') -Force

    $profile = Join-Path $stageRoot 'CodexData\data\profile'
    $codexState = Join-Path $profile '.codex'
    $exactTransientPaths = @(
        (Join-Path $stageRoot 'CodexData\logs'),
        (Join-Path $profile 'temp'),
        (Join-Path $profile 'cache\chromium'),
        (Join-Path $codexState 'sqlite'),
        (Join-Path $codexState 'log'),
        (Join-Path $codexState 'logs'),
        (Join-Path $codexState 'sessions'),
        (Join-Path $codexState 'archived_sessions'),
        (Join-Path $codexState 'rollout'),
        (Join-Path $profile 'electron\sentry'),
        (Join-Path $profile 'electron\Crashpad'),
        (Join-Path $profile 'electron\ShaderCache'),
        (Join-Path $profile 'electron\GrShaderCache'),
        (Join-Path $profile 'electron\GPUPersistentCache'),
        (Join-Path $profile 'electron\Default\Cache'),
        (Join-Path $profile 'electron\Default\Code Cache'),
        (Join-Path $profile 'electron\Default\GPUCache'),
        (Join-Path $profile 'electron\Default\Local Storage'),
        (Join-Path $profile 'electron\Default\Session Storage'),
        (Join-Path $profile 'electron\Default\Sessions'),
        (Join-Path $profile 'electron\Default\Partitions\codex-browser-app'),
        (Join-Path $profile 'appdata\local\OpenAI\extension'),
        (Join-Path $profile 'appdata\local\Codex\Logs')
    )
    $removed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $exactTransientPaths) {
        $full = [IO.Path]::GetFullPath($path)
        if (-not $full.StartsWith($stageRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing out-of-release cleanup path: $full"
        }
        if (Test-Path -LiteralPath $full) {
            Remove-Item -LiteralPath $full -Recurse -Force
            $removed.Add($full.Substring($stageRoot.Length).TrimStart('\'))
        }
    }

    $transientFiles = @(
        Get-ChildItem -LiteralPath $codexState -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like '*.sqlite' -or
                $_.Name -like '*.sqlite-shm' -or
                $_.Name -like '*.sqlite-wal'
            }
    )
    $electronRoot = Join-Path $profile 'electron'
    $electronTransientFiles = @(
        Get-ChildItem -LiteralPath $electronRoot -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'BrowserMetrics*' }
    )
    $browserProfile = Join-Path $electronRoot 'Default'
    $browserTransientFiles = @(
        Get-ChildItem -LiteralPath $browserProfile -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -in @(
                    'History', 'History-journal', 'Login Data', 'Login Data-journal',
                    'Login Data For Account', 'Login Data For Account-journal',
                    'Cookies', 'Cookies-journal', 'Web Data', 'Web Data-journal'
                )
            }
    )
    $networkProfile = Join-Path $browserProfile 'Network'
    $networkTransientFiles = @(
        Get-ChildItem -LiteralPath $networkProfile -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -in @(
                    'Cookies', 'Cookies-journal',
                    'Device Bound Sessions', 'Device Bound Sessions-journal',
                    'Network Persistent State', 'TransportSecurity'
                )
            }
    )
    $exactChromiumLogPaths = @(
        (Join-Path $browserProfile 'Extension State\LOG'),
        (Join-Path $browserProfile 'GCM Store\Encryption\LOG'),
        (Join-Path $browserProfile 'GCM Store\LOG'),
        (Join-Path $browserProfile 'shared_proto_db\LOG'),
        (Join-Path $browserProfile 'shared_proto_db\metadata\LOG'),
        (Join-Path $browserProfile 'Site Characteristics Database\LOG'),
        (Join-Path $browserProfile 'Sync Data\LevelDB\LOG')
    )
    $exactChromiumLogFiles = @(
        $exactChromiumLogPaths |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            ForEach-Object { Get-Item -LiteralPath $_ }
    )
    foreach ($file in @($transientFiles + $electronTransientFiles + $browserTransientFiles + $networkTransientFiles + $exactChromiumLogFiles)) {
        $full = [IO.Path]::GetFullPath($file.FullName)
        if (-not $full.StartsWith($stageRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing out-of-release cleanup file: $full"
        }
        Remove-Item -LiteralPath $full -Force
        $removed.Add($full.Substring($stageRoot.Length).TrimStart('\'))
    }

    $bootstrapConfig = Join-Path $codexState 'config.toml'
    if (Test-Path -LiteralPath $bootstrapConfig) {
        Remove-Item -LiteralPath $bootstrapConfig -Force
        $removed.Add($bootstrapConfig.Substring($stageRoot.Length).TrimStart('\'))
    }

    foreach ($directory in @(
        (Join-Path $profile 'temp'),
        (Join-Path $profile 'cache'),
        (Join-Path $profile 'cache\chromium')
    )) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $releaseRootEntries = @(Get-ChildItem -LiteralPath $stageRoot -Force | Select-Object -ExpandProperty Name | Sort-Object)
    if (Compare-Object -ReferenceObject $expectedRootEntries -DifferenceObject $releaseRootEntries) {
        throw "Unexpected release root entries: $($releaseRootEntries -join ', ')"
    }
    $reparsePoints = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop)
    if ($reparsePoints.Count -ne 0) {
        throw "Release contains $($reparsePoints.Count) reparse points."
    }
    foreach ($forbidden in @(
        (Join-Path $stageRoot 'CodexData\data\profile\.codex\auth.json'),
        (Join-Path $stageRoot 'CodexData\data\secrets\api-key.txt'),
        (Join-Path $stageRoot 'CodexData\data\secrets\api-vault.xml'),
        (Join-Path $stageRoot 'CodexData\data\config\custom-api-url.txt'),
        (Join-Path $stageRoot 'CodexData\data\config\custom-model.txt')
    )) {
        if (Test-Path -LiteralPath $forbidden) {
            throw "Release contains forbidden authentication/config state: $forbidden"
        }
    }

    $rg = Join-Path $stageRoot 'CodexData\app\current\resources\rg.exe'
    $profileTextGlobs = @(
        '--hidden', '--fixed-strings', '--files-with-matches',
        '--glob', '*.json', '--glob', '*.toml', '--glob', '*.jsonl', '--glob', '*.ini', '--glob', '*.txt',
        '--glob', '*.log', '--glob', '*.old'
    )
    $oldDriveMatches = New-Object 'System.Collections.Generic.List[string]'
    foreach ($needle in @('R:\CodexData', 'R:\\CodexData', 'S:\CodexData', 'S:\\CodexData')) {
        $matches = @(& $rg @profileTextGlobs -- $needle $profile 2>$null)
        $oldDriveExitCode = $LASTEXITCODE
        if ($oldDriveExitCode -notin @(0, 1)) {
            throw "Old-drive scan failed with exit code $oldDriveExitCode."
        }
        foreach ($match in $matches) { $oldDriveMatches.Add([string]$match) }
    }
    if ($oldDriveMatches.Count -ne 0) {
        throw "Release retains removed R:/S: paths: $($oldDriveMatches -join ', ')"
    }
    $dummyMatches = @(& $rg @profileTextGlobs -- 'portable-vm-dummy-key' (Join-Path $stageRoot 'CodexData\data') 2>$null)
    $dummyExitCode = $LASTEXITCODE
    if ($dummyExitCode -notin @(0, 1)) {
        throw "Dummy-key scan failed with exit code $dummyExitCode."
    }
    if ($dummyMatches.Count -ne 0) {
        throw "Release retains dummy-key material: $($dummyMatches -join ', ')"
    }

    $measure = Get-ChildItem -LiteralPath $stageRoot -Recurse -Force -File | Measure-Object Length -Sum
    $stageLauncherHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stageRoot 'CodexPortable.exe')).Hash

    $manifestOutput = @(& $manifestScript -SourceRoot $stageRoot -OutputPath $stagedManifestPath)
    if (-not (Test-Path -LiteralPath $stagedManifestPath -PathType Leaf)) {
        throw 'Manifest generator did not create the staged canonical manifest.'
    }
    $manifestHash = (Get-FileHash -LiteralPath $stagedManifestPath -Algorithm SHA256).Hash
    $manifest = Get-StrictJson $stagedManifestPath
    if ([int]$manifest.SchemaVersion -ne 3 -or [string]$manifest.Package -ne 'Codex Portable USB' -or
        -not ([string]$manifest.LauncherSha256).Equals($stageLauncherHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staged release manifest is unsupported or does not match the staged launcher.'
    }
    $x64AsarEntries = @($manifest.Files | Where-Object {
        [string]$_.Path -ceq 'CodexData/app/current/resources/app.asar'
    })
    $arm64AsarEntries = @($manifest.Files | Where-Object {
        [string]$_.Path -ceq 'CodexData/tools/desktop-payloads/arm64/current/resources/app.asar'
    })
    if ($x64AsarEntries.Count -ne 1 -or $arm64AsarEntries.Count -ne 1 -or
        [string]$x64AsarEntries[0].Sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        [string]$arm64AsarEntries[0].Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Staged release manifest lacks unique x64 and ARM64 app.asar hashes.'
    }
    $stageAsarHash = ([string]$x64AsarEntries[0].Sha256).ToUpperInvariant()
    $stageArm64AsarHash = ([string]$arm64AsarEntries[0].Sha256).ToUpperInvariant()

    $canonicalProcesses = @(
        Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            [int]$_.ProcessId -ne $PID -and
                -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
                (Test-PathWithin ([string]$_.ExecutablePath) $destinationFull)
        }
    )
    if ($canonicalProcesses.Count -ne 0) {
        throw "Canonical release processes must be stopped before publication: $($canonicalProcesses.Name -join ', ')"
    }

    if (Test-Path -LiteralPath $destinationFull) {
        Move-DirectoryAtomically $destinationFull $backupRoot
        $oldMoved = $true
    }
    Move-DirectoryAtomically $stageRoot $destinationFull
    $newMoved = $true
    Set-AtomicFileBytes $manifestPath ([IO.File]::ReadAllBytes($stagedManifestPath))
    $manifestPublished = $true

    $syncOutput = @()
    $syncReceipt = $null
    $usbProgramSync = 'Skipped'
    if (-not $SkipUsbSync) {
        $syncArguments = @{
            SourceRoot = $destinationFull
            ManifestPath = $manifestPath
            ExpectedManifestSha256 = $manifestHash
            WaitForPortableExitSeconds = $WaitForPortableExitSeconds
            Execute = $true
            Confirm = $false
        }
        $syncOutput = @(& $syncScript @syncArguments)
        if (-not (Test-Path -LiteralPath $syncReceiptPath -PathType Leaf)) {
            throw "USB synchronization did not create its canonical receipt: $syncReceiptPath"
        }
        $syncReceipt = Get-StrictJson $syncReceiptPath
        if ([string]$syncReceipt.Status -cne 'Synced' -or
            -not ([string]$syncReceipt.ManifestSha256).Equals($manifestHash, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$syncReceipt.AsarSha256).Equals($stageAsarHash, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$syncReceipt.SourceRoot).Equals($destinationFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'USB synchronization receipt is not Synced for this exact canonical release and manifest.'
        }
        $usbProgramSync = 'Synced'
    }

    $releaseResult = [ordered]@{
        Status = if ($SkipUsbSync) { 'PublishedOnly' } else { 'PublishedAndUsbSynced' }
        SourceRoot = $source
        LauncherSource = $canonicalLauncher
        LauncherBootstrapperArchitecture = 'x86'
        LauncherCoreArchitectures = @('x86', 'x64', 'arm64')
        DesktopPayloadArchitectures = @('x64', 'arm64')
        DestinationRoot = $destinationFull
        PreviousReleaseBackup = if ($oldMoved) { $backupRoot } else { $null }
        RobocopyExitCode = $copyExitCode
        FileCount = $measure.Count
        TotalBytes = [long]$measure.Sum
        LauncherSha256 = $stageLauncherHash
        AsarSha256 = $stageAsarHash
        Arm64AsarSha256 = $stageArm64AsarHash
        Arm64MsixSha256 = $arm64MsixHash
        ManifestSchemaVersion = [int]$manifest.SchemaVersion
        ManifestSha256 = $manifestHash
        ManagedSummary = $manifest.ManagedSummary
        ReparsePointCount = 0
        RemovedDrivePathMatches = 0
        DummyKeyMatches = 0
        RemovedItems = $removed
        UsbProgramSync = $usbProgramSync
        UsbProgramSyncReceipt = if ($null -ne $syncReceipt) { $syncReceiptPath } else { $null }
        UsbProgramSyncOutput = $syncOutput
        ManifestGeneratorOutput = $manifestOutput
    }
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
    if (Test-Path -LiteralPath $stagedManifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $stagedManifestPath -Force -ErrorAction SilentlyContinue
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
