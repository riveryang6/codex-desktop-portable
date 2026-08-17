param(
    [string]$SourceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'release'),
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\portable-package-manifest.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The manifest is generated from a compact release.  Keep hashing parallel,
# but never enumerate the expanded desktop payload or user profile here.
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

Add-Type -AssemblyName System.IO.Compression.FileSystem

$portableReleaseDescriptorPath = 'CodexData/portable-release.json'
$portableReleaseDescriptorFiles = @(
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

function Convert-ToExtendedPath([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    if ($full.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $full }
    if ($full.StartsWith('\\', [StringComparison]::Ordinal)) { return '\\?\UNC\' + $full.Substring(2) }
    return '\\?\' + $full
}

function Convert-FromExtendedPath([string]$path) {
    if ($path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { return '\\' + $path.Substring(8) }
    if ($path.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $path.Substring(4) }
    return $path
}

function Test-TransientFileSystemContention([Exception]$exception) {
    $current = $exception
    while ($null -ne $current) {
        if ($current -is [IO.IOException]) {
            # Retry only Windows ERROR_SHARING_VIOLATION and ERROR_LOCK_VIOLATION.
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

function Get-PortableSha256([string]$path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath (Convert-ToExtendedPath $path)).Hash.ToUpperInvariant()
}

function Get-StrictJson([string]$path, [string]$label) {
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    try { [IO.File]::ReadAllText((Convert-ToExtendedPath $path), $utf8) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "$label is not strict UTF-8 JSON: $($_.Exception.Message)" }
}

function Assert-ExactPropertySet([object]$value, [string[]]$expected, [string]$label) {
    $actual = @($value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actual.Count -ne $expected.Count -or
        @($expected | Where-Object { -not ($actual -ccontains $_) }).Count -ne 0 -or
        @($actual | Where-Object { -not ($expected -ccontains $_) }).Count -ne 0) {
        throw "$label has an unsupported property set: $($actual -join ', ')"
    }
}

function Assert-PortableReleaseDescriptor([string]$path, [string]$expectedVersion, [hashtable]$expectedMetadata) {
    $descriptor = Get-StrictJson $path 'portable-release.json'
    Assert-ExactPropertySet $descriptor @('SchemaVersion', 'ReleaseVersion', 'LauncherVersion', 'Files') 'portable-release.json'
    if ([int]$descriptor.SchemaVersion -ne 1 -or
        -not ([string]$descriptor.ReleaseVersion).Equals($expectedVersion, [StringComparison]::Ordinal) -or
        -not ([string]$descriptor.LauncherVersion).Equals($expectedVersion, [StringComparison]::Ordinal)) {
        throw 'portable-release.json schema or version does not match the launcher set.'
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $files = @($descriptor.Files)
    if ($files.Count -ne $portableReleaseDescriptorFiles.Count) {
        throw "portable-release.json must contain exactly $($portableReleaseDescriptorFiles.Count) file entries."
    }
    foreach ($entry in $files) {
        Assert-ExactPropertySet $entry @('Path', 'Length', 'Sha256') 'portable-release.json file entry'
        $relative = [string]$entry.Path
        if (-not ($portableReleaseDescriptorFiles -ccontains $relative) -or -not $seen.Add($relative)) {
            throw "portable-release.json contains an unexpected or duplicate file entry: $relative"
        }
        $expected = $expectedMetadata[$relative]
        if ($null -eq $expected -or [long]$entry.Length -ne [long]$expected.Length -or
            -not ([string]$entry.Sha256).Equals([string]$expected.Sha256, [StringComparison]::Ordinal)) {
            throw "portable-release.json hash or length differs for: $relative"
        }
    }
    foreach ($relative in $portableReleaseDescriptorFiles) {
        if (-not $seen.Contains($relative)) { throw "portable-release.json is missing: $relative" }
    }
    [pscustomobject]@{
        SchemaVersion = 1
        ReleaseVersion = [string]$descriptor.ReleaseVersion
        LauncherVersion = [string]$descriptor.LauncherVersion
        FileCount = $files.Count
    }
}

function Get-RelativePortablePath([string]$root, [string]$path) {
    $root = Convert-FromExtendedPath $root
    $path = Convert-FromExtendedPath $path
    $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($path)
    if (-not $pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside source root: $path"
    }
    $relative = $pathFull.Substring($rootFull.Length).TrimStart('\').Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or
        $relative.StartsWith('/') -or
        $relative.Contains(':') -or
        @($relative.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) {
        throw "Unsafe package path: $relative"
    }
    return $relative
}

function Assert-ExactStringSet([string[]]$expected, [string[]]$actual, [string]$label) {
    $expected = @($expected)
    $actual = @($actual)
    if ($expected.Count -ne $actual.Count) {
        throw "$label has unexpected entries: $($actual -join ', ')"
    }
    foreach ($entry in $expected) {
        if (-not ($actual -ccontains $entry)) { throw "$label is missing required entry: $entry" }
    }
    foreach ($entry in $actual) {
        if (-not ($expected -ccontains $entry)) { throw "$label contains an unexpected entry: $entry" }
    }
}

function Get-PeMachine([string]$path) {
    $stream = [IO.File]::Open((Convert-ToExtendedPath $path), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        if ($stream.Length -lt 64) { throw "PE file is too small: $path" }
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "PE file has no MZ header: $path" }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        if ($offset -lt 0 -or $offset -gt ($stream.Length - 6)) { throw "PE header offset is invalid: $path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "PE file has no signature: $path" }
        return [int]$reader.ReadUInt16()
    }
    finally { $stream.Dispose() }
}

function Assert-PeMachine([string]$path, [int]$expected, [string]$label) {
    $actual = Get-PeMachine $path
    if ($actual -ne $expected) { throw ("{0} has PE machine 0x{1:X4}; expected 0x{2:X4}." -f $label, $actual, $expected) }
}

function Get-ArchiveAttributes([IO.Compression.ZipArchiveEntry]$entry) {
    # ExternalAttributes is a signed Int32 in some .NET versions.
    return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
}

function Get-SafeArchiveEntryPath([string]$name, [string]$label) {
    if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.StartsWith('\') -or $name.Contains(':') -or
        $name -match '[\x00-\x1F]') { throw "$label contains an unsafe archive path: $name" }
    $isDirectory = $name.EndsWith('/') -or $name.EndsWith('\')
    $clean = $name.Replace('\', '/').TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($clean) -or @($clean.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) {
        throw "$label contains an unsafe archive path: $name"
    }
    foreach ($segment in $clean.Split('/')) {
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "$label contains a Windows-unsafe archive path: $name"
        }
    }
    [pscustomobject]@{ Path = $clean; IsDirectory = $isDirectory }
}

function Assert-ArchiveEntryAttributes([IO.Compression.ZipArchiveEntry]$entry, [string]$label) {
    $attributes = Get-ArchiveAttributes $entry
    $unixType = ($attributes -shr 16) -band 0xF000
    if ($unixType -eq 0xA000 -or (($attributes -band 0x400) -ne 0)) {
        throw "$label contains a symbolic link or reparse-point archive entry: $($entry.FullName)"
    }
}

function Read-ZipEntryText([IO.Compression.ZipArchiveEntry]$entry, [string]$label, [long]$maxBytes = 1048576) {
    if ($entry.Length -gt $maxBytes) { throw "$label is too large to parse safely: $($entry.FullName)" }
    $stream = $entry.Open()
    try {
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        $reader = New-Object IO.StreamReader($stream, $encoding, $true)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Assert-ArchiveReadable([IO.Compression.ZipArchiveEntry]$entry, [string]$label) {
    $stream = $entry.Open()
    try {
        $buffer = New-Object byte[] (1024 * 1024)
        [long]$actualLength = 0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($actualLength -gt ([long]::MaxValue - $read)) { throw "$label has an unrepresentable uncompressed size: $($entry.FullName)" }
            $actualLength += $read
        }
        if ($actualLength -ne [long]$entry.Length) { throw "$label length mismatch for $($entry.FullName)" }
    }
    finally { $stream.Dispose() }
}

function Assert-CommonZip([string]$path) {
    $allowedRoots = @(
        'tools/dotnet',
        'tools/gh',
        'data/profile/.cache/codex-runtimes',
        'data/profile/.codex/offline-marketplaces'
    )
    $requiredPrimaryRuntimePlugins = @('documents', 'pdf', 'presentations', 'spreadsheets', 'template-creator')
    $requiredFiles = @(
        'tools/dotnet/dotnet.exe',
        'data/profile/.cache/codex-runtimes/codex-primary-runtime/runtime.json',
        'data/profile/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe',
        'data/profile/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe',
        'data/profile/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/git/cmd/git.exe',
        'data/profile/.codex/offline-marketplaces/openai-primary-runtime/.agents/plugins/marketplace.json'
    ) + @($requiredPrimaryRuntimePlugins | ForEach-Object {
            "data/profile/.codex/offline-marketplaces/openai-primary-runtime/plugins/$_/.codex-plugin/plugin.json"
        })
    $ghAlternatives = @('tools/gh/gh.exe', 'tools/gh/bin/gh.exe')
    $archiveInfo = Get-Item -LiteralPath $path -Force
    if ($archiveInfo.Length -lt (100L * 1024L * 1024L) -or $archiveInfo.Length -gt (4L * 1024L * 1024L * 1024L)) {
        throw "Invalid LFPortable-common.zip: compressed size is outside the supported range: $($archiveInfo.Length)"
    }
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead((Convert-ToExtendedPath $path))
        $entries = @($zip.Entries)
        if ($entries.Count -eq 0) { throw 'LFPortable-common.zip is empty.' }
        if ($entries.Count -gt 100000) { throw 'LFPortable-common.zip has too many entries.' }
        $byPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        $pathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [long]$uncompressedBytes = 0
        [long]$compressedBytes = 0
        $fileEntries = New-Object 'System.Collections.Generic.List[object]'
        $rootFiles = @{}
        foreach ($entry in $entries) {
            Assert-ArchiveEntryAttributes $entry 'LFPortable-common.zip'
            $safe = Get-SafeArchiveEntryPath $entry.FullName 'LFPortable-common.zip'
            if (-not $pathSet.Add($safe.Path)) { throw "LFPortable-common.zip contains a duplicate path (case-insensitive): $($safe.Path)" }
            if ($safe.Path.Equals('data/profile/.codex/plugins/cache', [StringComparison]::OrdinalIgnoreCase) -or
                $safe.Path.StartsWith('data/profile/.codex/plugins/cache/', [StringComparison]::OrdinalIgnoreCase)) {
                throw "LFPortable-common.zip must not preseed the derived plugin cache: $($safe.Path)"
            }
            if ($safe.Path -match '^tools/dotnet/sdk/[^/]+/FSharp(?:/|$)') {
                throw "LFPortable-common.zip must not contain the unused F# SDK subtree: $($safe.Path)"
            }
            foreach ($root in $allowedRoots) {
                if ($safe.Path.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
                    $safe.Path.StartsWith($root + '/', [StringComparison]::OrdinalIgnoreCase)) {
                    if (-not $safe.IsDirectory) { $rootFiles[$root] = $true }
                    break
                }
            }
            $matchedRoot = @($allowedRoots | Where-Object {
                $safe.Path.Equals($_, [StringComparison]::OrdinalIgnoreCase) -or
                    $safe.Path.StartsWith($_ + '/', [StringComparison]::OrdinalIgnoreCase) -or
                    ($safe.IsDirectory -and $_.StartsWith($safe.Path + '/', [StringComparison]::OrdinalIgnoreCase))
            })
            if ($matchedRoot.Count -eq 0) { throw "LFPortable-common.zip contains an entry outside the whitelist: $($safe.Path)" }
            if ($entry.Length -lt 0 -or $entry.CompressedLength -lt 0) { throw "LFPortable-common.zip contains an invalid entry length: $($safe.Path)" }
            if ($uncompressedBytes -gt ([long]::MaxValue - [long]$entry.Length) -or $compressedBytes -gt ([long]::MaxValue - [long]$entry.CompressedLength)) { throw 'LFPortable-common.zip size totals overflow Int64.' }
            $uncompressedBytes += [long]$entry.Length
            $compressedBytes += [long]$entry.CompressedLength
            [void]$byPath.Add($safe.Path, $entry)
            if (-not $safe.IsDirectory) { [void]$fileEntries.Add($entry) }
        }
        foreach ($required in $requiredFiles) {
            if (-not $byPath.ContainsKey($required) -or $byPath[$required].Length -le 0) { throw "LFPortable-common.zip is missing required entry: $required" }
        }
        $ghEntry = @($ghAlternatives | Where-Object { $byPath.ContainsKey($_) -and $byPath[$_].Length -gt 0 })
        if ($ghEntry.Count -ne 1) { throw 'LFPortable-common.zip must contain exactly one supported GitHub CLI entry.' }
        foreach ($root in $allowedRoots) {
            if (-not $rootFiles.ContainsKey($root)) { throw "LFPortable-common.zip has no file under required root: $root" }
        }
        if ($uncompressedBytes -lt (500L * 1024L * 1024L) -or $uncompressedBytes -gt (4L * 1024L * 1024L * 1024L)) {
            throw "LFPortable-common.zip uncompressed size is outside the supported range: $uncompressedBytes"
        }

        $csharpSdkVersions = @{}
        $visualBasicSdkVersions = @{}
        foreach ($entryPath in $byPath.Keys) {
            if ($entryPath -match '^tools/dotnet/sdk/(?<version>[^/]+)/Roslyn/bincore/csc\.dll$') {
                $csharpSdkVersions[$matches['version']] = $true
            }
            if ($entryPath -match '^tools/dotnet/sdk/(?<version>[^/]+)/Roslyn/bincore/vbc\.dll$') {
                $visualBasicSdkVersions[$matches['version']] = $true
            }
        }
        $compilerSdkVersions = @($csharpSdkVersions.Keys | Where-Object { $visualBasicSdkVersions.ContainsKey($_) })
        if ($compilerSdkVersions.Count -eq 0) {
            throw 'LFPortable-common.zip must retain one .NET SDK containing both C# and Visual Basic compilers.'
        }
        foreach ($entry in $fileEntries) { Assert-ArchiveReadable $entry 'LFPortable-common.zip' }
        $runtimeJson = Read-ZipEntryText $byPath['data/profile/.cache/codex-runtimes/codex-primary-runtime/runtime.json'] 'Runtime metadata' | ConvertFrom-Json -ErrorAction Stop
        if ([string]$runtimeJson.targetPlatform -ne 'win32' -or [string]$runtimeJson.targetArch -notin @('x64', 'arm64')) { throw 'Runtime metadata has an unsupported target platform or architecture.' }
        $marketplace = Read-ZipEntryText $byPath['data/profile/.codex/offline-marketplaces/openai-primary-runtime/.agents/plugins/marketplace.json'] 'Offline marketplace metadata' | ConvertFrom-Json -ErrorAction Stop
        if ([string]$marketplace.name -ne 'openai-primary-runtime') { throw 'Offline marketplace metadata has an unexpected name.' }
        $marketplacePlugins = @($marketplace.plugins | Select-Object -ExpandProperty name)
        Assert-ExactStringSet $requiredPrimaryRuntimePlugins $marketplacePlugins 'Offline marketplace plugin list'
        foreach ($plugin in @($marketplace.plugins)) {
            $pluginName = [string]$plugin.name
            if ($requiredPrimaryRuntimePlugins -cnotcontains $pluginName -or
                [string]$plugin.source.source -ne 'local' -or [string]$plugin.source.path -ne "./plugins/$pluginName") {
                throw "Offline marketplace metadata contains an unexpected or unsafe plugin source: $pluginName"
            }
        }
        $pluginSourceLayout = New-Object 'System.Collections.Generic.List[string]'
        foreach ($plugin in $requiredPrimaryRuntimePlugins) {
            $manifestPath = "data/profile/.codex/offline-marketplaces/openai-primary-runtime/plugins/$plugin/.codex-plugin/plugin.json"
            $pluginJson = Read-ZipEntryText $byPath[$manifestPath] "Offline plugin manifest $manifestPath" | ConvertFrom-Json -ErrorAction Stop
            $manifestName = [string]$pluginJson.name
            $manifestVersion = [string]$pluginJson.version
            if (-not $manifestName.Equals($plugin, [StringComparison]::Ordinal) -or
                [string]::IsNullOrWhiteSpace($manifestVersion) -or
                $manifestVersion.Equals('latest', [StringComparison]::OrdinalIgnoreCase) -or
                $manifestVersion -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') {
                throw "Offline plugin manifest is unsafe or inconsistent: $manifestPath"
            }
            $pluginSourceLayout.Add("openai-primary-runtime/$plugin/$manifestVersion")
        }
        return [pscustomobject]@{
            Path = 'CodexData/packages/LFPortable-common.zip'
            EntryCount = $entries.Count
            FileCount = $fileEntries.Count
            UncompressedBytes = $uncompressedBytes
            CompressedBytes = $compressedBytes
            AllowedRoots = $allowedRoots
            RequiredEntries = $requiredFiles
            RequiredEntryGroups = @([ordered]@{ Name = 'GitHub CLI'; AnyOf = $ghAlternatives })
            PluginCacheLayout = @()
            PluginSourceLayout = @($pluginSourceLayout | Sort-Object)
        }
    }
    catch { throw "Invalid LFPortable-common.zip: $($_.Exception.Message)" }
    finally { if ($null -ne $zip) { $zip.Dispose() } }
}

function Assert-MsixPackage([string]$path, [string]$expectedArchitecture) {
    $requiredBundledPlugins = if ($expectedArchitecture -ceq 'x64') {
        @('sites', 'browser', 'chrome', 'computer-use', 'latex', 'deep-research', 'visualize')
    }
    else {
        @('sites', 'browser', 'chrome', 'computer-use', 'deep-research', 'visualize')
    }
    $bundledPluginPrefix = 'app/resources/plugins/openai-bundled/plugins/'
    $requiredEntries = @(
        'AppxManifest.xml', 'app/ChatGPT.exe', 'app/resources/app.asar', 'app/resources/codex.exe'
    ) + @($requiredBundledPlugins | ForEach-Object {
            "$bundledPluginPrefix$_/.codex-plugin/plugin.json"
        })
    $archiveInfo = Get-Item -LiteralPath $path -Force
    if ($archiveInfo.Length -lt (100L * 1024L * 1024L) -or $archiveInfo.Length -gt (3L * 1024L * 1024L * 1024L)) {
        throw "Invalid $([IO.Path]::GetFileName($path)): package size is outside the supported range: $($archiveInfo.Length)"
    }
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead((Convert-ToExtendedPath $path))
        $entries = @($zip.Entries)
        if ($entries.Count -eq 0) { throw 'MSIX archive is empty.' }
        $byPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        $pathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [long]$uncompressedBytes = 0
        foreach ($entry in $entries) {
            Assert-ArchiveEntryAttributes $entry 'MSIX package'
            $safe = Get-SafeArchiveEntryPath $entry.FullName 'MSIX package'
            if (-not $pathSet.Add($safe.Path)) { throw "MSIX contains a duplicate path (case-insensitive): $($safe.Path)" }
            if ($entry.Length -lt 0 -or $entry.Length -gt [long]::MaxValue - $uncompressedBytes) { throw 'MSIX uncompressed size totals overflow Int64.' }
            $uncompressedBytes += [long]$entry.Length
            [void]$byPath.Add($safe.Path, $entry)
        }
        foreach ($required in $requiredEntries) {
            if (-not $byPath.ContainsKey($required)) { throw "MSIX is missing required entry: $required" }
            if ($byPath[$required].Length -le 0) { throw "MSIX required entry is empty: $required" }
        }
        $bundledPluginSources = New-Object 'System.Collections.Generic.List[string]'
        foreach ($plugin in $requiredBundledPlugins) {
            $manifestPath = "$bundledPluginPrefix$plugin/.codex-plugin/plugin.json"
            $pluginJson = Read-ZipEntryText $byPath[$manifestPath] "MSIX bundled plugin manifest $manifestPath" |
                ConvertFrom-Json -ErrorAction Stop
            $manifestName = [string]$pluginJson.name
            $manifestVersion = [string]$pluginJson.version
            if (-not $manifestName.Equals($plugin, [StringComparison]::Ordinal) -or
                [string]::IsNullOrWhiteSpace($manifestVersion) -or
                $manifestVersion.Equals('latest', [StringComparison]::OrdinalIgnoreCase) -or
                $manifestVersion -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') {
                throw "MSIX bundled plugin manifest is unsafe or inconsistent: $manifestPath"
            }
            $bundledPluginSources.Add("openai-bundled/$plugin/$manifestVersion")
        }
        $manifestText = Read-ZipEntryText $byPath['AppxManifest.xml'] 'MSIX AppxManifest.xml'
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $document = New-Object Xml.XmlDocument
        $document.XmlResolver = $null
        $manifestReader = [Xml.XmlReader]::Create((New-Object IO.StringReader($manifestText)), $settings)
        try { $document.Load($manifestReader) }
        finally { $manifestReader.Dispose() }
        $identity = $document.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Identity"]')
        if ($null -eq $identity) { throw 'MSIX AppxManifest.xml has no Identity.' }
        $name = [string]$identity.GetAttribute('Name')
        $publisher = [string]$identity.GetAttribute('Publisher')
        $architecture = [string]$identity.GetAttribute('ProcessorArchitecture')
        $version = [string]$identity.GetAttribute('Version')
        if ($name -ne 'OpenAI.Codex' -or $publisher -ne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B' -or
            $architecture -ne $expectedArchitecture -or $version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
            throw "MSIX identity mismatch: Name=$name, Publisher=$publisher, ProcessorArchitecture=$architecture, Version=$version"
        }
        $application = $document.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Applications"]/*[local-name()="Application"]')
        if ($null -eq $application -or [string]$application.GetAttribute('Executable') -ne 'app/ChatGPT.exe') { throw 'MSIX application executable is not app/ChatGPT.exe.' }
        $publisherDisplayName = $document.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Properties"]/*[local-name()="PublisherDisplayName"]')
        if ($null -eq $publisherDisplayName -or $publisherDisplayName.InnerText.Trim() -ne 'OpenAI') { throw 'MSIX publisher display name is not OpenAI.' }
        return [pscustomobject]@{
            Path = [IO.Path]::GetFileName($path)
            Name = $name
            Publisher = $publisher
            ProcessorArchitecture = $architecture
            Version = $version
            EntryCount = $entries.Count
            UncompressedBytes = $uncompressedBytes
            RequiredEntries = $requiredEntries
            BundledPluginSources = @($bundledPluginSources | Sort-Object)
        }
    }
    catch { throw "Invalid $([IO.Path]::GetFileName($path)): $($_.Exception.Message)" }
    finally { if ($null -ne $zip) { $zip.Dispose() } }
}

$source = (Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop).Path.TrimEnd('\')
$sourceItem = Get-Item -LiteralPath $source -Force
if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Source release root cannot be a reparse point.' }

$expectedRootEntries = @('CodexData', 'CodexPortable.exe')
$rootEntries = @(Get-ChildItem -LiteralPath $source -Force | Select-Object -ExpandProperty Name)
Assert-ExactStringSet $expectedRootEntries $rootEntries 'Source root'

$expectedDirectories = @('CodexData', 'CodexData/packages', 'CodexData/tools', 'CodexData/tools/launchers')
$expectedFiles = @(
    'CodexPortable.exe',
    'CodexData/README.txt',
    'CodexData/THIRD_PARTY.txt',
    'CodexData/portable-release.json',
    'CodexData/tools/launchers/CodexPortable.x86.exe',
    'CodexData/tools/launchers/CodexPortable.x64.exe',
    'CodexData/tools/launchers/CodexPortable.arm64.exe',
    'CodexData/packages/LFPortable-common.zip',
    'CodexData/packages/LFPortable-x64.msix',
    'CodexData/packages/LFPortable-arm64.msix'
)
$extendedSource = Convert-ToExtendedPath $source
$reparsePoints = @(Get-ChildItem -LiteralPath $extendedSource -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop | Select-Object -ExpandProperty FullName)
if ($reparsePoints.Count -ne 0) { throw "Release source contains $($reparsePoints.Count) reparse points." }
$directories = @(Get-ChildItem -LiteralPath $extendedSource -Recurse -Force -Directory -ErrorAction Stop | ForEach-Object { Get-RelativePortablePath $source $_.FullName })
$files = @(Get-ChildItem -LiteralPath $extendedSource -Recurse -Force -File -ErrorAction Stop | ForEach-Object { Get-RelativePortablePath $source $_.FullName })
Assert-ExactStringSet $expectedDirectories $directories 'Canonical directories'
Assert-ExactStringSet $expectedFiles $files 'Canonical files'

$launcherPath = Join-Path $source 'CodexPortable.exe'
$launcherCorePaths = [ordered]@{
    x86 = Join-Path $source 'CodexData\tools\launchers\CodexPortable.x86.exe'
    x64 = Join-Path $source 'CodexData\tools\launchers\CodexPortable.x64.exe'
    arm64 = Join-Path $source 'CodexData\tools\launchers\CodexPortable.arm64.exe'
}
Assert-PeMachine $launcherPath 0x014c 'release bootstrapper'
Assert-PeMachine $launcherCorePaths.x86 0x014c 'x86 launcher core'
Assert-PeMachine $launcherCorePaths.x64 0x8664 'x64 launcher core'
Assert-PeMachine $launcherCorePaths.arm64 0xAA64 'ARM64 launcher core'
$launcherVersion = [string](Get-Item -LiteralPath $launcherPath).VersionInfo.FileVersion
if ([string]::IsNullOrWhiteSpace($launcherVersion)) { throw "Release bootstrapper has no file version: $launcherPath" }
foreach ($launcherCore in @($launcherCorePaths.GetEnumerator())) {
    $coreVersion = [string](Get-Item -LiteralPath $launcherCore.Value).VersionInfo.FileVersion
    if (-not $coreVersion.Equals($launcherVersion, [StringComparison]::OrdinalIgnoreCase)) { throw "Launcher version mismatch: bootstrapper $launcherVersion, $($launcherCore.Key) core $coreVersion." }
}

foreach ($relative in $expectedFiles) {
    if ((Get-Item -LiteralPath (Join-Path $source ($relative -replace '/', '\')) -Force).Length -le 0) { throw "Canonical file is empty: $relative" }
}
$commonPath = Join-Path $source 'CodexData\packages\LFPortable-common.zip'
$x64MsixPath = Join-Path $source 'CodexData\packages\LFPortable-x64.msix'
$arm64MsixPath = Join-Path $source 'CodexData\packages\LFPortable-arm64.msix'
$commonSummary = Assert-CommonZip $commonPath
$x64Summary = Assert-MsixPackage $x64MsixPath 'x64'
$arm64Summary = Assert-MsixPackage $arm64MsixPath 'arm64'
if ($x64Summary.Version -ne $arm64Summary.Version -or $x64Summary.Publisher -ne $arm64Summary.Publisher) { throw 'x64 and ARM64 MSIX identities do not match.' }

$fileObjects = @(Get-ChildItem -LiteralPath $extendedSource -Recurse -Force -File -ErrorAction Stop | Sort-Object FullName)
$hashResults = [CodexUsbPortable.ParallelHasher]::HashFiles([string[]]@($fileObjects | Select-Object -ExpandProperty FullName), [Math]::Min(16, [Environment]::ProcessorCount))
$entries = New-Object 'System.Collections.Generic.List[object]'
$fileSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[long]$totalBytes = 0
[long]$largestFileBytes = 0
$maxRelativePathChars = 0
for ($index = 0; $index -lt $fileObjects.Count; $index++) {
    $hashResult = $hashResults[$index]
    $relativePath = Get-RelativePortablePath $source $fileObjects[$index].FullName
    if (-not $fileSet.Add($relativePath)) { throw "Case-insensitive duplicate file path: $relativePath" }
    if ($totalBytes -gt ([long]::MaxValue - [long]$hashResult.Length)) { throw 'Canonical release size totals overflow Int64.' }
    $totalBytes += [long]$hashResult.Length
    $largestFileBytes = [math]::Max($largestFileBytes, [long]$hashResult.Length)
    $maxRelativePathChars = [math]::Max($maxRelativePathChars, $relativePath.Length)
    [void]$entries.Add([pscustomobject]@{ Path = $relativePath; Length = [long]$hashResult.Length; Sha256 = $hashResult.Sha256.ToUpperInvariant() })
}
$entryByPath = @{}
foreach ($entry in $entries) { $entryByPath[$entry.Path] = $entry }
$descriptorMetadata = @{}
foreach ($relative in $portableReleaseDescriptorFiles) {
    $descriptorMetadata[$relative] = $entryByPath[$relative]
}
$portableReleaseDescriptor = Assert-PortableReleaseDescriptor (Join-Path $source ($portableReleaseDescriptorPath -replace '/', '\')) `
    $launcherVersion $descriptorMetadata
$managedRoots = @('CodexPortable.exe', 'CodexData/tools/launchers', 'CodexData/packages', 'CodexData/README.txt', 'CodexData/THIRD_PARTY.txt', 'CodexData/portable-release.json')
$managedEntries = @($entries | Where-Object {
    $_.Path -eq 'CodexPortable.exe' -or $_.Path -eq 'CodexData/README.txt' -or $_.Path -eq 'CodexData/THIRD_PARTY.txt' -or $_.Path -eq 'CodexData/portable-release.json' -or
    $_.Path.StartsWith('CodexData/tools/launchers/', [StringComparison]::OrdinalIgnoreCase) -or
    $_.Path.StartsWith('CodexData/packages/', [StringComparison]::OrdinalIgnoreCase)
})
$managedTotalBytes = [long](@($managedEntries | Measure-Object -Property Length -Sum).Sum)
$managedLargestFileBytes = [long](@($managedEntries | Measure-Object -Property Length -Maximum).Maximum)

$manifest = [ordered]@{
    SchemaVersion = 4
    GeneratedUtc = [DateTime]::UtcNow.ToString('o')
    Package = 'Codex Portable USB'
    ManifestScope = 'Compact canonical release; desktop payload and profile/runtime data are first-run package contents'
    Packaging = 'CompressedFirstRun'
    ArchitectureSupport = [ordered]@{
        Bootstrapper = 'x86'
        LauncherCores = @('x86', 'x64', 'arm64')
        DesktopPackages = @('x64', 'arm64')
    }
    LauncherArtifacts = [ordered]@{
        Bootstrapper = 'CodexPortable.exe'
        X86 = 'CodexData/tools/launchers/CodexPortable.x86.exe'
        X64 = 'CodexData/tools/launchers/CodexPortable.x64.exe'
        Arm64 = 'CodexData/tools/launchers/CodexPortable.arm64.exe'
    }
    PackageArtifacts = [ordered]@{
        Common = [ordered]@{ Path = 'CodexData/packages/LFPortable-common.zip'; Length = $entryByPath['CodexData/packages/LFPortable-common.zip'].Length; Sha256 = $entryByPath['CodexData/packages/LFPortable-common.zip'].Sha256; Format = 'zip'; EntryCount = $commonSummary.EntryCount; FileCount = $commonSummary.FileCount; UncompressedBytes = $commonSummary.UncompressedBytes; CompressedEntryBytes = $commonSummary.CompressedBytes; AllowedRoots = $commonSummary.AllowedRoots; RequiredEntries = $commonSummary.RequiredEntries; RequiredEntryGroups = $commonSummary.RequiredEntryGroups; PluginCacheLayout = $commonSummary.PluginCacheLayout; PluginSourceLayout = $commonSummary.PluginSourceLayout }
        X64 = [ordered]@{ Path = 'CodexData/packages/LFPortable-x64.msix'; Length = $entryByPath['CodexData/packages/LFPortable-x64.msix'].Length; Sha256 = $entryByPath['CodexData/packages/LFPortable-x64.msix'].Sha256; Format = 'msix'; Identity = $x64Summary }
        Arm64 = [ordered]@{ Path = 'CodexData/packages/LFPortable-arm64.msix'; Length = $entryByPath['CodexData/packages/LFPortable-arm64.msix'].Length; Sha256 = $entryByPath['CodexData/packages/LFPortable-arm64.msix'].Sha256; Format = 'msix'; Identity = $arm64Summary }
    }
    LauncherVersion = $launcherVersion
    # The LF release tag and the launcher set are one versioned unit. The
    # official MSIX identity is recorded separately under PackageArtifacts.
    ReleaseVersion = $launcherVersion
    PortableReleaseDescriptor = [ordered]@{
        Path = $portableReleaseDescriptorPath
        SchemaVersion = $portableReleaseDescriptor.SchemaVersion
        ReleaseVersion = $portableReleaseDescriptor.ReleaseVersion
        LauncherVersion = $portableReleaseDescriptor.LauncherVersion
        FileCount = $portableReleaseDescriptor.FileCount
        Length = $entryByPath[$portableReleaseDescriptorPath].Length
        Sha256 = $entryByPath[$portableReleaseDescriptorPath].Sha256
    }
    LauncherSha256 = $entryByPath['CodexPortable.exe'].Sha256
    RootEntries = $expectedRootEntries
    ReparsePoints = @()
    DirectoryCount = $expectedDirectories.Count
    Directories = $expectedDirectories
    FileCount = $entries.Count
    TotalBytes = $totalBytes
    LargestFileBytes = $largestFileBytes
    MaxRelativePathChars = $maxRelativePathChars
    ManagedRoots = $managedRoots
    PreservedRoots = @()
    UnknownTargetEntriesPolicy = 'Preserve'
    ManagedSummary = [ordered]@{ DirectoryCount = $expectedDirectories.Count; FileCount = $managedEntries.Count; TotalBytes = $managedTotalBytes; LargestFileBytes = $managedLargestFileBytes }
    PreservedReleaseSummary = [ordered]@{ DirectoryCount = 0; FileCount = 0; TotalBytes = 0 }
    MutableAfterFirstRun = @('CodexData/app', 'CodexData/data', 'CodexData/logs', 'CodexData/updates')
    Files = $entries
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$temporaryOutput = $outputFull + '.tmp-' + [guid]::NewGuid().ToString('N')
$replacementBackup = $null
try {
    $json = $manifest | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($temporaryOutput, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $outputFull -PathType Leaf) {
        $replacementBackup = $outputFull + '.replace-backup-' + [guid]::NewGuid().ToString('N')
        Invoke-TransientFileSystemRetry "Manifest replacement ($outputFull)" {
            [IO.File]::Replace($temporaryOutput, $outputFull, $replacementBackup, $true)
        }
    }
    else {
        Invoke-TransientFileSystemRetry "Manifest move ($outputFull)" {
            [IO.File]::Move($temporaryOutput, $outputFull)
        }
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryOutput) { Remove-Item -LiteralPath $temporaryOutput -Force -ErrorAction SilentlyContinue }
    if ($null -ne $replacementBackup -and (Test-Path -LiteralPath $replacementBackup -PathType Leaf)) { Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction SilentlyContinue }
}

[pscustomobject]@{
    OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
    SchemaVersion = $manifest.SchemaVersion
    FileCount = $manifest.FileCount
    TotalBytes = $manifest.TotalBytes
    LauncherVersion = $manifest.LauncherVersion
    ReleaseVersion = $manifest.ReleaseVersion
    LauncherSha256 = $manifest.LauncherSha256
    ManifestSha256 = Get-PortableSha256 $OutputPath
    DirectoryCount = $manifest.DirectoryCount
    LargestFileBytes = $manifest.LargestFileBytes
    ManagedFileCount = $manifest.ManagedSummary.FileCount
    ManagedTotalBytes = $manifest.ManagedSummary.TotalBytes
} | ConvertTo-Json -Depth 8
