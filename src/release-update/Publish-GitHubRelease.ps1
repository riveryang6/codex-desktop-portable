[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseParentRoot,

    [Parameter(Mandatory = $true)]
    [string]$UsbRoot,

    [Parameter(Mandatory = $true)]
    [string]$SandboxValidationResultPath,

    [string]$Repository = 'riveryang6/codex-desktop-portable'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$assetName = 'LFPortable-release.zip'
$maximumAssetBytes = 2GB - 1
$minimumSevenZipVersion = [version]'24.9'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$distRoot = Join-Path $repoRoot 'dist'
$officialCompatibilityGate = Join-Path $repoRoot 'src\portable-launcher\Assert-OfficialCodexCompatibility.ps1'
$launcherMatrixBuilder = Join-Path $repoRoot 'src\portable-launcher\build-launcher-matrix.ps1'
$releaseParent = [IO.Path]::GetFullPath($ReleaseParentRoot).TrimEnd('\')
$releaseRoot = Join-Path $releaseParent 'release'
$manifestPath = Join-Path $releaseParent 'portable-package-manifest.json'
$archivePath = Join-Path $releaseParent $assetName
$canonicalFiles = @(
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
$descriptorFiles = @($canonicalFiles | Where-Object { $_ -cne 'CodexData/portable-release.json' })
$storedArchiveFiles = @(
    'CodexData/packages/LFPortable-common.zip',
    'CodexData/packages/LFPortable-x64.msix',
    'CodexData/packages/LFPortable-arm64.msix'
)
$launcherFiles = [ordered]@{
    Bootstrapper = 'CodexPortable.exe'
    X86 = 'CodexData/tools/launchers/CodexPortable.x86.exe'
    X64 = 'CodexData/tools/launchers/CodexPortable.x64.exe'
    Arm64 = 'CodexData/tools/launchers/CodexPortable.arm64.exe'
}
$packageArtifactFiles = [ordered]@{
    Common = [pscustomobject]@{
        Path = 'CodexData/packages/LFPortable-common.zip'
        Format = 'zip'
        Architecture = $null
    }
    X64 = [pscustomobject]@{
        Path = 'CodexData/packages/LFPortable-x64.msix'
        Format = 'msix'
        Architecture = 'x64'
    }
    Arm64 = [pscustomobject]@{
        Path = 'CodexData/packages/LFPortable-arm64.msix'
        Format = 'msix'
        Architecture = 'arm64'
    }
}

function Invoke-Native([string]$FilePath, [string[]]$ArgumentList) {
    $output = @(& $FilePath @ArgumentList 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$FilePath failed with exit code $exitCode.`r`n$($output -join [Environment]::NewLine)"
    }
    return ($output -join "`n")
}

function Get-Json([string]$Text, [string]$Label) {
    try { return $Text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "$Label is not valid JSON: $($_.Exception.Message)" }
}

function Get-RequiredProperty([object]$Value, [string]$Name, [string]$Label) {
    if ($null -eq $Value) { throw "$Label is missing." }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Label is missing property $Name." }
    return $property.Value
}

function Get-StrictJsonFile([string]$Path, [string]$Label) {
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    try { return Get-Json ([IO.File]::ReadAllText($Path, $strictUtf8)) $Label }
    catch { throw "$Label could not be read: $($_.Exception.Message)" }
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-StreamSha256([IO.Stream]$Stream) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Test-PathWithin([string]$Candidate, [string]$Root) {
    $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidateFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        $candidateFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePointInAncestry([string]$Path, [string]$Label) {
    $current = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($current).TrimEnd('\')
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label is or is beneath a reparse point: $current"
            }
        }
        if ($current.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = $parent.TrimEnd('\')
    }
}

function Assert-RegularFile([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is missing: $Path" }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0) {
        throw "$Label is not a safe non-empty regular file: $Path"
    }
    return $item
}

function New-ManifestContract([object]$Manifest, [string]$Label) {
    if ([int](Get-RequiredProperty $Manifest 'SchemaVersion' $Label) -ne 4 -or
        [string](Get-RequiredProperty $Manifest 'Package' $Label) -cne 'Codex Portable USB' -or
        [string](Get-RequiredProperty $Manifest 'Packaging' $Label) -cne 'CompressedFirstRun') {
        throw "$Label has an unsupported compact release contract."
    }
    $version = [string](Get-RequiredProperty $Manifest 'ReleaseVersion' $Label)
    $launcherVersion = [string](Get-RequiredProperty $Manifest 'LauncherVersion' $Label)
    if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' -or
        -not $version.Equals($launcherVersion, [StringComparison]::Ordinal)) {
        throw "$Label has inconsistent four-part LF versions."
    }
    if ([int](Get-RequiredProperty $Manifest 'FileCount' $Label) -ne $canonicalFiles.Count) {
        throw "$Label does not declare the exact canonical file count."
    }

    $metadata = @{}
    foreach ($entry in @((Get-RequiredProperty $Manifest 'Files' $Label))) {
        $path = [string](Get-RequiredProperty $entry 'Path' "$Label file entry")
        $length = [long](Get-RequiredProperty $entry 'Length' "$Label file entry")
        $sha256 = [string](Get-RequiredProperty $entry 'Sha256' "$Label file entry")
        if (-not ($canonicalFiles -ccontains $path) -or $metadata.ContainsKey($path) -or
            $length -le 0 -or $sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "$Label has invalid, duplicate, or unexpected metadata for $path."
        }
        $metadata[$path] = [pscustomobject]@{
            Length = $length
            Sha256 = $sha256.ToUpperInvariant()
        }
    }
    if ($metadata.Count -ne $canonicalFiles.Count) {
        throw "$Label does not declare all canonical files."
    }
    foreach ($path in $canonicalFiles) {
        if (-not $metadata.ContainsKey($path)) { throw "$Label is missing metadata for $path." }
    }
    $launcherSha256 = [string](Get-RequiredProperty $Manifest 'LauncherSha256' $Label)
    if (-not $launcherSha256.Equals([string]$metadata['CodexPortable.exe'].Sha256,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label launcher hash does not match CodexPortable.exe."
    }
    $packageArtifacts = Get-RequiredProperty $Manifest 'PackageArtifacts' $Label
    if (@($packageArtifacts.PSObject.Properties).Count -ne $packageArtifactFiles.Count) {
        throw "$Label has an unexpected PackageArtifacts declaration."
    }
    foreach ($packageName in @($packageArtifactFiles.Keys)) {
        $artifact = Get-RequiredProperty $packageArtifacts $packageName "$Label PackageArtifacts"
        $definition = $packageArtifactFiles[$packageName]
        if ([string](Get-RequiredProperty $artifact 'Path' "$Label $packageName package") -cne $definition.Path -or
            [string](Get-RequiredProperty $artifact 'Format' "$Label $packageName package") -cne $definition.Format) {
            throw "$Label $packageName package has the wrong path or format."
        }
        $expected = $metadata[$definition.Path]
        if ([long](Get-RequiredProperty $artifact 'Length' "$Label $packageName package") -ne [long]$expected.Length -or
            -not ([string](Get-RequiredProperty $artifact 'Sha256' "$Label $packageName package")).Equals(
                [string]$expected.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label $packageName package metadata does not match its Files entry."
        }
        if ($null -ne $definition.Architecture) {
            $identity = Get-RequiredProperty $artifact 'Identity' "$Label $packageName package"
            if ([string](Get-RequiredProperty $identity 'ProcessorArchitecture' "$Label $packageName package identity") -cne
                $definition.Architecture) {
                throw "$Label $packageName package has the wrong architecture."
            }
        }
    }
    [pscustomobject]@{
        Manifest = $Manifest
        Version = $version
        Metadata = $metadata
        PackageArtifacts = $packageArtifacts
    }
}

function Assert-PortableReleaseDescriptor([string]$Root, [object]$Contract, [string]$Label) {
    $path = Join-Path $Root 'CodexData\portable-release.json'
    $descriptor = Get-StrictJsonFile $path "$Label portable-release.json"
    if ([int](Get-RequiredProperty $descriptor 'SchemaVersion' "$Label portable-release.json") -ne 1 -or
        -not ([string](Get-RequiredProperty $descriptor 'ReleaseVersion' "$Label portable-release.json")).Equals(
            [string]$Contract.Version, [StringComparison]::Ordinal) -or
        -not ([string](Get-RequiredProperty $descriptor 'LauncherVersion' "$Label portable-release.json")).Equals(
            [string]$Contract.Version, [StringComparison]::Ordinal)) {
        throw "$Label portable-release.json has the wrong schema or version."
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $files = @((Get-RequiredProperty $descriptor 'Files' "$Label portable-release.json"))
    if ($files.Count -ne $descriptorFiles.Count) {
        throw "$Label portable-release.json has the wrong file count."
    }
    foreach ($entry in $files) {
        $relative = [string](Get-RequiredProperty $entry 'Path' "$Label descriptor entry")
        if (-not ($descriptorFiles -ccontains $relative) -or -not $seen.Add($relative)) {
            throw "$Label portable-release.json has an unexpected or duplicate entry: $relative"
        }
        $expected = $Contract.Metadata[$relative]
        if ([long](Get-RequiredProperty $entry 'Length' "$Label descriptor entry") -ne [long]$expected.Length -or
            -not ([string](Get-RequiredProperty $entry 'Sha256' "$Label descriptor entry")).Equals(
                [string]$expected.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label portable-release.json differs from the manifest for $relative."
        }
    }
}

function Assert-ManagedTree([string]$Root, [object]$Contract, [string]$Label, [bool]$ExactTree) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "$Label root is missing: $Root" }
    Assert-NoReparsePointInAncestry $Root "$Label root"
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label root is a reparse point."
    }
    if ($ExactTree) {
        $points = @(Get-ChildItem -LiteralPath $Root -Force -Recurse -Attributes ReparsePoint -ErrorAction Stop)
        if ($points.Count -ne 0) { throw "$Label contains reparse points: $($points.FullName -join ', ')" }
        $actualFiles = @(Get-ChildItem -LiteralPath $Root -Force -Recurse -File -ErrorAction Stop |
            ForEach-Object { $_.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\').Replace('\', '/') })
        if (Compare-Object -ReferenceObject @($canonicalFiles | Sort-Object) -DifferenceObject @($actualFiles | Sort-Object)) {
            throw "$Label does not contain exactly the ten canonical files."
        }
        $expectedDirectories = @('CodexData', 'CodexData/packages', 'CodexData/tools', 'CodexData/tools/launchers')
        $actualDirectories = @(Get-ChildItem -LiteralPath $Root -Force -Recurse -Directory -ErrorAction Stop |
            ForEach-Object { $_.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\').Replace('\', '/') })
        if (Compare-Object -ReferenceObject @($expectedDirectories | Sort-Object) -DifferenceObject @($actualDirectories | Sort-Object)) {
            throw "$Label has an unexpected directory layout."
        }
    }
    foreach ($relative in $canonicalFiles) {
        $path = Join-Path $Root ($relative.Replace('/', '\'))
        $item = Assert-RegularFile $path "$Label managed file"
        Assert-NoReparsePointInAncestry $path "$Label managed file"
        $expected = $Contract.Metadata[$relative]
        if ([long]$item.Length -ne [long]$expected.Length -or
            -not (Get-Sha256 $path).Equals([string]$expected.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label differs from the manifest for $relative."
        }
    }
    Assert-PortableReleaseDescriptor $Root $Contract $Label
    foreach ($launcher in $launcherFiles.Values) {
        $version = [string](Get-Item -LiteralPath (Join-Path $Root ($launcher.Replace('/', '\'))) -Force).VersionInfo.FileVersion
        if (-not $version.Equals([string]$Contract.Version, [StringComparison]::Ordinal)) {
            throw "$Label launcher version mismatch for ${launcher}: $version"
        }
    }
}

function Assert-DistMatchesRelease([object]$Contract) {
    if (-not (Test-Path -LiteralPath $distRoot -PathType Container)) { throw "dist is missing: $distRoot" }
    $actualFiles = @(Get-ChildItem -LiteralPath $distRoot -Force -Recurse -File -ErrorAction Stop |
        ForEach-Object { $_.FullName.Substring($distRoot.TrimEnd('\').Length).TrimStart('\').Replace('\', '/') })
    $expectedFiles = @($launcherFiles.Values)
    if (Compare-Object -ReferenceObject @($expectedFiles | Sort-Object) -DifferenceObject @($actualFiles | Sort-Object)) {
        throw 'dist must contain only the four release launcher binaries.'
    }
    foreach ($relative in $expectedFiles) {
        $path = Join-Path $distRoot ($relative.Replace('/', '\'))
        $item = Assert-RegularFile $path 'dist launcher'
        $expected = $Contract.Metadata[$relative]
        if ([long]$item.Length -ne [long]$expected.Length -or
            -not (Get-Sha256 $path).Equals([string]$expected.Sha256, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$item.VersionInfo.FileVersion).Equals([string]$Contract.Version, [StringComparison]::Ordinal)) {
            throw "dist launcher does not match the canonical release: $relative"
        }
    }
}

function Assert-CurrentSourceBuildMatchesRelease([object]$Contract) {
    Assert-RegularFile $launcherMatrixBuilder 'Launcher matrix builder' | Out-Null
    $temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $candidateRoot = Join-Path $temporaryParent ('LFPortable-publish-build-' + [Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $candidateRoot) {
        throw "Fresh publish build path already exists: $candidateRoot"
    }
    try {
        $buildResults = @(& $launcherMatrixBuilder -OutputRoot $candidateRoot)
        if ($buildResults.Count -ne 1 -or [int]$buildResults[0].BuildCount -ne 4 -or
            [string]$buildResults[0].OfficialPackageSelfTest -cne 'x64-msix+arm64-msix:passed' -or
            [string]$buildResults[0].FileVersion -cne [string]$Contract.Version -or
            -not ([IO.Path]::GetFullPath([string]$buildResults[0].OutputRoot).TrimEnd('\')).Equals(
                $candidateRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Fresh source launcher matrix did not complete the required compatibility-gated build.'
        }
        foreach ($relative in @($launcherFiles.Values)) {
            $candidate = Join-Path $candidateRoot ($relative.Replace('/', '\'))
            $candidateItem = Assert-RegularFile $candidate 'Fresh source launcher'
            $expected = $Contract.Metadata[$relative]
            if ([long]$candidateItem.Length -ne [long]$expected.Length -or
                -not (Get-Sha256 $candidate).Equals([string]$expected.Sha256, [StringComparison]::OrdinalIgnoreCase) -or
                -not ([string]$candidateItem.VersionInfo.FileVersion).Equals([string]$Contract.Version,
                    [StringComparison]::Ordinal)) {
                throw "Current source did not rebuild the canonical launcher: $relative"
            }
        }
        return [pscustomobject]@{
            OfficialCodexVersion = [string]$buildResults[0].OfficialCodexVersion
            FileVersion = [string]$buildResults[0].FileVersion
            BuildCount = [int]$buildResults[0].BuildCount
        }
    }
    finally {
        if (Test-Path -LiteralPath $candidateRoot -PathType Container) {
            $resolved = (Resolve-Path -LiteralPath $candidateRoot).Path
            if (-not $resolved.Equals($candidateRoot, [StringComparison]::OrdinalIgnoreCase) -or
                -not ([IO.Path]::GetDirectoryName($resolved)).Equals($temporaryParent,
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove an unexpected fresh publish build path: $resolved"
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

function Get-SafeArchivePath([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.StartsWith('/') -or $Name.StartsWith('\') -or
        $Name.Contains(':') -or $Name -match '[\x00-\x1F]') {
        throw "Release archive contains an unsafe path: $Name"
    }
    $clean = $Name.Replace('\', '/')
    if ($clean.EndsWith('/') -or @($clean.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) {
        throw "Release archive contains a directory or non-normalized path: $Name"
    }
    foreach ($segment in $clean.Split('/')) {
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ') -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "Release archive contains a Windows-unsafe path: $Name"
        }
    }
    return $clean
}

function Get-ZipEntryAttributes([IO.Compression.ZipArchiveEntry]$Entry) {
    [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Entry.ExternalAttributes), 0)
}

function Assert-ZipEntryIsRegular([IO.Compression.ZipArchiveEntry]$Entry, [string]$Label) {
    $attributes = Get-ZipEntryAttributes $Entry
    $unixType = ($attributes -shr 16) -band 0xF000
    if ($unixType -eq 0xA000 -or (($attributes -band 0x400) -ne 0)) {
        throw "$Label contains a symbolic link or reparse-point entry: $($Entry.FullName)"
    }
}

function Resolve-SevenZip {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $command = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) { $candidates.Add([string]$command.Source) }
    $candidates.Add((Join-Path $env:ProgramFiles '7-Zip\7z.exe'))
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $output = @(& $candidate i 2>&1)
        if ($LASTEXITCODE -ne 0) { continue }
        $banner = @($output | Where-Object { [string]$_ -match '^7-Zip [0-9]+\.[0-9]+' } | Select-Object -First 1)
        if ($banner.Count -ne 1) { continue }
        $match = [regex]::Match([string]$banner[0], '^7-Zip (?<version>[0-9]+\.[0-9]+)')
        if ($match.Success -and [version]$match.Groups['version'].Value -ge $minimumSevenZipVersion) {
            return [pscustomobject]@{ Path = $candidate; Version = $match.Groups['version'].Value }
        }
    }
    throw '7-Zip 24.09 or later is required to verify LFPortable-release.zip.'
}

function Get-ZipCompressionMethods([string]$Path, [string]$Label, [string]$SevenZipPath) {
    $listing = Invoke-Native $SevenZipPath @(
        'l', '-slt', '-ba', '-bd', '-bb0', '-bso1', '-bse1', '-bsp0', '--', $Path)
    $methods = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $currentPath = $null
    foreach ($line in @($listing -split "`n")) {
        if ($line -match '^Path = (?<path>.+)$') {
            if ($null -ne $currentPath) { throw "$Label has incomplete 7-Zip metadata for $currentPath." }
            $currentPath = Get-SafeArchivePath $Matches['path'].TrimEnd("`r")
            continue
        }
        if (-not $line.StartsWith('Method = ', [StringComparison]::Ordinal)) { continue }
        if ($null -eq $currentPath) { throw "$Label has a compression method without a path." }
        $method = $line.Substring(9).Trim().TrimEnd("`r")
        if ($method -notin @('Store', 'Deflate')) {
            throw "$Label uses an unsupported ZIP method '$method' for $currentPath."
        }
        if ($methods.ContainsKey($currentPath)) { throw "$Label has duplicate 7-Zip metadata for $currentPath." }
        $methods.Add($currentPath, $method)
        $currentPath = $null
    }
    if ($null -ne $currentPath) { throw "$Label has incomplete 7-Zip metadata for $currentPath." }
    return $methods
}

function Assert-CommonPackage([object]$Contract, [string]$SevenZipPath) {
    $label = 'LFPortable-common.zip'
    $artifact = Get-RequiredProperty $Contract.PackageArtifacts 'Common' 'Portable manifest PackageArtifacts'
    $relative = [string](Get-RequiredProperty $artifact 'Path' 'Portable manifest common package')
    $path = Join-Path $releaseRoot ($relative.Replace('/', '\'))
    $archive = Assert-RegularFile $path $label
    Invoke-Native $SevenZipPath @('t', '-bd', '-bb0', '-bso0', '-bse1', '-bsp0', '--', $path) | Out-Null
    $methods = Get-ZipCompressionMethods $path $label $SevenZipPath
    $expectedEntryCount = [int](Get-RequiredProperty $artifact 'EntryCount' 'Portable manifest common package')
    $expectedFileCount = [int](Get-RequiredProperty $artifact 'FileCount' 'Portable manifest common package')
    $expectedUncompressedBytes = [long](Get-RequiredProperty $artifact 'UncompressedBytes' 'Portable manifest common package')
    $expectedCompressedEntryBytes = [long](Get-RequiredProperty $artifact 'CompressedEntryBytes' 'Portable manifest common package')
    if ($expectedEntryCount -le 0 -or $expectedFileCount -ne $expectedEntryCount -or
        $expectedUncompressedBytes -le 0 -or $expectedCompressedEntryBytes -le 0) {
        throw 'Portable manifest common package has invalid ZIP summary metadata.'
    }

    $allowedRoots = @((Get-RequiredProperty $artifact 'AllowedRoots' 'Portable manifest common package'))
    $requiredEntries = @((Get-RequiredProperty $artifact 'RequiredEntries' 'Portable manifest common package'))
    $requiredGroups = @((Get-RequiredProperty $artifact 'RequiredEntryGroups' 'Portable manifest common package'))
    if ($allowedRoots.Count -eq 0 -or $requiredEntries.Count -eq 0) {
        throw 'Portable manifest common package has no allowed roots or required entries.'
    }
    $normalizedRoots = @($allowedRoots | ForEach-Object { Get-SafeArchivePath ([string]$_) })
    $normalizedRequiredEntries = @($requiredEntries | ForEach-Object { Get-SafeArchivePath ([string]$_) })
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    [long]$uncompressedBytes = 0
    [long]$compressedEntryBytes = 0
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        foreach ($entry in @($zip.Entries)) {
            Assert-ZipEntryIsRegular $entry $label
            $entryPath = Get-SafeArchivePath $entry.FullName
            if (-not $seen.Add($entryPath)) { throw "$label contains a duplicate entry: $entryPath" }
            if (@($normalizedRoots | Where-Object {
                    $entryPath.StartsWith($_ + '/', [StringComparison]::Ordinal)
                }).Count -eq 0) {
                throw "$label contains an entry outside its allowed roots: $entryPath"
            }
            if (-not $methods.ContainsKey($entryPath)) {
                throw "$label has no 7-Zip method metadata for $entryPath."
            }
            if ($uncompressedBytes -gt ([long]::MaxValue - [long]$entry.Length) -or
                $compressedEntryBytes -gt ([long]::MaxValue - [long]$entry.CompressedLength)) {
                throw "$label size totals overflow Int64."
            }
            $uncompressedBytes += [long]$entry.Length
            $compressedEntryBytes += [long]$entry.CompressedLength
            $stream = $entry.Open()
            try { if ($entry.Length -gt 0) { [void]$stream.ReadByte() } }
            finally { $stream.Dispose() }
        }
        if ($zip.Entries.Count -ne $expectedEntryCount -or $seen.Count -ne $expectedFileCount) {
            throw "$label entry count differs from the portable manifest."
        }
    }
    finally { $zip.Dispose() }
    if ($methods.Count -ne $seen.Count -or $uncompressedBytes -ne $expectedUncompressedBytes -or
        $compressedEntryBytes -ne $expectedCompressedEntryBytes -or [long]$archive.Length -ge $uncompressedBytes) {
        throw "$label ZIP metadata or compression totals differ from the portable manifest."
    }
    if (@($methods.Values | Where-Object { $_ -ceq 'Deflate' }).Count -le 0) {
        throw "$label contains no Deflate entries."
    }
    foreach ($required in $normalizedRequiredEntries) {
        if (-not $seen.Contains($required)) { throw "$label is missing required entry: $required" }
    }
    foreach ($group in $requiredGroups) {
        $name = [string](Get-RequiredProperty $group 'Name' 'Portable manifest common required-entry group')
        $candidates = @((Get-RequiredProperty $group 'AnyOf' "Portable manifest common group $name") |
            ForEach-Object { Get-SafeArchivePath ([string]$_) })
        if ($candidates.Count -eq 0 -or @($candidates | Where-Object { $seen.Contains($_) }).Count -eq 0) {
            throw "$label does not satisfy required entry group: $name"
        }
    }
    [pscustomobject]@{
        EntryCount = $seen.Count
        StoreEntries = @($methods.Values | Where-Object { $_ -ceq 'Store' }).Count
        DeflateEntries = @($methods.Values | Where-Object { $_ -ceq 'Deflate' }).Count
        UncompressedBytes = $uncompressedBytes
        CompressedEntryBytes = $compressedEntryBytes
    }
}

function Assert-ReleaseArchive([string]$Path, [string]$ManifestFile, [object]$Contract, [string]$SevenZipPath) {
    $archive = Assert-RegularFile $Path 'LF release archive'
    if ($archive.Length -gt $maximumAssetBytes) {
        throw "$assetName exceeds the GitHub Release asset limit at $($archive.Length) bytes."
    }
    Invoke-Native $SevenZipPath @('t', '-bd', '-bb0', '-bso0', '-bse1', '-bsp0', '--', $Path) | Out-Null
    $manifestItem = Assert-RegularFile $ManifestFile 'Canonical portable manifest'
    $manifestHash = Get-Sha256 $ManifestFile
    $expectedPaths = @('portable-package-manifest.json') + @($canonicalFiles)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if ($zip.Entries.Count -ne $expectedPaths.Count) {
            throw "$assetName has $($zip.Entries.Count) entries; expected $($expectedPaths.Count)."
        }
        foreach ($entry in @($zip.Entries)) {
            Assert-ZipEntryIsRegular $entry $assetName
            $relative = Get-SafeArchivePath $entry.FullName
            if (-not ($expectedPaths -ccontains $relative) -or -not $seen.Add($relative)) {
                throw "$assetName contains an unexpected or duplicate entry: $relative"
            }
            $stream = $entry.Open()
            try { $entryHash = Get-StreamSha256 $stream }
            finally { $stream.Dispose() }
            if ($relative -ceq 'portable-package-manifest.json') {
                if ([long]$entry.Length -ne [long]$manifestItem.Length -or
                    -not $entryHash.Equals($manifestHash, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "$assetName embedded manifest does not match the canonical manifest."
                }
            }
            else {
                $expected = $Contract.Metadata[$relative]
                if ([long]$entry.Length -ne [long]$expected.Length -or
                    -not $entryHash.Equals([string]$expected.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "$assetName entry does not match the manifest: $relative"
                }
            }
        }
    }
    finally { $zip.Dispose() }

    $methods = Get-ZipCompressionMethods $Path $assetName $SevenZipPath
    if ($methods.Count -ne $expectedPaths.Count) { throw "$assetName has incomplete 7-Zip method metadata." }
    foreach ($relative in $expectedPaths) {
        $expectedMethod = if ($storedArchiveFiles -ccontains $relative) { 'Store' } else { 'Deflate' }
        if (-not $methods.ContainsKey($relative) -or [string]$methods[$relative] -cne $expectedMethod) {
            throw "$assetName compression method for $relative must be $expectedMethod."
        }
    }
    [pscustomobject]@{
        Length = [long]$archive.Length
        Sha256 = Get-Sha256 $Path
        ManifestSha256 = $manifestHash
        EntryCount = $expectedPaths.Count
        StoreEntries = $storedArchiveFiles.Count
        DeflateEntries = $expectedPaths.Count - $storedArchiveFiles.Count
    }
}

function Assert-UsbVolume([string]$Root) {
    if ($Root -notmatch '^[A-Za-z]:\\$') {
        throw "USB root must be an explicit drive root such as E:\; refusing ambiguous path: $Root"
    }
    $drive = $Root.Substring(0, 1)
    $volumeText = (& cmd.exe /d /c "vol $drive`:" 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $volumeText -notmatch '(?i)\bCODEX_USB\b') {
        throw "USB root $Root does not have the required CODEX_USB volume label."
    }
}

function Assert-TrueProperty([object]$Value, [string]$Name, [string]$Label) {
    $actual = Get-RequiredProperty $Value $Name $Label
    if (-not ($actual -is [bool]) -or -not [bool]$actual) { throw "$Label $Name is not true." }
}

function Assert-SandboxValidation([string]$Path, [string]$ManifestSha256, [string]$Version,
    [string]$ManifestFile, [string]$ReleaseTree, [string]$UsbTree) {
    $candidate = [IO.Path]::GetFullPath($Path)
    if ((Test-PathWithin $candidate $ReleaseTree) -or (Test-PathWithin $candidate $UsbTree)) {
        throw 'Windows Sandbox evidence must be outside the canonical release and USB trees.'
    }
    $item = Assert-RegularFile $candidate 'Windows Sandbox validation result'
    Assert-NoReparsePointInAncestry $candidate 'Windows Sandbox validation result'
    if ($item.Length -gt 16MB -or $item.LastWriteTimeUtc -lt (Get-Item -LiteralPath $ManifestFile -Force).LastWriteTimeUtc) {
        throw 'Windows Sandbox validation result is too large or predates this release manifest.'
    }
    $proof = Get-StrictJsonFile $candidate 'Windows Sandbox validation result'
    if ([string](Get-RequiredProperty $proof 'Contract' 'Windows Sandbox validation result') -cne
            'LF compact first-run Sandbox' -or
        [string](Get-RequiredProperty $proof 'Status' 'Windows Sandbox validation result') -cne 'Passed') {
        throw 'Windows Sandbox validation result has an unsupported or failed contract.'
    }
    Assert-TrueProperty $proof 'Passed' 'Windows Sandbox validation result'
    if (-not ([string](Get-RequiredProperty $proof 'ManifestSha256' 'Windows Sandbox validation result')).Equals(
            $ManifestSha256, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string](Get-RequiredProperty $proof 'ReleaseVersion' 'Windows Sandbox validation result')).Equals(
            $Version, [StringComparison]::Ordinal) -or
        [int](Get-RequiredProperty $proof 'ExpectedManagedFileCount' 'Windows Sandbox validation result') -ne 10 -or
        [int](Get-RequiredProperty $proof 'ExpectedPluginCount' 'Windows Sandbox validation result') -ne 12) {
        throw 'Windows Sandbox validation result is not bound to this compact release.'
    }
    $compact = Get-RequiredProperty $proof 'CompactRelease' 'Windows Sandbox validation result'
    foreach ($name in @('SourceFileCountValid', 'ManifestFileCountValid', 'SourcePathsValid', 'ManifestPathsValid')) {
        Assert-TrueProperty $compact $name 'Windows Sandbox compact release'
    }
    $plugins = Get-RequiredProperty $proof 'Plugins' 'Windows Sandbox validation result'
    if ([int](Get-RequiredProperty $plugins 'ExpectedPluginCount' 'Windows Sandbox plugins') -ne 12 -or
        [int](Get-RequiredProperty $plugins 'FoundPluginCount' 'Windows Sandbox plugins') -ne 12) {
        throw 'Windows Sandbox validation did not inspect all required plugins.'
    }
    Assert-TrueProperty $plugins 'Valid' 'Windows Sandbox plugins'
    $validator = Get-RequiredProperty $proof 'Validator' 'Windows Sandbox validation result'
    if ([int](Get-RequiredProperty $validator 'ExitCode' 'Windows Sandbox validator') -ne 0) {
        throw 'Windows Sandbox isolated validator failed.'
    }
    Assert-TrueProperty $validator 'Passed' 'Windows Sandbox validator'
    $manual = Get-RequiredProperty $proof 'ManualStart' 'Windows Sandbox validation result'
    Assert-TrueProperty $manual 'Executed' 'Windows Sandbox manual start'
    Assert-TrueProperty $manual 'Passed' 'Windows Sandbox manual start'
    $zero = Get-RequiredProperty $manual 'ZeroState' 'Windows Sandbox manual start'
    foreach ($name in @('ConfigTomlExists', 'ExpandedPayloadExists', 'RuntimeCacheExists', 'PluginCacheExists')) {
        if ([bool](Get-RequiredProperty $zero $name 'Windows Sandbox zero state')) {
            throw "Windows Sandbox zero state $name must be false."
        }
    }
    $launcher = Get-RequiredProperty $manual 'Launcher' 'Windows Sandbox manual start'
    Assert-TrueProperty $launcher 'ActualButtonClicked' 'Windows Sandbox launcher'
    $ephemeralApi = Get-RequiredProperty $manual 'EphemeralApiConfiguration' 'Windows Sandbox manual start'
    $expectedModel = [string](Get-RequiredProperty $ephemeralApi 'Model' 'Windows Sandbox ephemeral API configuration')
    if ($expectedModel -cne 'sandbox-local-probe') {
        throw 'Windows Sandbox did not use the required disposable custom-model probe.'
    }
    $derived = Get-RequiredProperty $manual 'DerivedState' 'Windows Sandbox manual start'
    $config = Get-RequiredProperty $derived 'ConfigToml' 'Windows Sandbox derived state'
    if ([string](Get-RequiredProperty $config 'Model' 'Windows Sandbox config.toml') -cne $expectedModel) {
        throw 'Windows Sandbox config.toml model does not match the configured custom-model probe.'
    }
    Assert-TrueProperty $config 'RootPermissionsStillValid' 'Windows Sandbox config.toml'
    Assert-TrueProperty $config 'ConfiguredModelStillValid' 'Windows Sandbox config.toml'
    return $candidate
}

function Assert-OfficialPackages([object]$Contract) {
    Assert-RegularFile $officialCompatibilityGate 'Official Codex compatibility gate' | Out-Null
    $referenceLauncher = Join-Path $releaseRoot 'CodexData\tools\launchers\CodexPortable.x64.exe'
    $result = @(& $officialCompatibilityGate -ReferenceLauncherPath $referenceLauncher -RunLauncherSelfTest)
    if ($result.Count -ne 1 -or [string]$result[0].LauncherSelfTest -cne 'Passed') {
        throw 'Official Codex compatibility gate did not pass for the packaged launcher.'
    }
    $artifacts = Get-RequiredProperty $Contract.Manifest 'PackageArtifacts' 'Portable manifest'
    $x64 = Get-RequiredProperty $artifacts 'X64' 'Portable manifest PackageArtifacts'
    $arm64 = Get-RequiredProperty $artifacts 'Arm64' 'Portable manifest PackageArtifacts'
    $x64Identity = Get-RequiredProperty $x64 'Identity' 'Portable manifest x64 package'
    $arm64Identity = Get-RequiredProperty $arm64 'Identity' 'Portable manifest ARM64 package'
    if ([long](Get-RequiredProperty $x64 'Length' 'Portable manifest x64 package') -ne [long]$result[0].X64Length -or
        -not ([string](Get-RequiredProperty $x64 'Sha256' 'Portable manifest x64 package')).Equals(
            [string]$result[0].X64SHA256, [StringComparison]::OrdinalIgnoreCase) -or
        [long](Get-RequiredProperty $arm64 'Length' 'Portable manifest ARM64 package') -ne [long]$result[0].Arm64Length -or
        -not ([string](Get-RequiredProperty $arm64 'Sha256' 'Portable manifest ARM64 package')).Equals(
            [string]$result[0].Arm64SHA256, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string](Get-RequiredProperty $x64Identity 'Version' 'Portable manifest x64 identity')).Equals(
            [string]$result[0].Version, [StringComparison]::Ordinal) -or
        -not ([string](Get-RequiredProperty $arm64Identity 'Version' 'Portable manifest ARM64 identity')).Equals(
            [string]$result[0].Version, [StringComparison]::Ordinal)) {
        throw 'Canonical release packages do not match the current official Codex packages.'
    }
    return $result[0]
}

function Assert-RemoteAsset($Release, [long]$ExpectedLength, [string]$ExpectedSha256) {
    $assets = @($Release.assets | Where-Object { [string]$_.name -ceq $assetName })
    if ($assets.Count -ne 1 -or @($Release.assets).Count -ne 1) {
        throw "GitHub Release must contain exactly one asset named $assetName."
    }
    $asset = $assets[0]
    if ([string]$asset.state -cne 'uploaded' -or [long]$asset.size -ne $ExpectedLength) {
        throw 'GitHub Release asset is incomplete or has the wrong length.'
    }
    $digest = [string]$asset.digest
    if ($digest -notmatch '^sha256:[A-Fa-f0-9]{64}$' -or
        -not $digest.Substring(7).Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'GitHub Release asset SHA-256 differs from the verified local archive.'
    }
    $downloadUrl = [string]$asset.browser_download_url
    $expectedPrefix = "https://github.com/$Repository/releases/download/"
    if (-not $downloadUrl.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'GitHub Release asset public download URL is invalid.'
    }
    return $asset
}

function Remove-ControlledDownloadFile([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is not a regular file: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label is a reparse point: $Path"
    }
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $Path) {
        throw "Could not remove ${Label}: $Path"
    }
}

function Invoke-AuthenticatedAssetDownload(
    [string]$GhPath,
    [string]$Repo,
    [string]$Tag,
    [string]$Asset,
    [string]$DestinationDirectory,
    [string]$DestinationPath,
    [long]$ExpectedLength,
    [string]$ExpectedSha256,
    [int]$MaximumAttempts = 4
) {
    if ($MaximumAttempts -lt 1) { throw 'Authenticated download retry count must be positive.' }
    $lastError = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            # Never allow a failed transfer from an earlier attempt to satisfy this release check.
            Remove-ControlledDownloadFile $DestinationPath 'Incomplete authenticated GitHub asset download'
            Invoke-Native $GhPath @('release', 'download', $Tag, '--repo', $Repo,
                '--pattern', $Asset, '--dir', $DestinationDirectory, '--clobber') | Out-Null
            $downloaded = Assert-RegularFile $DestinationPath 'Authenticated GitHub asset download'
            if ([long]$downloaded.Length -ne $ExpectedLength) {
                throw "Authenticated GitHub asset download has $([long]$downloaded.Length) bytes; expected $ExpectedLength."
            }
            $downloadedHash = Get-Sha256 $DestinationPath
            if (-not $downloadedHash.Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Authenticated GitHub asset download has the expected length but the wrong SHA-256.'
            }
            return $downloaded
        }
        catch {
            $lastError = $_.Exception
            try { Remove-ControlledDownloadFile $DestinationPath 'Incomplete authenticated GitHub asset download' }
            catch { throw "Authenticated GitHub asset download cleanup failed after attempt ${attempt}: $($_.Exception.Message)" }
            if ($attempt -lt $MaximumAttempts) {
                Start-Sleep -Seconds ([int][Math]::Min(5 * $attempt, 20))
            }
        }
    }
    throw "Authenticated GitHub asset download failed after $MaximumAttempts attempts: $($lastError.Message)"
}

function Invoke-PublicAssetDownload(
    [string]$CurlPath,
    [string]$DownloadUrl,
    [string]$DestinationPath,
    [long]$ExpectedLength,
    [string]$ExpectedSha256,
    [int]$MaximumAttempts = 4
) {
    if ($MaximumAttempts -lt 1) { throw 'Public download retry count must be positive.' }
    $lastError = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            if (Test-Path -LiteralPath $DestinationPath) {
                if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
                    throw "Public GitHub asset download is not a regular file: $DestinationPath"
                }
                $existing = Get-Item -LiteralPath $DestinationPath -Force -ErrorAction Stop
                if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Public GitHub asset download is a reparse point: $DestinationPath"
                }
                if ([long]$existing.Length -le 0 -or [long]$existing.Length -gt $ExpectedLength) {
                    Remove-ControlledDownloadFile $DestinationPath 'Invalid public GitHub asset download'
                }
                elseif ([long]$existing.Length -eq $ExpectedLength) {
                    $existingHash = Get-Sha256 $DestinationPath
                    if ($existingHash.Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
                        return $existing
                    }
                    Remove-ControlledDownloadFile $DestinationPath 'Corrupt public GitHub asset download'
                }
            }
            Invoke-Native $CurlPath @('--fail', '--location', '--silent', '--show-error',
                '--retry', '4', '--retry-all-errors', '--retry-delay', '3', '--retry-max-time', '1800',
                '--continue-at', '-', '--output', $DestinationPath, $DownloadUrl) | Out-Null
            $downloaded = Assert-RegularFile $DestinationPath 'Public GitHub asset download'
            if ([long]$downloaded.Length -ne $ExpectedLength) {
                throw "Public GitHub asset download has $([long]$downloaded.Length) bytes; expected $ExpectedLength."
            }
            $downloadedHash = Get-Sha256 $DestinationPath
            if (-not $downloadedHash.Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Public GitHub asset download has the expected length but the wrong SHA-256.'
            }
            return $downloaded
        }
        catch {
            $lastError = $_.Exception
            if ($attempt -lt $MaximumAttempts) {
                Start-Sleep -Seconds ([int][Math]::Min(5 * $attempt, 20))
            }
        }
    }
    throw "Public GitHub asset download failed after $MaximumAttempts attempts: $($lastError.Message)"
}

function Get-ReleaseByTag([string]$GhPath, [string]$Repo, [string]$Tag) {
    $releaseListText = Invoke-Native $GhPath @('api', "repos/$Repo/releases?per_page=100")
    $parsedReleases = Get-Json -Text $releaseListText -Label 'GitHub release list'
    $releases = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in @($parsedReleases)) {
        if ($candidate -is [Array]) {
            foreach ($release in $candidate) { $releases.Add($release) }
        }
        else {
            $releases.Add($candidate)
        }
    }
    $matches = @($releases | Where-Object { [string]$_.tag_name -ceq $Tag })
    if ($matches.Count -gt 1) { throw "More than one GitHub Release uses tag $Tag." }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-ReleaseById([string]$GhPath, [string]$Repo, [long]$ReleaseId) {
    if ($ReleaseId -le 0) { throw 'GitHub Release ID must be positive.' }
    $releaseText = Invoke-Native $GhPath @('api', "repos/$Repo/releases/$ReleaseId")
    return Get-Json -Text $releaseText -Label "GitHub Release $ReleaseId"
}

function Get-ReleaseByReference([string]$GhPath, [string]$Repo, [string]$Tag, [long]$ReleaseId) {
    if ($ReleaseId -gt 0) { return Get-ReleaseById $GhPath $Repo $ReleaseId }
    return Get-ReleaseByTag $GhPath $Repo $Tag
}

function Test-ReleaseState([object]$Release, [string]$ExpectedState) {
    if ($ExpectedState -ceq 'Any') { return $true }
    if ($ExpectedState -ceq 'Draft') { return [bool]$Release.draft }
    if ($ExpectedState -ceq 'Published') { return -not [bool]$Release.draft }
    throw "Unsupported expected GitHub Release state: $ExpectedState"
}

function Wait-ReleaseByTag(
    [string]$GhPath,
    [string]$Repo,
    [string]$Tag,
    [ValidateSet('Any', 'Draft', 'Published')]
    [string]$ExpectedState = 'Any',
    [int]$ExpectedAssetCount = -1,
    [long]$ReleaseId = 0,
    [int]$TimeoutSeconds = 900
) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastState = 'not found'
    while ($true) {
        try {
            $release = Get-ReleaseByReference $GhPath $Repo $Tag $ReleaseId
            if ($null -ne $release) {
                $assetCount = @($release.assets).Count
                $lastState = "draft=$([bool]$release.draft), assets=$assetCount"
                if ((Test-ReleaseState $release $ExpectedState) -and
                    ($ExpectedAssetCount -lt 0 -or $assetCount -eq $ExpectedAssetCount)) {
                    return $release
                }
            }
        }
        catch { $lastState = $_.Exception.Message }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for GitHub Release $Tag ($ExpectedState, assets=$ExpectedAssetCount). Last state: $lastState"
        }
        Start-Sleep -Seconds 2
    }
}

function Wait-VerifiedReleaseAsset(
    [string]$GhPath,
    [string]$Repo,
    [string]$Tag,
    [ValidateSet('Draft', 'Published')]
    [string]$ExpectedState,
    [long]$ExpectedLength,
    [string]$ExpectedSha256,
    [long]$ReleaseId = 0,
    [int]$TimeoutSeconds = 900
) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastState = 'not found'
    while ($true) {
        try {
            $release = Get-ReleaseByReference $GhPath $Repo $Tag $ReleaseId
            if ($null -ne $release -and (Test-ReleaseState $release $ExpectedState)) {
                $asset = Assert-RemoteAsset $release $ExpectedLength $ExpectedSha256
                return [pscustomobject]@{ Release = $release; Asset = $asset }
            }
            if ($null -ne $release) {
                $lastState = "draft=$([bool]$release.draft), assets=$(@($release.assets).Count)"
            }
        }
        catch { $lastState = $_.Exception.Message }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for the verified GitHub asset on $Tag ($ExpectedState). Last state: $lastState"
        }
        Start-Sleep -Seconds 2
    }
}

function Wait-ReleaseTagVisible(
    [string]$GhPath,
    [string]$Repo,
    [string]$Tag,
    [long]$ReleaseId,
    [int]$TimeoutSeconds = 900
) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastState = 'not found'
    while ($true) {
        try {
            $release = Get-ReleaseByTag $GhPath $Repo $Tag
            if ($null -ne $release) {
                $lastState = "id=$([long]$release.id), draft=$([bool]$release.draft), assets=$(@($release.assets).Count)"
                if ([long]$release.id -eq $ReleaseId) { return $release }
            }
        }
        catch { $lastState = $_.Exception.Message }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for GitHub to expose release $ReleaseId under tag $Tag. Last state: $lastState"
        }
        Start-Sleep -Seconds 2
    }
}

function Wait-LatestVerifiedRelease(
    [string]$GhPath,
    [string]$Repo,
    [string]$Tag,
    [long]$ExpectedLength,
    [string]$ExpectedSha256,
    [int]$TimeoutSeconds = 900
) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastState = 'not available'
    while ($true) {
        try {
            $latestText = Invoke-Native $GhPath @('api', "repos/$Repo/releases/latest")
            $latest = Get-Json -Text $latestText -Label 'Latest release metadata'
            $lastState = "tag=$([string]$latest.tag_name), draft=$([bool]$latest.draft), assets=$(@($latest.assets).Count)"
            if (-not [bool]$latest.draft -and -not [bool]$latest.prerelease -and
                [string]$latest.tag_name -ceq $Tag) {
                $asset = Assert-RemoteAsset $latest $ExpectedLength $ExpectedSha256
                return [pscustomobject]@{ Release = $latest; Asset = $asset }
            }
        }
        catch { $lastState = $_.Exception.Message }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for $Tag to become the verified latest stable Release. Last state: $lastState"
        }
        Start-Sleep -Seconds 2
    }
}

foreach ($required in @(
        $releaseRoot, $manifestPath, $archivePath, $distRoot,
        $officialCompatibilityGate, $launcherMatrixBuilder)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required release input is missing: $required" }
}
$usb = [IO.Path]::GetFullPath($UsbRoot)
Assert-UsbVolume $usb
Assert-NoReparsePointInAncestry $releaseRoot 'Canonical release'
Assert-NoReparsePointInAncestry $manifestPath 'Canonical manifest'
Assert-NoReparsePointInAncestry $archivePath 'Canonical release archive'
Assert-NoReparsePointInAncestry $usb 'Portable USB'

$sevenZip = Resolve-SevenZip
$manifest = Get-StrictJsonFile $manifestPath 'Portable manifest'
$contract = New-ManifestContract $manifest 'Portable manifest'
$archiveVerification = Assert-ReleaseArchive $archivePath $manifestPath $contract $sevenZip.Path
$commonVerification = Assert-CommonPackage $contract $sevenZip.Path
Assert-ManagedTree $releaseRoot $contract 'Canonical release' $true
Assert-DistMatchesRelease $contract
Assert-ManagedTree $usb $contract 'Portable USB' $false
$sandboxResult = Assert-SandboxValidation $SandboxValidationResultPath $archiveVerification.ManifestSha256 `
    $contract.Version $manifestPath $releaseRoot $usb
$official = Assert-OfficialPackages $contract
$tag = 'v' + $contract.Version

$gh = (Get-Command gh.exe -ErrorAction Stop).Source
$git = (Get-Command git.exe -ErrorAction Stop).Source
$curl = (Get-Command curl.exe -ErrorAction Stop).Source

Push-Location -LiteralPath $repoRoot
try {
    $status = Invoke-Native $git @('status', '--porcelain=v1')
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw 'Git working tree must be clean before publishing a stable release.'
    }
    $sourceBuild = Assert-CurrentSourceBuildMatchesRelease $contract
    $statusAfterBuild = Invoke-Native $git @('status', '--porcelain=v1')
    if (-not [string]::IsNullOrWhiteSpace($statusAfterBuild)) {
        throw 'Git working tree changed during the fresh source verification build.'
    }
    $head = (Invoke-Native $git @('rev-parse', 'HEAD')).Trim()
    if ((Invoke-Native $git @('cat-file', '-t', "refs/tags/$tag")).Trim() -cne 'tag') {
        throw "$tag must be an annotated tag."
    }
    $localTagCommit = (Invoke-Native $git @('rev-parse', "$tag^{}" )).Trim()
    if (-not $localTagCommit.Equals($head, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$tag does not resolve to HEAD."
    }

    $remoteMainText = Invoke-Native $git @('ls-remote', '--heads', 'origin', 'refs/heads/main')
    $remoteMainLines = @($remoteMainText -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($remoteMainLines.Count -ne 1) { throw 'Remote origin/main could not be resolved uniquely.' }
    $remoteMain = ($remoteMainLines[0] -split "`t")[0]
    if (-not $remoteMain.Equals($head, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Remote origin/main does not equal local HEAD.'
    }

    $tagRef = "refs/tags/$tag"
    $peeledTagRef = $tagRef + '^{}'
    $remoteTagText = Invoke-Native $git @('ls-remote', 'origin', $tagRef, $peeledTagRef)
    $remoteTagRefs = @{}
    foreach ($line in @($remoteTagText -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $parts = $line -split "`t"
        if ($parts.Count -eq 2) { $remoteTagRefs[$parts[1]] = $parts[0] }
    }
    if (-not $remoteTagRefs.ContainsKey($tagRef) -or -not $remoteTagRefs.ContainsKey($peeledTagRef) -or
        -not ([string]$remoteTagRefs[$peeledTagRef]).Equals($head, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Remote annotated tag $tag does not resolve to HEAD."
    }

    Invoke-Native $gh @('auth', 'status', '--hostname', 'github.com') | Out-Null
    $repoText = Invoke-Native $gh @('repo', 'view', $Repository, '--json', 'nameWithOwner,visibility')
    $repo = Get-Json -Text $repoText -Label 'GitHub repository metadata'
    if ([string]$repo.nameWithOwner -cne $Repository -or [string]$repo.visibility -cne 'PUBLIC') {
        throw 'The configured GitHub repository is not the expected public repository.'
    }
    $verificationRoot = Join-Path $releaseParent ('.github-release-verify-' + [Guid]::NewGuid().ToString('N'))
    $authenticatedRoot = Join-Path $verificationRoot 'authenticated'
    $authenticatedDownloadPath = Join-Path $authenticatedRoot $assetName
    $publicDownloadPath = Join-Path $verificationRoot ('public-' + $assetName)
    New-Item -ItemType Directory -Path $verificationRoot -ErrorAction Stop | Out-Null
    $publishedThisRun = $false
    try {
        $release = Get-ReleaseByTag $gh $Repository $tag
        if ($null -eq $release) {
            $notes = 'Complete verified portable release for launcher-managed updates.'
            $createdText = Invoke-Native $gh @(
                'api', '--method', 'POST', "repos/$Repository/releases",
                '-f', "tag_name=$tag",
                '-f', "target_commitish=$head",
                '-f', "name=LF Portable $($contract.Version)",
                '-f', "body=$notes",
                '-F', 'draft=true',
                '-F', 'prerelease=false'
            )
            $release = Get-Json -Text $createdText -Label 'Created GitHub draft release'
        }
        if ([bool]$release.prerelease -or [string]$release.tag_name -cne $tag) {
            throw 'GitHub Release metadata is inconsistent.'
        }
        $releaseId = [long]$release.id
        if ($releaseId -le 0) { throw 'GitHub Release metadata has no valid ID.' }
        if (@($release.assets).Count -eq 0) {
            if (-not [bool]$release.draft) { throw 'Published GitHub Release has no program asset.' }
            Invoke-Native $gh @('release', 'upload', $tag, $archivePath, '--repo', $Repository) | Out-Null
        }
        $expectedReleaseState = if ([bool]$release.draft) { 'Draft' } else { 'Published' }
        $verifiedRelease = Wait-VerifiedReleaseAsset $gh $Repository $tag $expectedReleaseState `
            $archiveVerification.Length $archiveVerification.Sha256 -ReleaseId $releaseId
        $release = $verifiedRelease.Release
        $releaseAsset = $verifiedRelease.Asset

        New-Item -ItemType Directory -Path $authenticatedRoot -ErrorAction Stop | Out-Null
        [void](Wait-ReleaseTagVisible $gh $Repository $tag $releaseId)
        Invoke-AuthenticatedAssetDownload $gh $Repository $tag $assetName $authenticatedRoot `
            $authenticatedDownloadPath $archiveVerification.Length $archiveVerification.Sha256 | Out-Null
        $authenticatedVerification = Assert-ReleaseArchive $authenticatedDownloadPath $manifestPath $contract $sevenZip.Path
        if ($authenticatedVerification.Length -ne $archiveVerification.Length -or
            -not $authenticatedVerification.Sha256.Equals(
                $archiveVerification.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Authenticated GitHub asset round-trip differs from the verified local archive.'
        }

        if ([bool]$release.draft) {
            $publishedText = Invoke-Native $gh @(
                'api', '--method', 'PATCH', "repos/$Repository/releases/$releaseId",
                '-F', 'draft=false',
                '-f', 'make_latest=true'
            )
            $publishedMetadata = Get-Json -Text $publishedText -Label 'Published GitHub Release'
            if ([long]$publishedMetadata.id -ne $releaseId -or [bool]$publishedMetadata.draft) {
                throw 'GitHub did not publish the expected draft release.'
            }
            $publishedThisRun = $true
        }
        $publishedRelease = Wait-VerifiedReleaseAsset $gh $Repository $tag 'Published' `
            $archiveVerification.Length $archiveVerification.Sha256 -ReleaseId $releaseId
        $latestRelease = Wait-LatestVerifiedRelease $gh $Repository $tag `
            $archiveVerification.Length $archiveVerification.Sha256
        $latest = $latestRelease.Release
        $latestAsset = $latestRelease.Asset

        Invoke-PublicAssetDownload $curl ([string]$latestAsset.browser_download_url) $publicDownloadPath `
            $archiveVerification.Length $archiveVerification.Sha256 | Out-Null
        $publicVerification = Assert-ReleaseArchive $publicDownloadPath $manifestPath $contract $sevenZip.Path
        if ($publicVerification.Length -ne $archiveVerification.Length -or
            -not $publicVerification.Sha256.Equals($archiveVerification.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Public round-trip release archive differs from the verified local archive.'
        }
    }
    catch {
        $publicationError = $_
        if ($publishedThisRun) {
            try {
                $rollbackText = Invoke-Native $gh @(
                    'api', '--method', 'PATCH', "repos/$Repository/releases/$releaseId",
                    '-F', 'draft=true'
                )
                $rollbackMetadata = Get-Json -Text $rollbackText -Label 'Rolled-back GitHub Release'
                if ([long]$rollbackMetadata.id -ne $releaseId -or -not [bool]$rollbackMetadata.draft) {
                    throw 'GitHub did not restore the expected release to draft state.'
                }
                $rolledBack = Wait-ReleaseByTag $gh $Repository $tag 'Draft' 1 -ReleaseId $releaseId
            }
            catch {
                throw "Release verification failed after publication and rollback to draft also failed. Original error: $($publicationError.Exception.Message) Rollback error: $($_.Exception.Message)"
            }
        }
        throw $publicationError
    }
    finally {
        if (Test-Path -LiteralPath $verificationRoot -PathType Container) {
            Remove-Item -LiteralPath $verificationRoot -Recurse -Force
        }
    }

    [pscustomobject]@{
        Status = 'PublishedAndRoundTripVerified'
        Repository = $Repository
        Tag = $tag
        ReleaseId = [long]$latest.id
        AssetName = $assetName
        AssetBytes = [long]$archiveVerification.Length
        AssetSha256 = $archiveVerification.Sha256
        PublicDownloadUrl = [string]$latestAsset.browser_download_url
        SourceCommit = $head
        OfficialCodexVersion = [string]$official.Version
        SandboxValidationResult = $sandboxResult
        UsbRoot = $usb
        CompressionToolVersion = [string]$sevenZip.Version
        SourceRebuild = $sourceBuild
        CommonArchiveEntryCount = [int]$commonVerification.EntryCount
        CommonArchiveStoreEntries = [int]$commonVerification.StoreEntries
        CommonArchiveDeflateEntries = [int]$commonVerification.DeflateEntries
        ReleaseArchiveStoreEntries = [int]$archiveVerification.StoreEntries
        ReleaseArchiveDeflateEntries = [int]$archiveVerification.DeflateEntries
    }
}
finally {
    Pop-Location
}
