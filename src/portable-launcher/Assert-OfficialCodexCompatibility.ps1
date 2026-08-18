[CmdletBinding()]
param(
    [string]$CacheRoot,
    [string]$ReferenceLauncherPath,
    [switch]$RunLauncherSelfTest,
    [ValidateRange(30, 1800)]
    [int]$LauncherSelfTestTimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$officialHost = 'persistent.oaistatic.com'
$officialIdentityName = 'OpenAI.Codex'
$officialPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$minimumPackageBytes = 100L * 1024L * 1024L
$maximumPackageBytes = 3L * 1024L * 1024L * 1024L
$requiredBundledPluginsByArchitecture = @{
    x64 = @(
        'sites',
        'browser',
        'chrome',
        'computer-use',
        'latex',
        'deep-research',
        'visualize'
    )
    arm64 = @(
        'sites',
        'browser',
        'chrome',
        'computer-use',
        'deep-research',
        'visualize'
    )
}
$sharedBundledPlugins = @(
    'sites',
    'browser',
    'chrome',
    'computer-use',
    'deep-research',
    'visualize'
)

# The first-run announcement contract is intentionally pinned to the current
# official desktop implementation.  If the official UI changes, the gate must
# fail before a launcher is compiled so the portable rewrite can be updated
# and revalidated against the new package.
$officialModelAnnouncement = 'gpt-5.6-sol'
$officialTryModelAvailabilityGateText =
    'function PNc(){let e=(0,LNc.c)(3),{announcementContent:t,dismissAnnouncement:n,showAnnouncement:r}=Eri();if(!r||t==null)return null;'
$officialTryModelUpgradeGateText =
    'function FNc(){let e=(0,LNc.c)(3),{announcementContent:t,dismissAnnouncement:n,showAnnouncement:r}=Dri();if(!r||t==null)return null;'
$officialTryModelCtaMarker =
    'id:`codexUpgradeModal.tryNewModel`,defaultMessage:`Try {modelName} now`'
$officialModelAnnouncementMarker =
    'dNc=`gpt-5.6-sol`,fNc=Od({gpt56SolAnnouncement:'
$maximumAsarHeaderBytes = 64L * 1024L * 1024L
$maximumAppInitialBytes = 64L * 1024L * 1024L

# These are deliberately constants. A build must inspect the current official
# packages and cannot substitute a mirror, local file, or stale offline input.
$officialPackages = @(
    [pscustomobject]@{
        Architecture = 'x64'
        Uri = [Uri]'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
        Path = '/codex-app-prod/ChatGPT-x64.msix'
        FileName = 'ChatGPT-x64.msix'
    },
    [pscustomobject]@{
        Architecture = 'arm64'
        Uri = [Uri]'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-arm64.msix'
        Path = '/codex-app-prod/ChatGPT-arm64.msix'
        FileName = 'ChatGPT-arm64.msix'
    }
)

function Get-CanonicalDirectoryPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Directory path cannot be empty.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Directory path has no filesystem root: $Path"
    }
    $trimmed = $full.TrimEnd([char[]]@('\', '/'))
    if ($trimmed.Length -lt $root.Length) { return $root }
    return $trimmed
}

function Test-PathWithin([string]$Candidate, [string]$Root) {
    $candidateFull = Get-CanonicalDirectoryPath $Candidate
    $rootFull = Get-CanonicalDirectoryPath $Root
    if ($candidateFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = if ($rootFull.EndsWith('\', [StringComparison]::Ordinal)) {
        $rootFull
    }
    else {
        $rootFull + '\'
    }
    return $candidateFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePointInExistingAncestry([string]$Path) {
    $current = Get-CanonicalDirectoryPath $Path
    $root = Get-CanonicalDirectoryPath ([IO.Path]::GetPathRoot($current))
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Compatibility cache path is or is beneath a reparse point: $current"
            }
        }
        if ($current.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = Get-CanonicalDirectoryPath $parent.FullName
    }
}

function Ensure-SafeDirectory([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "Expected a directory but found another filesystem object: $Path"
        }
    }
    else {
        [IO.Directory]::CreateDirectory($Path) | Out-Null
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Compatibility cache directory cannot be a reparse point: $Path"
    }
}

function Assert-OfficialPackageUri([Uri]$Uri, [object]$Package, [string]$Label) {
    if ($null -eq $Uri -or -not $Uri.IsAbsoluteUri -or
        -not $Uri.Scheme.Equals([Uri]::UriSchemeHttps, [StringComparison]::OrdinalIgnoreCase) -or
        -not $Uri.Host.Equals($officialHost, [StringComparison]::OrdinalIgnoreCase) -or
        $Uri.Port -ne 443 -or -not [string]::IsNullOrEmpty($Uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($Uri.Query) -or -not [string]::IsNullOrEmpty($Uri.Fragment) -or
        -not $Uri.AbsolutePath.Equals([string]$Package.Path, [StringComparison]::Ordinal)) {
        throw "$Label is not the fixed official HTTPS endpoint for $($Package.Architecture): $Uri"
    }
}

function New-OfficialHttpRequest([object]$Package, [string]$Method) {
    Assert-OfficialPackageUri $Package.Uri $Package "$Method request URL"
    $request = [Net.HttpWebRequest]::Create($Package.Uri)
    $request.Method = $Method
    $request.AllowAutoRedirect = $false
    $request.AutomaticDecompression = [Net.DecompressionMethods]::None
    $request.CachePolicy = New-Object Net.Cache.RequestCachePolicy(
        [Net.Cache.RequestCacheLevel]::NoCacheNoStore)
    $request.Headers['Cache-Control'] = 'no-cache, no-store, max-age=0'
    $request.Headers['Pragma'] = 'no-cache'
    $request.UserAgent = 'LFPortable-OfficialCompatibility/1.0'
    $request.Timeout = 1800000
    $request.ReadWriteTimeout = 1800000
    return $request
}

function Get-OfficialHttpResponse([object]$Package, [string]$Method) {
    $request = New-OfficialHttpRequest $Package $Method
    $response = $null
    try {
        $response = [Net.HttpWebResponse]$request.GetResponse()
    }
    catch [Net.WebException] {
        $failureResponse = $_.Exception.Response -as [Net.HttpWebResponse]
        if ($null -ne $failureResponse) {
            try { $status = [int]$failureResponse.StatusCode }
            finally { $failureResponse.Close() }
            throw "Official $($Package.Architecture) MSIX $Method request returned HTTP $status."
        }
        throw "Official $($Package.Architecture) MSIX $Method request failed: $($_.Exception.Message)"
    }

    try {
        if ($response.StatusCode -ne [Net.HttpStatusCode]::OK) {
            throw "Official $($Package.Architecture) MSIX $Method request returned HTTP $([int]$response.StatusCode)."
        }
        Assert-OfficialPackageUri $response.ResponseUri $Package "$Method response URL"
        return $response
    }
    catch {
        $response.Close()
        throw
    }
}

function Get-ValidatedETag([string]$Value, [string]$Label) {
    $etag = if ($null -eq $Value) { '' } else { $Value.Trim() }
    if ([string]::IsNullOrWhiteSpace($etag) -or $etag.Length -gt 512 -or
        $etag -match '[\x00-\x20\x7F]') {
        throw "$Label has a missing or invalid ETag."
    }
    return $etag
}

function Get-TextSha256([string]$Value) {
    $bytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Get-FreshOfficialHead([object]$Package) {
    $response = Get-OfficialHttpResponse $Package 'HEAD'
    try {
        [long]$contentLength = $response.ContentLength
        if ($contentLength -lt $minimumPackageBytes -or $contentLength -gt $maximumPackageBytes) {
            throw "Official $($Package.Architecture) MSIX HEAD Content-Length is outside the supported range: $contentLength"
        }
        $etag = Get-ValidatedETag ([string]$response.Headers['ETag']) (
            "Official $($Package.Architecture) MSIX HEAD response")
        return [pscustomobject]@{
            Architecture = [string]$Package.Architecture
            Uri = [string]$Package.Uri.AbsoluteUri
            ContentLength = $contentLength
            ETag = $etag
            ETagKey = Get-TextSha256 $etag
        }
    }
    finally {
        $response.Close()
    }
}

function Assert-FourPartVersion([string]$Value, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -notmatch '^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}$') {
        throw "$Label is not a four-part numeric version: $Value"
    }
    $parsed = $null
    if (-not [Version]::TryParse($Value, [ref]$parsed) -or $null -eq $parsed -or
        $parsed.Major -gt 65535 -or $parsed.Minor -gt 65535 -or
        $parsed.Build -gt 65535 -or $parsed.Revision -gt 65535 -or
        -not $parsed.ToString(4).Equals($Value, [StringComparison]::Ordinal)) {
        throw "$Label is not a canonical four-part MSIX version: $Value"
    }
    return $Value
}

function Get-ZipEntryAttributes([IO.Compression.ZipArchiveEntry]$Entry) {
    return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Entry.ExternalAttributes), 0)
}

function Get-SafeMsixEntryPath([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.StartsWith('/') -or
        $Name.StartsWith('\') -or $Name.Contains(':') -or $Name.Contains('\') -or
        $Name -match '[\x00-\x1F]') {
        throw "MSIX contains an unsafe entry path: $Name"
    }
    $isDirectory = $Name.EndsWith('/', [StringComparison]::Ordinal)
    $path = if ($isDirectory) { $Name.Substring(0, $Name.Length - 1) } else { $Name }
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "MSIX contains an unsafe entry path: $Name"
    }
    $segments = @($path.Split('/'))
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) {
        throw "MSIX contains an unsafe entry path: $Name"
    }
    foreach ($segment in $segments) {
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ') -or
            $segment -match '[<>"|?*]' -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "MSIX contains a Windows-unsafe entry path: $Name"
        }
    }
    return [pscustomobject]@{
        Path = $path
        IsDirectory = $isDirectory
    }
}

function Assert-RegularArchiveEntry([IO.Compression.ZipArchiveEntry]$Entry) {
    $attributes = Get-ZipEntryAttributes $Entry
    $unixType = ($attributes -shr 16) -band 0xF000
    if ($unixType -eq 0xA000 -or (($attributes -band 0x400) -ne 0)) {
        throw "MSIX contains a symbolic-link or reparse-point entry: $($Entry.FullName)"
    }
}

function Read-StrictZipEntryText([IO.Compression.ZipArchiveEntry]$Entry, [string]$Label) {
    if ($null -eq $Entry -or $Entry.Length -le 0 -or $Entry.Length -gt 4MB) {
        throw "$Label has an invalid text-entry length."
    }
    $stream = $Entry.Open()
    try {
        $reader = New-Object IO.StreamReader(
            $stream, (New-Object Text.UTF8Encoding($false, $true)), $true)
        try {
            $text = $reader.ReadToEnd()
            if ([string]::IsNullOrWhiteSpace($text)) { throw "$Label is empty." }
            return $text
        }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-RequiredArchiveEntry([object]$Entries, [string]$Path, [string]$Label) {
    $entry = $null
    if (-not $Entries.TryGetValue($Path, [ref]$entry) -or $null -eq $entry) {
        throw "$Label is missing: $Path"
    }
    if ($entry.Length -le 0) {
        throw "$Label is empty: $Path"
    }
    return $entry
}

function Get-StrictManifestIdentity([IO.Compression.ZipArchiveEntry]$ManifestEntry,
    [string]$ExpectedArchitecture) {
    $manifestText = Read-StrictZipEntryText $ManifestEntry 'MSIX AppxManifest.xml'
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $document = New-Object Xml.XmlDocument
    $document.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader($manifestText)), $settings)
    try { $document.Load($reader) }
    finally { $reader.Dispose() }

    $identityNodes = $document.SelectNodes(
        '/*[local-name()="Package"]/*[local-name()="Identity"]')
    if ($null -eq $identityNodes -or $identityNodes.Count -ne 1) {
        throw 'MSIX AppxManifest.xml must contain exactly one Package/Identity element.'
    }
    $identity = $identityNodes[0]
    $name = [string]$identity.GetAttribute('Name')
    $publisher = [string]$identity.GetAttribute('Publisher')
    $architecture = [string]$identity.GetAttribute('ProcessorArchitecture')
    $version = Assert-FourPartVersion ([string]$identity.GetAttribute('Version')) (
        'MSIX Identity Version')
    if (-not $name.Equals($officialIdentityName, [StringComparison]::Ordinal) -or
        -not $publisher.Equals($officialPublisher, [StringComparison]::Ordinal) -or
        -not $architecture.Equals($ExpectedArchitecture, [StringComparison]::Ordinal)) {
        throw "MSIX identity mismatch: Name=$name, Publisher=$publisher, ProcessorArchitecture=$architecture, Version=$version"
    }

    $applicationNodes = $document.SelectNodes(
        '/*[local-name()="Package"]/*[local-name()="Applications"]/*[local-name()="Application"]')
    if ($null -eq $applicationNodes -or $applicationNodes.Count -ne 1 -or
        -not ([string]$applicationNodes[0].GetAttribute('Executable')).Equals(
            'app/ChatGPT.exe', [StringComparison]::Ordinal)) {
        throw 'MSIX AppxManifest.xml must declare exactly one app/ChatGPT.exe application.'
    }

    $publisherDisplayNodes = $document.SelectNodes(
        '/*[local-name()="Package"]/*[local-name()="Properties"]/*[local-name()="PublisherDisplayName"]')
    if ($null -eq $publisherDisplayNodes -or $publisherDisplayNodes.Count -ne 1 -or
        -not $publisherDisplayNodes[0].InnerText.Trim().Equals('OpenAI', [StringComparison]::Ordinal)) {
        throw 'MSIX PublisherDisplayName is not exactly OpenAI.'
    }

    return [pscustomobject]@{
        Name = $name
        Publisher = $publisher
        Architecture = $architecture
        Version = $version
    }
}

function Get-StrictPluginVersion([IO.Compression.ZipArchiveEntry]$Entry, [string]$Plugin) {
    $label = "Bundled plugin $Plugin manifest"
    try {
        $manifest = Read-StrictZipEntryText $Entry $label | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$label is invalid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $manifest -or $manifest -is [Array]) {
        throw "$label must be one JSON object."
    }
    $name = [string]$manifest.name
    $version = [string]$manifest.version
    if (-not $name.Equals($Plugin, [StringComparison]::Ordinal) -or
        [string]::IsNullOrWhiteSpace($version) -or
        $version.Equals('latest', [StringComparison]::OrdinalIgnoreCase) -or
        $version -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') {
        throw "$label has an unsafe or inconsistent name/version."
    }
    return $version
}

function Get-RequiredBundledPlugins([string]$Architecture) {
    if ([string]::IsNullOrWhiteSpace($Architecture) -or
        -not $requiredBundledPluginsByArchitecture.ContainsKey($Architecture)) {
        throw "Bundled plugin contract is undefined for architecture: $Architecture"
    }
    return @($requiredBundledPluginsByArchitecture[$Architecture])
}

function Get-BundledPluginVersionSummary([object]$PluginVersions, [string[]]$Plugins) {
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($plugin in $Plugins) {
        $property = $PluginVersions.PSObject.Properties[$plugin]
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            throw "Bundled plugin version summary is missing: $plugin"
        }
        $items.Add("$plugin=$([string]$property.Value)")
    }
    return ($items.ToArray() -join ', ')
}

function Assert-SharedBundledPluginVersions([object]$X64, [object]$Arm64) {
    foreach ($plugin in $sharedBundledPlugins) {
        $x64Property = $X64.PluginVersions.PSObject.Properties[$plugin]
        $arm64Property = $Arm64.PluginVersions.PSObject.Properties[$plugin]
        if ($null -eq $x64Property -or $null -eq $arm64Property) {
            throw "Official package shared bundled plugin metadata is missing: $plugin"
        }
        $x64Version = [string]$x64Property.Value
        $arm64Version = [string]$arm64Property.Value
        if (-not $x64Version.Equals($arm64Version, [StringComparison]::Ordinal)) {
            throw "Official shared bundled plugin versions differ for ${plugin}: x64=$x64Version, arm64=$arm64Version."
        }
    }
}

function Read-StrictStreamBytes([IO.Stream]$Stream, [int]$Length, [string]$Label) {
    if ($null -eq $Stream -or $Length -lt 0) {
        throw "$Label has an invalid byte length."
    }
    $bytes = New-Object byte[] $Length
    [int]$offset = 0
    while ($offset -lt $bytes.Length) {
        [int]$read = $Stream.Read($bytes, $offset, $bytes.Length - $offset)
        if ($read -le 0) {
            throw "$Label ended before its declared byte length."
        }
        $offset += $read
    }
    return ,$bytes
}

function Discard-StrictStreamBytes([IO.Stream]$Stream, [long]$Length, [string]$Label) {
    if ($null -eq $Stream -or $Length -lt 0) {
        throw "$Label has an invalid byte length."
    }
    $buffer = New-Object byte[] (64 * 1024)
    [long]$remaining = $Length
    while ($remaining -gt 0) {
        [int]$requested = [int][Math]::Min($remaining, [long]$buffer.Length)
        [int]$read = $Stream.Read($buffer, 0, $requested)
        if ($read -le 0) {
            throw "$Label ended before its declared byte length."
        }
        $remaining -= $read
    }
}

function ConvertTo-StrictNonNegativeInt64([object]$Value, [string]$Label) {
    if ($null -eq $Value -or $Value -is [bool]) {
        throw "$Label is not a non-negative integer."
    }
    try {
        $text = [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw "$Label is not a non-negative integer."
    }
    if ([string]::IsNullOrWhiteSpace($text) -or $text -notmatch '^(?:0|[1-9][0-9]*)$') {
        throw "$Label is not a canonical non-negative integer."
    }
    [long]$parsed = 0
    if (-not [Int64]::TryParse($text, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        throw "$Label exceeds Int64."
    }
    return $parsed
}

function Assert-AsarJsonObject([object]$Value, [string]$Label) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [Array] -or
        $Value -is [ValueType]) {
        throw "$Label must be one JSON object."
    }
}

function Get-OrdinalStringOccurrenceCount([string]$Text, [string]$Needle, [string]$Label) {
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Needle)) {
        throw "$Label cannot be empty."
    }
    [int]$count = 0
    [int]$position = 0
    while ($position -le ($Text.Length - $Needle.Length)) {
        [int]$match = $Text.IndexOf($Needle, $position, [StringComparison]::Ordinal)
        if ($match -lt 0) { break }
        if ($count -eq [int]::MaxValue) {
            throw "$Label occurrence count overflowed Int32."
        }
        $count++
        $position = $match + $Needle.Length
    }
    return $count
}

function Get-OfficialAsarTryModelContract([IO.Compression.ZipArchiveEntry]$AsarEntry,
    [string]$Architecture) {
    if ($null -eq $AsarEntry -or [string]::IsNullOrWhiteSpace($Architecture) -or
        $AsarEntry.Length -le 16) {
        throw 'MSIX app.asar has an invalid length.'
    }
    if (-not [BitConverter]::IsLittleEndian) {
        throw 'The compatibility gate requires a little-endian ASAR parser.'
    }

    $stream = $null
    $headerBytes = $null
    $appInitialBytes = $null
    try {
        $stream = $AsarEntry.Open()
        if ($null -eq $stream) { throw 'MSIX app.asar has no readable stream.' }

        $prefix = Read-StrictStreamBytes $stream 16 'Electron ASAR header'
        try {
            [long]$sizePayloadLength = [BitConverter]::ToUInt32($prefix, 0)
            [long]$headerPickleLength = [BitConverter]::ToUInt32($prefix, 4)
            [long]$headerPayloadLength = [BitConverter]::ToUInt32($prefix, 8)
            [long]$headerJsonLength = [BitConverter]::ToUInt32($prefix, 12)
        }
        finally {
            [Array]::Clear($prefix, 0, $prefix.Length)
        }
        if ($sizePayloadLength -ne 4 -or $headerPickleLength -lt 8 -or
            $headerPayloadLength -lt 4 -or $headerJsonLength -le 0 -or
            $headerJsonLength -gt $maximumAsarHeaderBytes) {
            throw 'Electron ASAR header has an unsupported length layout.'
        }

        [long]$dataOffset = 8L + $headerPickleLength
        [long]$headerEnd = 16L + $headerJsonLength
        if ($dataOffset -lt $headerEnd -or $dataOffset -gt [long]$AsarEntry.Length) {
            throw 'Electron ASAR header data offset is invalid.'
        }
        $headerBytes = Read-StrictStreamBytes $stream ([int]$headerJsonLength) `
            'Electron ASAR header JSON'
        try {
            $utf8 = New-Object Text.UTF8Encoding($false, $true)
            $headerText = $utf8.GetString($headerBytes)
        }
        finally {
            [Array]::Clear($headerBytes, 0, $headerBytes.Length)
            $headerBytes = $null
        }
        if ([string]::IsNullOrWhiteSpace($headerText)) {
            throw 'Electron ASAR header JSON is empty.'
        }
        try {
            $header = ConvertFrom-Json -InputObject $headerText -ErrorAction Stop
        }
        catch {
            throw "Electron ASAR header JSON is invalid: $($_.Exception.Message)"
        }
        finally {
            $headerText = $null
        }
        Assert-AsarJsonObject $header 'Electron ASAR header'
        $rootFilesProperty = $header.PSObject.Properties['files']
        if ($null -eq $rootFilesProperty) {
            throw 'Electron ASAR file table is missing.'
        }
        $rootFiles = $rootFilesProperty.Value
        Assert-AsarJsonObject $rootFiles 'Electron ASAR file table'

        $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' (
            [StringComparer]::Ordinal)
        $appInitialMatches = New-Object 'System.Collections.Generic.List[object]'
        $directories = New-Object 'System.Collections.Generic.Stack[object]'
        $directories.Push([pscustomobject]@{
                Files = $rootFiles
                Prefix = ''
            })
        while ($directories.Count -gt 0) {
            $directory = $directories.Pop()
            Assert-AsarJsonObject $directory.Files 'Electron ASAR directory'
            foreach ($property in @($directory.Files.PSObject.Properties)) {
                $segment = [string]$property.Name
                if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..') -or
                    $segment.Contains('/') -or $segment.Contains('\') -or
                    $segment -match '[\x00-\x1F]') {
                    throw "Electron ASAR contains an unsafe file-table segment: $segment"
                }
                $relativePath = if ([string]::IsNullOrEmpty([string]$directory.Prefix)) {
                    $segment
                }
                else {
                    [string]$directory.Prefix + '/' + $segment
                }
                if (-not $seenPaths.Add($relativePath)) {
                    throw "Electron ASAR contains a duplicate file-table path: $relativePath"
                }
                $node = $property.Value
                Assert-AsarJsonObject $node "Electron ASAR file-table node $relativePath"

                $childrenProperty = $node.PSObject.Properties['files']
                if ($null -ne $childrenProperty) {
                    if ($null -ne $node.PSObject.Properties['offset'] -or
                        $null -ne $node.PSObject.Properties['size']) {
                        throw "Electron ASAR directory has file metadata: $relativePath"
                    }
                    Assert-AsarJsonObject $childrenProperty.Value `
                        "Electron ASAR child table $relativePath"
                    $directories.Push([pscustomobject]@{
                            Files = $childrenProperty.Value
                            Prefix = $relativePath
                        })
                    continue
                }

                $sizeProperty = $node.PSObject.Properties['size']
                if ($null -eq $sizeProperty) {
                    throw "Electron ASAR file has no size: $relativePath"
                }
                [long]$entrySize = ConvertTo-StrictNonNegativeInt64 $sizeProperty.Value `
                    "Electron ASAR file size $relativePath"
                $offsetProperty = $node.PSObject.Properties['offset']
                [long]$entryOffset = -1
                if ($null -ne $offsetProperty) {
                    $entryOffset = ConvertTo-StrictNonNegativeInt64 $offsetProperty.Value `
                        "Electron ASAR file offset $relativePath"
                }
                $unpackedProperty = $node.PSObject.Properties['unpacked']
                [bool]$isUnpacked = $false
                if ($null -ne $unpackedProperty) {
                    if ($unpackedProperty.Value -isnot [bool]) {
                        throw "Electron ASAR unpacked flag is invalid: $relativePath"
                    }
                    $isUnpacked = [bool]$unpackedProperty.Value
                }
                if ($entryOffset -lt 0 -and -not $isUnpacked) {
                    throw "Electron ASAR packed file has no offset: $relativePath"
                }

                if ($relativePath -match '^webview/assets/app-initial-[^/\\]+\.js$') {
                    $appInitialMatches.Add([pscustomobject]@{
                            Path = $relativePath
                            Offset = $entryOffset
                            Length = $entrySize
                            IsUnpacked = $isUnpacked
                            HasIntegrity = ($null -ne $node.PSObject.Properties['integrity'])
                        })
                }
            }
        }
        if ($appInitialMatches.Count -ne 1) {
            throw "Electron ASAR must contain exactly one app-initial JavaScript entry; found $($appInitialMatches.Count)."
        }

        $appInitial = $appInitialMatches[0]
        if ($appInitial.IsUnpacked -or $appInitial.Offset -lt 0 -or -not $appInitial.HasIntegrity -or
            $appInitial.Length -le 0 -or $appInitial.Length -gt $maximumAppInitialBytes) {
            throw 'Electron ASAR app-initial JavaScript entry has an invalid storage layout.'
        }
        if ($appInitial.Offset -gt ([long]$AsarEntry.Length - $dataOffset)) {
            throw 'Electron ASAR app-initial JavaScript offset exceeds the archive.'
        }
        [long]$appInitialStart = $dataOffset + $appInitial.Offset
        if ($appInitial.Length -gt ([long]$AsarEntry.Length - $appInitialStart)) {
            throw 'Electron ASAR app-initial JavaScript length exceeds the archive.'
        }
        if ($appInitialStart -lt $headerEnd) {
            throw 'Electron ASAR app-initial JavaScript overlaps the header.'
        }

        [long]$bytesConsumed = $headerEnd
        Discard-StrictStreamBytes $stream ($appInitialStart - $bytesConsumed) `
            'Electron ASAR app-initial JavaScript prefix'
        $appInitialBytes = Read-StrictStreamBytes $stream ([int]$appInitial.Length) `
            'Electron ASAR app-initial JavaScript'
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $appInitialSha256 = ([BitConverter]::ToString($sha.ComputeHash($appInitialBytes))).Replace('-', '')
        }
        finally {
            $sha.Dispose()
        }
        try {
            $appInitialText = $utf8.GetString($appInitialBytes)
        }
        finally {
            [Array]::Clear($appInitialBytes, 0, $appInitialBytes.Length)
            $appInitialBytes = $null
        }

        $availabilityGateCount = Get-OrdinalStringOccurrenceCount $appInitialText `
            $officialTryModelAvailabilityGateText 'Official Try model availability render gate'
        $upgradeGateCount = Get-OrdinalStringOccurrenceCount $appInitialText `
            $officialTryModelUpgradeGateText 'Official Try model upgrade render gate'
        $ctaCount = Get-OrdinalStringOccurrenceCount $appInitialText $officialTryModelCtaMarker `
            'Official Try model CTA marker'
        $announcementCount = Get-OrdinalStringOccurrenceCount $appInitialText `
            $officialModelAnnouncementMarker 'Official model announcement marker'
        $appInitialText = $null
        if ($availabilityGateCount -ne 1 -or $upgradeGateCount -ne 1 -or
            $ctaCount -ne 1 -or $announcementCount -ne 1) {
            throw ('Official {0} app-initial Try model contract changed: PNc/Eri={1}, ' +
                'FNc/Dri={2}, CTA={3}, {4} announcement={5}.' -f $Architecture,
                $availabilityGateCount, $upgradeGateCount, $ctaCount,
                $officialModelAnnouncement, $announcementCount)
        }

        return [pscustomobject]@{
            Architecture = $Architecture
            AppInitialPath = [string]$appInitial.Path
            AppInitialLength = [long]$appInitial.Length
            AppInitialSHA256 = $appInitialSha256
            OfficialPncGateCount = [int]$availabilityGateCount
            OfficialFncGateCount = [int]$upgradeGateCount
            TryModelCtaCount = [int]$ctaCount
            OfficialSolMarkerCount = [int]$announcementCount
            OfficialAnnouncementModel = $officialModelAnnouncement
        }
    }
    finally {
        if ($null -ne $headerBytes) { [Array]::Clear($headerBytes, 0, $headerBytes.Length) }
        if ($null -ne $appInitialBytes) { [Array]::Clear($appInitialBytes, 0, $appInitialBytes.Length) }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Assert-SharedOfficialTryModelContract([object]$X64, [object]$Arm64) {
    $contracts = @(
        [pscustomobject]@{ Package = $X64; Architecture = 'x64' },
        [pscustomobject]@{ Package = $Arm64; Architecture = 'arm64' }
    )
    foreach ($item in $contracts) {
        $contractProperty = $item.Package.PSObject.Properties['TryModelContract']
        if ($null -eq $contractProperty -or $null -eq $contractProperty.Value) {
            throw "Official $($item.Architecture) package has no Try model ASAR contract."
        }
        $contract = $contractProperty.Value
        Assert-AsarJsonObject $contract "Official $($item.Architecture) Try model ASAR contract"
        $architectureProperty = $contract.PSObject.Properties['Architecture']
        $modelProperty = $contract.PSObject.Properties['OfficialAnnouncementModel']
        $pathProperty = $contract.PSObject.Properties['AppInitialPath']
        if ($null -eq $architectureProperty -or $null -eq $modelProperty -or $null -eq $pathProperty -or
            -not ([string]$architectureProperty.Value).Equals([string]$item.Architecture,
                [StringComparison]::Ordinal) -or
            -not ([string]$modelProperty.Value).Equals($officialModelAnnouncement,
                [StringComparison]::Ordinal) -or
            -not ([string]$pathProperty.Value -match '^webview/assets/app-initial-[^/\\]+\.js$')) {
            throw "Official $($item.Architecture) Try model ASAR contract is inconsistent."
        }
        foreach ($metric in @('OfficialPncGateCount', 'OfficialFncGateCount',
                'TryModelCtaCount', 'OfficialSolMarkerCount')) {
            $metricProperty = $contract.PSObject.Properties[$metric]
            if ($null -eq $metricProperty -or
                (ConvertTo-StrictNonNegativeInt64 $metricProperty.Value "Official $($item.Architecture) $metric") -ne 1) {
                throw "Official $($item.Architecture) Try model ASAR contract does not have exactly one $metric."
            }
        }
    }

    $x64Contract = $X64.TryModelContract
    $arm64Contract = $Arm64.TryModelContract
    if (-not ([string]$x64Contract.OfficialAnnouncementModel).Equals(
            [string]$arm64Contract.OfficialAnnouncementModel, [StringComparison]::Ordinal)) {
        throw 'Official x64 and ARM64 Try model announcement models differ.'
    }
}

function Assert-OfficialMsixPackage([string]$Path, [object]$Package, [object]$Head) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Official $($Package.Architecture) MSIX is missing: $full"
    }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Official $($Package.Architecture) MSIX cannot be a reparse point: $full"
    }
    if ([long]$item.Length -ne [long]$Head.ContentLength) {
        throw "Official $($Package.Architecture) MSIX length mismatch: expected $($Head.ContentLength), found $($item.Length)."
    }

    $signature = Get-AuthenticodeSignature -FilePath $full
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        -not ([string]$signature.SignerCertificate.Subject).Equals(
            $officialPublisher, [StringComparison]::Ordinal)) {
        throw "Official $($Package.Architecture) MSIX Authenticode validation failed: $full"
    }

    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($full)
        if ($zip.Entries.Count -eq 0) { throw 'MSIX archive is empty.' }
        $entries = New-Object 'System.Collections.Generic.Dictionary[string,object]' (
            [StringComparer]::Ordinal)
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' (
            [StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($zip.Entries)) {
            Assert-RegularArchiveEntry $entry
            $safe = Get-SafeMsixEntryPath $entry.FullName
            if (-not $seen.Add([string]$safe.Path)) {
                throw "MSIX contains a duplicate entry path: $($safe.Path)"
            }
            if (-not $safe.IsDirectory) {
                [void]$entries.Add([string]$safe.Path, $entry)
            }
        }

        $manifestEntry = Get-RequiredArchiveEntry $entries 'AppxManifest.xml' 'MSIX required entry'
        $identity = Get-StrictManifestIdentity $manifestEntry ([string]$Package.Architecture)
        [void](Get-RequiredArchiveEntry $entries 'app/ChatGPT.exe' 'MSIX required entry')
        [void](Get-RequiredArchiveEntry $entries 'app/resources/codex.exe' 'MSIX required entry')
        $asarEntry = Get-RequiredArchiveEntry $entries 'app/resources/app.asar' 'MSIX required entry'
        $tryModelContract = Get-OfficialAsarTryModelContract $asarEntry `
            ([string]$Package.Architecture)

        $requiredBundledPlugins = @(Get-RequiredBundledPlugins ([string]$Package.Architecture))
        $expectedPluginSet = New-Object 'System.Collections.Generic.HashSet[string]' (
            [StringComparer]::Ordinal)
        foreach ($plugin in $requiredBundledPlugins) {
            if (-not $expectedPluginSet.Add($plugin)) {
                throw "Bundled plugin contract contains a duplicate for $($Package.Architecture): $plugin"
            }
        }

        $bundledPluginRoot = 'app/resources/plugins/openai-bundled/plugins/'
        $actualPluginSet = New-Object 'System.Collections.Generic.HashSet[string]' (
            [StringComparer]::Ordinal)
        foreach ($entryPathValue in $seen) {
            $entryPath = [string]$entryPathValue
            if (-not $entryPath.StartsWith($bundledPluginRoot, [StringComparison]::Ordinal)) { continue }
            $relative = $entryPath.Substring($bundledPluginRoot.Length)
            if ([string]::IsNullOrWhiteSpace($relative)) {
                throw "MSIX bundled plugin path has no plugin directory: $entryPath"
            }
            $separator = $relative.IndexOf('/')
            $plugin = if ($separator -lt 0) { $relative } else { $relative.Substring(0, $separator) }
            if ([string]::IsNullOrWhiteSpace($plugin)) {
                throw "MSIX bundled plugin path has an empty plugin directory: $entryPath"
            }
            [void]$actualPluginSet.Add($plugin)
        }
        $actualPlugins = @($actualPluginSet | Sort-Object)
        $expectedPlugins = @($expectedPluginSet | Sort-Object)
        if ($actualPlugins.Count -ne $expectedPlugins.Count -or
            (Compare-Object -CaseSensitive -ReferenceObject $expectedPlugins -DifferenceObject $actualPlugins)) {
            throw "MSIX bundled plugin directory set for $($Package.Architecture) is not exact. Expected=[$($expectedPlugins -join ', ')], Actual=[$($actualPlugins -join ', ')]."
        }

        $actualManifestSet = New-Object 'System.Collections.Generic.HashSet[string]' (
            [StringComparer]::Ordinal)
        foreach ($entryPathValue in $entries.Keys) {
            $entryPath = [string]$entryPathValue
            if (-not $entryPath.StartsWith($bundledPluginRoot, [StringComparison]::Ordinal)) { continue }
            $relative = $entryPath.Substring($bundledPluginRoot.Length)
            $segments = @($relative.Split('/'))
            if ($segments.Count -eq 3 -and
                $segments[1].Equals('.codex-plugin', [StringComparison]::Ordinal) -and
                $segments[2].Equals('plugin.json', [StringComparison]::Ordinal)) {
                [void]$actualManifestSet.Add([string]$segments[0])
            }
        }
        $actualManifests = @($actualManifestSet | Sort-Object)
        if ($actualManifests.Count -ne $expectedPlugins.Count -or
            (Compare-Object -CaseSensitive -ReferenceObject $expectedPlugins -DifferenceObject $actualManifests)) {
            throw "MSIX bundled plugin manifest set for $($Package.Architecture) is not exact. Expected=[$($expectedPlugins -join ', ')], Actual=[$($actualManifests -join ', ')]."
        }

        $pluginVersions = [ordered]@{}
        foreach ($plugin in $requiredBundledPlugins) {
            $pluginPath = "app/resources/plugins/openai-bundled/plugins/$plugin/.codex-plugin/plugin.json"
            $pluginEntry = Get-RequiredArchiveEntry $entries $pluginPath 'MSIX bundled plugin manifest'
            $pluginVersions[$plugin] = Get-StrictPluginVersion $pluginEntry $plugin
        }

        $sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpperInvariant()
        return [pscustomobject]@{
            Architecture = [string]$Package.Architecture
            Version = [string]$identity.Version
            Path = $full
            Length = [long]$item.Length
            SHA256 = $sha256
            ETag = [string]$Head.ETag
            PluginVersions = [pscustomobject]$pluginVersions
            TryModelContract = $tryModelContract
        }
    }
    catch {
        throw "Official $($Package.Architecture) MSIX compatibility validation failed: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

function Find-ValidatedCachedPackage([object]$Package, [object]$Head, [string]$Root) {
    $architectureRoot = Join-Path $Root ([string]$Package.Architecture)
    if (-not (Test-Path -LiteralPath $architectureRoot -PathType Container)) { return $null }
    $architectureItem = Get-Item -LiteralPath $architectureRoot -Force -ErrorAction Stop
    if (($architectureItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Compatibility cache architecture directory cannot be a reparse point: $architectureRoot"
    }
    $cacheMatches = New-Object System.Collections.Generic.List[object]
    foreach ($versionDirectory in @(Get-ChildItem -LiteralPath $architectureRoot -Directory -Force -ErrorAction Stop)) {
        if ($versionDirectory.Name -notmatch '^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}$') {
            continue
        }
        if (($versionDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Compatibility cache version directory cannot be a reparse point: $($versionDirectory.FullName)"
        }
        $etagDirectory = Join-Path $versionDirectory.FullName ('etag-' + [string]$Head.ETagKey)
        $candidate = Join-Path $etagDirectory ([string]$Package.FileName)
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $etagItem = Get-Item -LiteralPath $etagDirectory -Force -ErrorAction Stop
        if (($etagItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Compatibility cache ETag directory cannot be a reparse point: $etagDirectory"
        }
        try {
            $validated = Assert-OfficialMsixPackage $candidate $Package $Head
        }
        catch {
            $cacheError = $_
            try { [IO.File]::Delete($candidate) }
            catch {
                throw "Current $($Package.Architecture) MSIX cache is invalid and could not be removed: $candidate. Validation error: $($cacheError.Exception.Message). Removal error: $($_.Exception.Message)"
            }
            continue
        }
        if (-not ([string]$validated.Version).Equals(
                $versionDirectory.Name, [StringComparison]::Ordinal)) {
            throw "Compatibility cache version directory does not match its signed MSIX: $candidate"
        }
        $cacheMatches.Add($validated)
    }
    if ($cacheMatches.Count -gt 1) {
        throw "Compatibility cache contains multiple packages for the current $($Package.Architecture) ETag."
    }
    if ($cacheMatches.Count -eq 1) { return $cacheMatches[0] }
    return $null
}

function Remove-AbandonedDownloads([string]$Root) {
    $downloadRoot = Join-Path $Root '.downloads'
    if (-not (Test-Path -LiteralPath $downloadRoot -PathType Container)) { return }
    $directory = Get-Item -LiteralPath $downloadRoot -Force -ErrorAction Stop
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Compatibility download directory cannot be a reparse point: $downloadRoot"
    }
    $cutoff = [DateTime]::UtcNow.AddHours(-6)
    foreach ($file in @(Get-ChildItem -LiteralPath $downloadRoot -File -Force -ErrorAction Stop)) {
        if ($file.Name -notmatch '^ChatGPT-(?:x64|arm64)\.download-[0-9a-f]{32}\.msix$' -or
            $file.LastWriteTimeUtc -ge $cutoff) {
            continue
        }
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Abandoned compatibility download cannot be a reparse point: $($file.FullName)"
        }
        [IO.File]::Delete($file.FullName)
    }
}

function Download-OfficialPackage([object]$Package, [object]$Head, [string]$Root) {
    $downloadRoot = Join-Path $Root '.downloads'
    Ensure-SafeDirectory $downloadRoot
    $temporary = Join-Path $downloadRoot (
        [IO.Path]::GetFileNameWithoutExtension([string]$Package.FileName) +
        '.download-' + [guid]::NewGuid().ToString('N') + '.msix')
    $response = $null
    $input = $null
    $output = $null
    $completed = $false
    try {
        $response = Get-OfficialHttpResponse $Package 'GET'
        [long]$responseLength = $response.ContentLength
        if ($responseLength -ne [long]$Head.ContentLength) {
            throw "Official $($Package.Architecture) MSIX changed between HEAD and GET (Content-Length)."
        }
        $responseETag = Get-ValidatedETag ([string]$response.Headers['ETag']) (
            "Official $($Package.Architecture) MSIX GET response")
        if (-not $responseETag.Equals([string]$Head.ETag, [StringComparison]::Ordinal)) {
            throw "Official $($Package.Architecture) MSIX changed between HEAD and GET (ETag)."
        }

        $input = $response.GetResponseStream()
        if ($null -eq $input) { throw 'Official MSIX GET response has no body stream.' }
        $output = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] (1024 * 1024)
        [long]$written = 0
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($written -gt ([long]::MaxValue - $read)) { throw 'Official MSIX download length overflowed Int64.' }
            $output.Write($buffer, 0, $read)
            $written += $read
            if ($written -gt [long]$Head.ContentLength) {
                throw "Official $($Package.Architecture) MSIX download exceeded its HEAD Content-Length."
            }
        }
        $output.Flush($true)
        if ($written -ne [long]$Head.ContentLength) {
            throw "Official $($Package.Architecture) MSIX download is incomplete: expected $($Head.ContentLength), received $written."
        }
        $completed = $true
        return $temporary
    }
    finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $input) { $input.Dispose() }
        if ($null -ne $response) { $response.Close() }
        if (-not $completed -and (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Get-VerifiedOfficialPackage([object]$Package, [object]$Head, [string]$Root) {
    $cached = Find-ValidatedCachedPackage $Package $Head $Root
    if ($null -ne $cached) { return $cached }

    $temporary = Download-OfficialPackage $Package $Head $Root
    try {
        $downloaded = Assert-OfficialMsixPackage $temporary $Package $Head
        $versionRoot = Join-Path (Join-Path $Root ([string]$Package.Architecture)) (
            [string]$downloaded.Version)
        $etagRoot = Join-Path $versionRoot ('etag-' + [string]$Head.ETagKey)
        Ensure-SafeDirectory (Split-Path -Parent $versionRoot)
        Ensure-SafeDirectory $versionRoot
        Ensure-SafeDirectory $etagRoot
        $destination = Join-Path $etagRoot ([string]$Package.FileName)

        if (-not (Test-Path -LiteralPath $destination)) {
            try {
                [IO.File]::Move($temporary, $destination)
            }
            catch [IO.IOException] {
                if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw }
            }
        }
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            throw "Compatibility cache destination is not a regular file: $destination"
        }
        $final = Assert-OfficialMsixPackage $destination $Package $Head
        if (-not ([string]$final.Version).Equals(
                [string]$downloaded.Version, [StringComparison]::Ordinal) -or
            -not ([string]$final.SHA256).Equals(
                [string]$downloaded.SHA256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Compatibility cache activation changed the verified $($Package.Architecture) MSIX."
        }
        return $final
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            [IO.File]::Delete($temporary)
        }
    }
}

function ConvertTo-WindowsCommandLineArgument([string]$Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value.IndexOfAny([char[]]@(' ', "`t", "`r", "`n", '"')) -lt 0) { return $Value }
    $quoted = New-Object Text.StringBuilder
    [void]$quoted.Append('"')
    [int]$backslashes = 0
    for ([int]$index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$quoted.Append([char]92, ($backslashes * 2 + 1))
            [void]$quoted.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$quoted.Append([char]92, $backslashes)
            $backslashes = 0
        }
        [void]$quoted.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$quoted.Append([char]92, ($backslashes * 2))
    }
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Get-PeMachine([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 256 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw "Reference launcher has no MZ header: $Path"
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 6)) {
            throw "Reference launcher has an invalid PE offset: $Path"
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Reference launcher has no PE signature: $Path"
        }
        return [int]$reader.ReadUInt16()
    }
    finally { $reader.Dispose() }
}

function Stop-LauncherProcessTree([Diagnostics.Process]$Process) {
    if ($null -eq $Process) { return }
    try {
        if ($Process.HasExited) { return }
        $taskKill = Join-Path $env:WINDIR 'System32\taskkill.exe'
        if (Test-Path -LiteralPath $taskKill -PathType Leaf) {
            $processId = [int]$Process.Id
            & $taskKill /PID $processId /T /F *> $null
            [void]$Process.WaitForExit(5000)
        }
        if (-not $Process.HasExited) { $Process.Kill() }
    }
    catch {
        try { if (-not $Process.HasExited) { $Process.Kill() } }
        catch { }
    }
}

function Invoke-LauncherMsixSelfTest([string]$Launcher, [string]$ValidationRoot,
    [string]$PackagePath, [string]$Architecture, [int]$TimeoutSeconds) {
    $arguments = @(
        '--portable-root',
        $ValidationRoot,
        '--self-test-msix',
        $PackagePath,
        $Architecture
    )
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Launcher
    $info.Arguments = (($arguments | ForEach-Object {
        ConvertTo-WindowsCommandLineArgument ([string]$_)
    }) -join ' ')
    $info.WorkingDirectory = $ValidationRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw "Unable to start reference launcher: $Launcher" }
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-LauncherProcessTree $process
            throw "Reference launcher $Architecture self-test timed out after $TimeoutSeconds seconds."
        }
        if ($process.ExitCode -ne 0) {
            throw "Reference launcher $Architecture self-test failed with exit code $($process.ExitCode)."
        }
    }
    catch {
        Stop-LauncherProcessTree $process
        throw
    }
    finally { $process.Dispose() }
}

function New-ShortValidationRoot([string]$Root) {
    $parents = New-Object System.Collections.Generic.List[string]
    $driveRoot = [IO.Path]::GetPathRoot($Root)
    if (-not [string]::IsNullOrWhiteSpace($driveRoot)) { $parents.Add($driveRoot) }
    $temporaryRoot = [IO.Path]::GetTempPath()
    if (-not ($parents -contains $temporaryRoot)) { $parents.Add($temporaryRoot) }

    foreach ($parent in $parents) {
        for ([int]$attempt = 0; $attempt -lt 8; $attempt++) {
            $leaf = '.lfv-' + [guid]::NewGuid().ToString('N')
            $candidate = Join-Path $parent $leaf
            try {
                New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
                $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Launcher validation root cannot be a reparse point: $candidate"
                }
                return [IO.Path]::GetFullPath($candidate)
            }
            catch {
                if (Test-Path -LiteralPath $candidate) { continue }
                break
            }
        }
    }
    throw 'Unable to create an exclusive launcher validation root.'
}

function Invoke-OfficialLauncherSelfTests([string]$LauncherPath, [object]$X64,
    [object]$Arm64, [string]$Root, [int]$TimeoutSeconds) {
    if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
        throw 'ReferenceLauncherPath is required with RunLauncherSelfTest.'
    }
    $launcher = [IO.Path]::GetFullPath($LauncherPath)
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Reference x64 launcher is missing: $launcher"
    }
    $launcherItem = Get-Item -LiteralPath $launcher -Force -ErrorAction Stop
    if (($launcherItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reference x64 launcher cannot be a reparse point: $launcher"
    }
    $machine = Get-PeMachine $launcher
    if ($machine -ne 0x8664) {
        throw ("Reference launcher is not x64 (PE machine 0x{0:X4}): {1}" -f $machine, $launcher)
    }

    $validationRoot = New-ShortValidationRoot $Root
    try {
        Invoke-LauncherMsixSelfTest $launcher $validationRoot $X64.Path 'x64' $TimeoutSeconds
        Invoke-LauncherMsixSelfTest $launcher $validationRoot $Arm64.Path 'arm64' $TimeoutSeconds
    }
    catch {
        $selfTestError = $_
        $logRoot = Join-Path $validationRoot 'CodexData\logs'
        $diagnostic = $null
        if (Test-Path -LiteralPath $logRoot -PathType Container) {
            $log = @(Get-ChildItem -LiteralPath $logRoot -File -Filter 'launcher-*.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
            if ($log.Count -eq 1) {
                $lines = @(Get-Content -LiteralPath $log[0].FullName -Tail 24 -ErrorAction SilentlyContinue)
                $diagnostic = (($lines -join ' | ') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' ')
                if ($diagnostic.Length -gt 8192) { $diagnostic = $diagnostic.Substring(0, 8192) }
            }
        }
        if ([string]::IsNullOrWhiteSpace($diagnostic)) {
            throw $selfTestError
        }
        throw "$($selfTestError.Exception.Message) Launcher diagnostic: $diagnostic"
    }
    finally {
        if (Test-Path -LiteralPath $validationRoot -PathType Container) {
            $leaf = [IO.Path]::GetFileName($validationRoot.TrimEnd('\'))
            if ($leaf -notmatch '^\.lfv-[0-9a-f]{32}$') {
                throw "Refusing to remove an unexpected launcher validation root: $validationRoot"
            }
            Remove-Item -LiteralPath $validationRoot -Recurse -Force -ErrorAction Stop
        }
    }
}

if (-not $RunLauncherSelfTest -and -not [string]::IsNullOrWhiteSpace($ReferenceLauncherPath)) {
    throw 'ReferenceLauncherPath is only valid when RunLauncherSelfTest is requested.'
}

$repositoryRoot = Get-CanonicalDirectoryPath (Join-Path $PSScriptRoot '..\..')
if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable; pass a repository-external CacheRoot.'
    }
    $CacheRoot = Join-Path $env:LOCALAPPDATA 'LFPortable\official-codex-msix'
}
$cacheRootFull = Get-CanonicalDirectoryPath $CacheRoot
$cacheFileSystemRoot = Get-CanonicalDirectoryPath ([IO.Path]::GetPathRoot($cacheRootFull))
if ($cacheRootFull.Equals($cacheFileSystemRoot, [StringComparison]::OrdinalIgnoreCase) -or
    (Test-PathWithin $cacheRootFull $repositoryRoot) -or
    (Test-PathWithin $repositoryRoot $cacheRootFull)) {
    throw "Official MSIX cache must be outside and non-ancestral to the repository: $cacheRootFull"
}
Assert-NoReparsePointInExistingAncestry $cacheRootFull
Ensure-SafeDirectory $cacheRootFull
Assert-NoReparsePointInExistingAncestry $cacheRootFull
Remove-AbandonedDownloads $cacheRootFull

$heads = @{}
foreach ($package in $officialPackages) {
    $heads[[string]$package.Architecture] = Get-FreshOfficialHead $package
}

$x64 = Get-VerifiedOfficialPackage $officialPackages[0] $heads['x64'] $cacheRootFull
$arm64 = Get-VerifiedOfficialPackage $officialPackages[1] $heads['arm64'] $cacheRootFull
if (-not ([string]$x64.Version).Equals([string]$arm64.Version, [StringComparison]::Ordinal)) {
    throw "Official x64 and ARM64 package versions differ: x64=$($x64.Version), arm64=$($arm64.Version)."
}
Assert-SharedBundledPluginVersions $x64 $arm64
Assert-SharedOfficialTryModelContract $x64 $arm64

$selfTest = 'NotRequested'
if ($RunLauncherSelfTest) {
    Invoke-OfficialLauncherSelfTests $ReferenceLauncherPath $x64 $arm64 `
        $cacheRootFull $LauncherSelfTestTimeoutSeconds
    $selfTest = 'Passed'
}

foreach ($package in $officialPackages) {
    $architecture = [string]$package.Architecture
    $finalHead = Get-FreshOfficialHead $package
    $initialHead = $heads[$architecture]
    if ([long]$finalHead.ContentLength -ne [long]$initialHead.ContentLength -or
        -not ([string]$finalHead.ETag).Equals(
            [string]$initialHead.ETag, [StringComparison]::Ordinal)) {
        throw "Official $architecture MSIX changed during compatibility validation; rerun the build against the new package."
    }
}

[pscustomobject][ordered]@{
    Version = [string]$x64.Version
    CacheRoot = $cacheRootFull
    X64Path = [string]$x64.Path
    X64SHA256 = [string]$x64.SHA256
    X64Length = [long]$x64.Length
    X64ETag = [string]$x64.ETag
    X64PluginVersions = $x64.PluginVersions
    X64PluginVersionSummary = Get-BundledPluginVersionSummary $x64.PluginVersions `
        @(Get-RequiredBundledPlugins 'x64')
    X64TryModelContract = $x64.TryModelContract
    Arm64Path = [string]$arm64.Path
    Arm64SHA256 = [string]$arm64.SHA256
    Arm64Length = [long]$arm64.Length
    Arm64ETag = [string]$arm64.ETag
    Arm64PluginVersions = $arm64.PluginVersions
    Arm64PluginVersionSummary = Get-BundledPluginVersionSummary $arm64.PluginVersions `
        @(Get-RequiredBundledPlugins 'arm64')
    Arm64TryModelContract = $arm64.TryModelContract
    OfficialModelAnnouncement = $officialModelAnnouncement
    LauncherSelfTest = $selfTest
}
