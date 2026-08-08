param(
    [string]$SourceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'release'),
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\portable-package-manifest.json')
)

$ErrorActionPreference = 'Stop'

if (-not ('CodexUsbPortable.ParallelHasher' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading.Tasks;

namespace CodexUsbPortable {
    public sealed class HashResult {
        public string Path;
        public long Length;
        public string Sha256;
    }

    public static class ParallelHasher {
        private static string Extended(string path) {
            string full = Path.GetFullPath(path);
            if (full.StartsWith(@"\\?\", StringComparison.Ordinal)) return full;
            if (full.StartsWith(@"\\", StringComparison.Ordinal)) return @"\\?\UNC\" + full.Substring(2);
            return @"\\?\" + full;
        }

        public static HashResult[] HashFiles(string[] paths, int maxDegreeOfParallelism) {
            HashResult[] results = new HashResult[paths.Length];
            ParallelOptions options = new ParallelOptions();
            options.MaxDegreeOfParallelism = Math.Max(1, maxDegreeOfParallelism);
            Parallel.For(0, paths.Length, options, delegate(int index) {
                string path = paths[index];
                using (FileStream stream = new FileStream(
                    Extended(path), FileMode.Open, FileAccess.Read, FileShare.Read,
                    1024 * 1024, FileOptions.SequentialScan)) {
                    using (SHA256 sha = SHA256.Create()) {
                        byte[] digest = sha.ComputeHash(stream);
                        results[index] = new HashResult {
                            Path = path,
                            Length = stream.Length,
                            Sha256 = BitConverter.ToString(digest).Replace("-", "")
                        };
                    }
                }
            });
            return results;
        }
    }
}
'@
}

function Convert-ToExtendedPath([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    if ($full.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $full }
    if ($full.StartsWith('\\', [StringComparison]::Ordinal)) {
        return '\\?\UNC\' + $full.Substring(2)
    }
    return '\\?\' + $full
}

function Get-PortableSha256([string]$path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath (Convert-ToExtendedPath $path)).Hash
}

function Get-RelativePortablePath([string]$root, [string]$path) {
    $relative = $path.Substring($root.Length).TrimStart('\').Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or
        $relative.StartsWith('/') -or
        $relative.Contains('\') -or
        $relative.Contains(':') -or
        @($relative.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) {
        throw "Unsafe package path: $relative"
    }
    $relative
}

function Test-PathAtOrUnder([string]$path, [string]$root) {
    $path.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith($root + '/', [StringComparison]::OrdinalIgnoreCase)
}

function Get-PeMachine([string]$path) {
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        if ($stream.Length -lt 64) { throw "PE file is too small: $path" }
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

function Read-PluginManifest([string]$path, [string]$label) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$label is missing its .codex-plugin/plugin.json: $path"
    }
    try {
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $manifest = [IO.File]::ReadAllText($path, $strictUtf8) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$label has an invalid plugin manifest: $path ($($_.Exception.Message))"
    }
    $version = [string]$manifest.version
    if ([string]::IsNullOrWhiteSpace($version) -or $version -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') {
        throw "$label has no safe semantic version in $path"
    }
    [pscustomobject]@{
        Name = [string]$manifest.name
        Version = $version
        Path = $path
    }
}

function Assert-VersionedPluginCache([string]$cacheRoot, [string]$catalog, [string[]]$requiredPlugins) {
    $catalogRoot = Join-Path $cacheRoot $catalog
    if (-not (Test-Path -LiteralPath $catalogRoot -PathType Container)) {
        throw "Portable plugin cache catalog is missing: $catalogRoot"
    }
    $catalogItem = Get-Item -LiteralPath $catalogRoot -Force
    if (($catalogItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Portable plugin cache catalog cannot be a reparse point: $catalogRoot"
    }
    $catalogFiles = @(Get-ChildItem -LiteralPath $catalogRoot -File -Force -ErrorAction Stop)
    if ($catalogFiles.Count -ne 0) {
        throw "Portable plugin cache catalog contains files outside plugin directories: $catalogRoot"
    }

    $pluginDirectories = @(Get-ChildItem -LiteralPath $catalogRoot -Directory -Force -ErrorAction Stop)
    $pluginNames = @($pluginDirectories | Select-Object -ExpandProperty Name | Sort-Object)
    $expectedNames = @($requiredPlugins | Sort-Object)
    if (@(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $pluginNames).Count -ne 0) {
        throw "Portable plugin cache catalog '$catalog' must contain exactly: $($expectedNames -join ', '); found: $($pluginNames -join ', ')"
    }
    $layout = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pluginDirectory in $pluginDirectories) {
        $directFiles = @(Get-ChildItem -LiteralPath $pluginDirectory.FullName -File -Force -ErrorAction Stop)
        if ($directFiles.Count -ne 0) {
            throw "Plugin cache entry is flattened; files must be below a version directory: $($pluginDirectory.FullName)"
        }
        $versionDirectories = @(Get-ChildItem -LiteralPath $pluginDirectory.FullName -Directory -Force -ErrorAction Stop)
        if ($versionDirectories.Count -eq 0) {
            throw "Plugin cache entry has no version directory: $($pluginDirectory.FullName)"
        }
        if (@($versionDirectories | Where-Object { $_.Name -eq '.codex-plugin' }).Count -ne 0) {
            throw "Plugin cache entry is flattened; .codex-plugin is directly below the plugin id: $($pluginDirectory.FullName)"
        }
        $manifestVersions = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($versionDirectory in $versionDirectories) {
            if (($versionDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Plugin cache version entry cannot be a reparse point: $($versionDirectory.FullName)"
            }
            $manifest = Read-PluginManifest (Join-Path $versionDirectory.FullName '.codex-plugin\plugin.json') "$catalog/$($pluginDirectory.Name)/$($versionDirectory.Name)"
            if ($versionDirectory.Name -ne 'latest' -and -not $versionDirectory.Name.Equals($manifest.Version, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Plugin cache version directory '$($versionDirectory.Name)' does not match manifest version '$($manifest.Version)' for $($pluginDirectory.Name)."
            }
            [void]$manifestVersions.Add($manifest.Version)
        }
        $layout.Add([pscustomobject]@{
            Catalog = $catalog
            Plugin = $pluginDirectory.Name
            Versions = @($manifestVersions | Sort-Object)
        })
    }
    return $layout.ToArray()
}

$managedFileRoots = @(
    'CodexPortable.exe',
    'CodexData/README.txt',
    'CodexData/THIRD_PARTY.txt'
)
$managedDirectoryRoots = @(
    'CodexData/app/current',
    'CodexData/tools'
)
$managedRoots = @(
    'CodexPortable.exe',
    'CodexData/app/current',
    'CodexData/tools',
    'CodexData/README.txt',
    'CodexData/THIRD_PARTY.txt'
)
$preservedRoots = @(
    'CodexData/data',
    'CodexData/logs',
    'CodexData/updates',
    'CodexData/app/rollback'
)

function Test-ManagedFilePath([string]$path) {
    foreach ($root in $managedFileRoots) {
        if ($path.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($root in $managedDirectoryRoots) {
        if ($path.StartsWith($root + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

function Test-ManagedDirectoryPath([string]$path) {
    if ($path -in @('CodexData', 'CodexData/app')) { return $true }
    foreach ($root in $managedDirectoryRoots) {
        if (Test-PathAtOrUnder $path $root) { return $true }
    }
    $false
}

function Test-PreservedPath([string]$path) {
    foreach ($root in $preservedRoots) {
        if (Test-PathAtOrUnder $path $root) { return $true }
    }
    $false
}

$source = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
$expectedRootEntries = @('CodexData', 'CodexPortable.exe')
$rootEntries = @(
    Get-ChildItem -LiteralPath $source -Force |
        Select-Object -ExpandProperty Name |
        Sort-Object
)
if (Compare-Object -ReferenceObject $expectedRootEntries -DifferenceObject $rootEntries) {
    throw "Unexpected source root entries: $($rootEntries -join ', ')"
}

# The desktop resolves plugins by catalog -> plugin id -> version.  A prior
# portable repair copied the plugin contents directly into the cache root,
# which looked non-empty but made every launch fail with "plugin cache
# incomplete".  Validate this contract while the release is still staged so
# a malformed package can never become canonical or be copied to USB.
$pluginCacheRoot = Join-Path $source 'CodexData\data\profile\.codex\plugins\cache'
$pluginLayout = @()
$pluginLayout += Assert-VersionedPluginCache $pluginCacheRoot 'openai-bundled' @('browser', 'chrome', 'computer-use', 'latex', 'visualize')
$pluginLayout += Assert-VersionedPluginCache $pluginCacheRoot 'openai-primary-runtime' @('documents', 'pdf', 'presentations', 'spreadsheets', 'template-creator')

$launcherPath = Join-Path $source 'CodexPortable.exe'
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    throw "Portable launcher is missing: $launcherPath"
}
Assert-PeMachine $launcherPath 0x014c 'release bootstrapper'
$launcherCoreRoot = Join-Path $source 'CodexData\tools\launchers'
$launcherCorePaths = [ordered]@{
    x86 = Join-Path $launcherCoreRoot 'CodexPortable.x86.exe'
    x64 = Join-Path $launcherCoreRoot 'CodexPortable.x64.exe'
    arm64 = Join-Path $launcherCoreRoot 'CodexPortable.arm64.exe'
}
Assert-PeMachine $launcherCorePaths.x86 0x014c 'x86 launcher core'
Assert-PeMachine $launcherCorePaths.x64 0x8664 'x64 launcher core'
Assert-PeMachine $launcherCorePaths.arm64 0xAA64 'ARM64 launcher core'
$desktopPayloads = [ordered]@{
    x64 = Join-Path $source 'CodexData\app\current'
    arm64 = Join-Path $source 'CodexData\tools\desktop-payloads\arm64\current'
}
foreach ($payload in $desktopPayloads.GetEnumerator()) {
    $official = Join-Path $payload.Value 'ChatGPT.exe'
    $alias = Join-Path $payload.Value 'CodexDesktop.exe'
    $codex = Join-Path $payload.Value 'resources\codex.exe'
    $asar = Join-Path $payload.Value 'resources\app.asar'
    foreach ($required in @($official, $alias, $codex, $asar)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required $($payload.Key) desktop payload file is missing: $required"
        }
    }
    $expectedMachine = if ($payload.Key -eq 'x64') { 0x8664 } else { 0xAA64 }
    Assert-PeMachine $official $expectedMachine "$($payload.Key) ChatGPT.exe"
    Assert-PeMachine $alias $expectedMachine "$($payload.Key) CodexDesktop.exe"
    Assert-PeMachine $codex $expectedMachine "$($payload.Key) resources/codex.exe"
}

$reparsePoints = @(
    Get-ChildItem -LiteralPath $source -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop |
        Select-Object -ExpandProperty FullName
)
if ($reparsePoints.Count -ne 0) {
    throw "Release source contains $($reparsePoints.Count) reparse points."
}
$directories = @(
    Get-ChildItem -LiteralPath $source -Recurse -Force -Directory -ErrorAction Stop |
        Sort-Object FullName
)
$files = @(
    Get-ChildItem -LiteralPath $source -Recurse -Force -File -ErrorAction Stop |
        Sort-Object FullName
)

$directoryEntries = @($directories | ForEach-Object { Get-RelativePortablePath $source $_.FullName })
$directorySet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($relativeDirectory in $directoryEntries) {
    if (-not $directorySet.Add($relativeDirectory)) {
        throw "Case-insensitive duplicate directory path: $relativeDirectory"
    }
}
$entries = New-Object 'System.Collections.Generic.List[object]'
$managedEntries = New-Object 'System.Collections.Generic.List[object]'
$fileSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$totalBytes = [long]0
$managedTotalBytes = [long]0
$largestFileBytes = [long]0
$managedLargestFileBytes = [long]0
$maxRelativePathChars = 0
$hashResults = [CodexUsbPortable.ParallelHasher]::HashFiles(
    [string[]]@($files | Select-Object -ExpandProperty FullName),
    [Math]::Min(16, [Environment]::ProcessorCount)
)
for ($index = 0; $index -lt $files.Count; $index++) {
    $file = $files[$index]
    $hashResult = $hashResults[$index]
    $totalBytes += [long]$hashResult.Length
    $relativePath = Get-RelativePortablePath $source $file.FullName
    if (-not $fileSet.Add($relativePath)) {
        throw "Case-insensitive duplicate file path: $relativePath"
    }
    $largestFileBytes = [math]::Max($largestFileBytes, [long]$hashResult.Length)
    $maxRelativePathChars = [math]::Max($maxRelativePathChars, $relativePath.Length)
    $entry = [pscustomobject]@{
        Path = $relativePath
        Length = [long]$hashResult.Length
        Sha256 = $hashResult.Sha256
    }
    $entries.Add($entry)
    if (Test-ManagedFilePath $relativePath) {
        $managedEntries.Add($entry)
        $managedTotalBytes += [long]$hashResult.Length
        $managedLargestFileBytes = [math]::Max($managedLargestFileBytes, [long]$hashResult.Length)
    }
    elseif (-not (Test-PreservedPath $relativePath)) {
        throw "Release file is outside the declared managed/preserved policy: $relativePath"
    }
}

$managedDirectoryEntries = New-Object 'System.Collections.Generic.List[string]'
$preservedDirectoryEntries = New-Object 'System.Collections.Generic.List[string]'
foreach ($relativeDirectory in $directoryEntries) {
    if (Test-ManagedDirectoryPath $relativeDirectory) {
        $managedDirectoryEntries.Add($relativeDirectory)
    }
    elseif (Test-PreservedPath $relativeDirectory) {
        $preservedDirectoryEntries.Add($relativeDirectory)
    }
    else {
        throw "Release directory is outside the declared managed/preserved policy: $relativeDirectory"
    }
}
$preservedEntries = @($entries | Where-Object { Test-PreservedPath ([string]$_.Path) })
$preservedTotalBytes = [long](@($preservedEntries | Measure-Object -Property Length -Sum).Sum)

$launcherVersion = (Get-Item -LiteralPath $launcherPath).VersionInfo.FileVersion
$manifest = [ordered]@{
    SchemaVersion = 3
    GeneratedUtc = [DateTime]::UtcNow.ToString('o')
    Package = 'Codex Portable USB'
    ManifestScope = 'Canonical release plus explicit non-destructive USB program/data policy'
    ArchitectureSupport = [ordered]@{
        Bootstrapper = 'x86'
        LauncherCores = @('x86', 'x64', 'arm64')
        DesktopPayloads = @('x64', 'arm64')
        X64 = 'supported'
        Arm64 = 'supported when the official ARM64 MSIX is present'
        X86 = 'launcher diagnostics only; the official Desktop x86 payload is not published'
        Arm = 'launcher diagnostics only; the official Desktop ARM payload is not published'
    }
    LauncherArtifacts = [ordered]@{
        Bootstrapper = 'CodexPortable.exe'
        X86 = 'CodexData/tools/launchers/CodexPortable.x86.exe'
        X64 = 'CodexData/tools/launchers/CodexPortable.x64.exe'
        Arm64 = 'CodexData/tools/launchers/CodexPortable.arm64.exe'
    }
    DesktopPayloadRoots = [ordered]@{
        X64 = 'CodexData/app/current'
        Arm64 = 'CodexData/tools/desktop-payloads/arm64/current'
    }
    PluginCacheLayout = $pluginLayout
    LauncherVersion = $launcherVersion
    LauncherSha256 = Get-PortableSha256 $launcherPath
    RootEntries = $rootEntries
    ReparsePoints = @()
    DirectoryCount = $directoryEntries.Count
    Directories = $directoryEntries
    FileCount = $entries.Count
    TotalBytes = $totalBytes
    LargestFileBytes = $largestFileBytes
    MaxRelativePathChars = $maxRelativePathChars
    ManagedRoots = $managedRoots
    PreservedRoots = $preservedRoots
    UnknownTargetEntriesPolicy = 'Preserve'
    ManagedSummary = [ordered]@{
        DirectoryCount = $managedDirectoryEntries.Count
        FileCount = $managedEntries.Count
        TotalBytes = $managedTotalBytes
        LargestFileBytes = $managedLargestFileBytes
    }
    PreservedReleaseSummary = [ordered]@{
        DirectoryCount = $preservedDirectoryEntries.Count
        FileCount = $preservedEntries.Count
        TotalBytes = $preservedTotalBytes
    }
    MutableAfterFirstRun = @(
        $preservedRoots
    )
    Files = $entries
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$json = $manifest | ConvertTo-Json -Depth 6
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$temporaryOutput = $outputFull + '.tmp-' + [guid]::NewGuid().ToString('N')
$replacementBackup = $null
try {
    [IO.File]::WriteAllText($temporaryOutput, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $outputFull -PathType Leaf) {
        $replacementBackup = $outputFull + '.replace-backup-' + [guid]::NewGuid().ToString('N')
        [IO.File]::Replace($temporaryOutput, $outputFull, $replacementBackup, $true)
    }
    else {
        [IO.File]::Move($temporaryOutput, $outputFull)
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryOutput) {
        Remove-Item -LiteralPath $temporaryOutput -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $replacementBackup -and (Test-Path -LiteralPath $replacementBackup -PathType Leaf)) {
        Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction SilentlyContinue
    }
}

[pscustomobject]@{
    OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
    FileCount = $manifest.FileCount
    TotalBytes = $manifest.TotalBytes
    LauncherVersion = $manifest.LauncherVersion
    LauncherSha256 = $manifest.LauncherSha256
    ManifestSha256 = Get-PortableSha256 $OutputPath
    DirectoryCount = $manifest.DirectoryCount
    LargestFileBytes = $manifest.LargestFileBytes
    MaxRelativePathChars = $manifest.MaxRelativePathChars
    ReparsePointCount = $manifest.ReparsePoints.Count
    ManagedRoots = $manifest.ManagedRoots
    PreservedRoots = $manifest.PreservedRoots
    ManagedDirectoryCount = $manifest.ManagedSummary.DirectoryCount
    ManagedFileCount = $manifest.ManagedSummary.FileCount
    ManagedTotalBytes = $manifest.ManagedSummary.TotalBytes
} | ConvertTo-Json -Depth 5
