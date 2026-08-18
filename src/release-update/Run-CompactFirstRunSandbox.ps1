[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$EvidenceRoot,

    [ValidateRange(60, 600)]
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$contract = 'LF compact first-run Sandbox'
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
$expectedPlugins = [ordered]@{
    'openai-bundled' = @('sites', 'browser', 'chrome', 'computer-use', 'latex', 'deep-research', 'visualize')
    'openai-primary-runtime' = @('documents', 'pdf', 'presentations', 'spreadsheets', 'template-creator')
}

function Write-Json([string]$Path, [object]$Value) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Path + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 14),
            (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporary, $Path, $null)
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-NullableObjectProperty([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RelativeFiles([string]$Root) {
    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction Stop |
            ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/') } |
            Sort-Object
    )
}

function Get-ManagedFileHashSnapshot([string]$Root) {
    $snapshot = [ordered]@{}
    foreach ($relative in $expectedFiles) {
        $path = Join-Path $Root $relative.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Managed Sandbox file is missing while hashing: $relative"
        }
        $snapshot[$relative] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    if ($snapshot.Count -ne 10) {
        throw 'Managed Sandbox hash snapshot does not contain exactly ten files.'
    }
    return $snapshot
}

function Get-ManagedFileManifestContract([object]$Manifest) {
    $entries = @(Get-ObjectProperty $Manifest 'Files')
    if ($entries.Count -ne $expectedFiles.Count) {
        throw 'Sandbox release manifest does not contain exactly ten managed files.'
    }
    $contract = [ordered]@{}
    foreach ($entry in $entries) {
        $relative = [string](Get-ObjectProperty $entry 'Path')
        $length = [long](Get-ObjectProperty $entry 'Length')
        $sha256 = [string](Get-ObjectProperty $entry 'Sha256')
        if ($expectedFiles -cnotcontains $relative -or $contract.Contains($relative) -or
            $length -le 0 -or $sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "Sandbox release manifest has invalid managed-file metadata: $relative"
        }
        $contract[$relative] = [pscustomobject][ordered]@{
            Length = $length
            Sha256 = $sha256.ToUpperInvariant()
        }
    }
    if ($contract.Count -ne $expectedFiles.Count -or
        -not (Test-ExactStringSet $expectedFiles @($contract.Keys))) {
        throw 'Sandbox release manifest does not match the fixed managed-file contract.'
    }
    return $contract
}

function Get-ManifestBoundManagedFileSnapshot([string]$Root,
    [Collections.IDictionary]$Contract) {
    if ($null -eq $Contract -or $Contract.Count -ne $expectedFiles.Count) {
        throw 'Sandbox managed-file manifest contract is incomplete.'
    }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($relative in $expectedFiles) {
        if (-not $Contract.Contains($relative)) {
            throw "Sandbox managed-file manifest contract is missing: $relative"
        }
        $path = Join-Path $Root $relative.Replace('/', '\\')
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (-not ($item -is [IO.FileInfo])) {
            throw "Sandbox managed file is not a regular file: $relative"
        }
        $actualLength = [long]$item.Length
        $actualSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
        $expected = $Contract[$relative]
        $lengthMatches = $actualLength -eq [long]$expected.Length
        $sha256Matches = [string]::Equals($actualSha256, [string]$expected.Sha256,
            [StringComparison]::Ordinal)
        $entries.Add([pscustomobject][ordered]@{
                Path = $relative
                Length = $actualLength
                Sha256 = $actualSha256
                ExpectedLength = [long]$expected.Length
                ExpectedSha256 = [string]$expected.Sha256
                LengthMatchesManifest = $lengthMatches
                Sha256MatchesManifest = $sha256Matches
                MatchesManifest = $lengthMatches -and $sha256Matches
            })
    }
    $mismatches = @($entries | Where-Object { -not $_.MatchesManifest } |
            Select-Object -ExpandProperty Path)
    return [pscustomobject][ordered]@{
        ExpectedFileCount = $expectedFiles.Count
        FileCount = $entries.Count
        # Windows PowerShell 5.1 can throw "Argument types do not match" when
        # an Array subexpression binds directly to a generic List[object].
        # Materialize the list explicitly so the guest validator is stable on
        # the exact PowerShell version used by Windows Sandbox.
        Files = $entries.ToArray()
        MismatchedPaths = @($mismatches)
        MatchesManifest = $entries.Count -eq $expectedFiles.Count -and $mismatches.Count -eq 0
    }
}

function Compare-ManifestBoundManagedFileSnapshots([object]$Before, [object]$After) {
    $beforeFiles = @($Before.Files)
    $afterFiles = @($After.Files)
    $differences = New-Object 'System.Collections.Generic.List[string]'
    foreach ($relative in $expectedFiles) {
        $before = @($beforeFiles | Where-Object { [string]$_.Path -ceq $relative })
        $after = @($afterFiles | Where-Object { [string]$_.Path -ceq $relative })
        if ($before.Count -ne 1 -or $after.Count -ne 1 -or
            -not [bool]$before[0].MatchesManifest -or -not [bool]$after[0].MatchesManifest -or
            [long]$before[0].Length -ne [long]$after[0].Length -or
            -not [string]::Equals([string]$before[0].Sha256, [string]$after[0].Sha256,
                [StringComparison]::Ordinal)) {
            $differences.Add($relative)
        }
    }
    return [pscustomobject][ordered]@{
        ExpectedFileCount = $expectedFiles.Count
        BeforeFileCount = $beforeFiles.Count
        AfterFileCount = $afterFiles.Count
        ChangedOrMissingFiles = @($differences)
        Unchanged = $beforeFiles.Count -eq $expectedFiles.Count -and
            $afterFiles.Count -eq $expectedFiles.Count -and $differences.Count -eq 0
    }
}

function ConvertTo-ManagedFileHashEvidence([Collections.IDictionary]$Snapshot) {
    return @(
        foreach ($relative in $expectedFiles) {
            [pscustomobject][ordered]@{
                Path = $relative
                Sha256 = [string]$Snapshot[$relative]
            }
        }
    )
}

function Compare-ManagedFileHashSnapshots([Collections.IDictionary]$Before,
    [Collections.IDictionary]$After) {
    $differences = New-Object 'System.Collections.Generic.List[string]'
    foreach ($relative in $expectedFiles) {
        if (-not $Before.Contains($relative) -or -not $After.Contains($relative) -or
            -not [string]::Equals([string]$Before[$relative], [string]$After[$relative],
                [StringComparison]::Ordinal)) {
            $differences.Add($relative)
        }
    }
    return [pscustomobject][ordered]@{
        ExpectedFileCount = 10
        BeforeFileCount = $Before.Count
        AfterFileCount = $After.Count
        ChangedOrMissingFiles = @($differences)
        Unchanged = $Before.Count -eq 10 -and $After.Count -eq 10 -and $differences.Count -eq 0
    }
}

function Test-ExactStringSet([string[]]$Expected, [string[]]$Actual) {
    return @(Compare-Object -ReferenceObject @($Expected | Sort-Object) -DifferenceObject @($Actual | Sort-Object)).Count -eq 0
}

function Get-ObjectProperty([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-DesktopFollowUpQueueMode([string]$ConfigText) {
    $values = New-Object 'System.Collections.Generic.List[string]'
    $entryCount = 0
    $inDesktop = $false
    foreach ($line in ($ConfigText -split '\r?\n')) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(?<table>[^\]]+)\]\s*(?:#.*)?$') {
            $inDesktop = $matches['table'] -ceq 'desktop'
            continue
        }
        if (-not $inDesktop) { continue }
        if ($trimmed -notmatch '^followUpQueueMode\s*=') { continue }
        $entryCount++
        $match = [regex]::Match($trimmed,
            '^followUpQueueMode\s*=\s*"(?<value>[^"\\\r\n]+)"\s*(?:#.*)?$')
        if ($match.Success) { $values.Add($match.Groups['value'].Value) }
    }
    $value = if ($values.Count -eq 1) { $values[0] } else { $null }
    return [pscustomobject]@{
        EntryCount = $entryCount
        Entries = @($values)
        Value = $value
        Valid = $entryCount -eq 1 -and $values.Count -eq 1 -and $value -ceq 'steer'
    }
}

function Get-GlobalStateOnboardingAudit([string]$StatePath) {
    $empty = [ordered]@{
        Path = $StatePath
        Exists = $false
        LocalAgentMode = $null
        SeenModelUpgradeList = @()
        DefaultModelSeen = $false
        OfficialModelSeen = $false
        LatestModelSeenPresent = $false
        LatestModelSeenIsNull = $false
        OnboardingOverride = $null
        ProjectlessCompleted = $false
        WelcomePending = $null
        AnnouncementFlagsDismissed = $false
        Valid = $false
    }
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return [pscustomobject]$empty
    }
    try {
        $state = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        $atoms = Get-ObjectProperty $state 'electron-persisted-atom-state'
        $agentModes = Get-ObjectProperty $atoms 'agent-mode-by-host-id'
        $localMode = Get-ObjectProperty $agentModes 'local'
        $seen = Get-ObjectProperty $atoms 'seen-model-upgrade-list'
        $seenModels = @($seen | Where-Object { $_ -is [string] } |
            ForEach-Object { [string]$_ })
        $latestProperty = if ($null -eq $atoms) {
            $null
        } else {
            $atoms.PSObject.Properties['latest-model-seen']
        }
        $latestValue = if ($null -eq $latestProperty) { $null } else { $latestProperty.Value }
        $announcementFlagsValid = $true
        foreach ($key in @(
                'has-seen-knowledge-work-announcement',
                'has-seen-fast-mode-announcement',
                'has-seen-work-plugins-announcement',
                'wallet-onboarding-announcement-dismissed-v1')) {
            $value = Get-ObjectProperty $atoms $key
            if (-not ($value -is [bool]) -or -not [bool]$value) {
                $announcementFlagsValid = $false
                break
            }
        }
        $defaultModelSeen = $seenModels -ccontains 'gpt-5.6-terra'
        $officialModelSeen = $seenModels -ccontains 'gpt-5.6-sol'
        $onboardingOverride = Get-ObjectProperty $atoms 'electron:onboarding-override'
        $projectlessCompleted = Get-ObjectProperty $atoms 'electron:onboarding-projectless-completed'
        $welcomePending = Get-ObjectProperty $atoms 'electron:onboarding-welcome-pending'
        $localModeValid = [string]::Equals([string]$localMode, 'custom',
            [StringComparison]::Ordinal)
        $latestModelSeenIsNull = $null -ne $latestProperty -and $null -eq $latestValue
        $valid = $localModeValid -and
            [string]::Equals([string]$onboardingOverride, 'app', [StringComparison]::Ordinal) -and
            ($projectlessCompleted -is [bool]) -and [bool]$projectlessCompleted -and
            ($welcomePending -is [bool]) -and -not [bool]$welcomePending -and
            $defaultModelSeen -and $officialModelSeen -and
            $latestModelSeenIsNull -and $announcementFlagsValid
        return [pscustomobject][ordered]@{
            Path = $StatePath
            Exists = $true
            LocalAgentMode = if ($null -eq $localMode) { $null } else { [string]$localMode }
            SeenModelUpgradeList = @($seenModels)
            DefaultModelSeen = $defaultModelSeen
            OfficialModelSeen = $officialModelSeen
            LatestModelSeenPresent = $null -ne $latestProperty
            LatestModelSeenIsNull = $latestModelSeenIsNull
            OnboardingOverride = if ($null -eq $onboardingOverride) { $null } else { [string]$onboardingOverride }
            ProjectlessCompleted = ($projectlessCompleted -is [bool]) -and [bool]$projectlessCompleted
            WelcomePending = if ($welcomePending -is [bool]) { [bool]$welcomePending } else { $null }
            AnnouncementFlagsDismissed = $announcementFlagsValid
            Valid = $valid
        }
    }
    catch {
        $empty.ParseError = $_.Exception.Message
        return [pscustomobject]$empty
    }
}

function Wait-Until([scriptblock]$Condition, [int]$Seconds, [string]$Label) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $value = & $Condition
        if ($null -ne $value -and $value -ne $false) { return $value }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Label."
}

function Get-PluginAudit([string]$CommonArchivePath, [string]$X64MsixPath) {
    $found = @{}
    $versions = @{}
    $unexpected = New-Object 'System.Collections.Generic.List[string]'
    $pluginCacheEntries = New-Object 'System.Collections.Generic.List[string]'
    $fsharpSdkEntries = New-Object 'System.Collections.Generic.List[string]'
    $csharpSdkVersions = @{}
    $visualBasicSdkVersions = @{}

    function Add-PluginSourceManifest([IO.Compression.ZipArchiveEntry]$Entry, [string]$Catalog,
        [string]$Plugin, [string]$SourceLabel) {
        if ($Entry.Length -le 0 -or $Entry.Length -gt 1048576) {
            throw "$SourceLabel plugin manifest has an unsafe size: $($Entry.FullName)"
        }
        if (-not $expectedPlugins.Contains($Catalog) -or $expectedPlugins[$Catalog] -cnotcontains $Plugin) {
            $unexpected.Add("$Catalog/$Plugin")
            return
        }
        $stream = $Entry.Open()
        try {
            $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false, $true)), $false)
            try { $metadata = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
        $version = [string]$metadata.version
        if ([string]$metadata.name -cne $Plugin -or [string]::IsNullOrWhiteSpace($version) -or
            $version.Equals('latest', [StringComparison]::OrdinalIgnoreCase) -or
            $version -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') {
            throw "$SourceLabel plugin manifest is unsafe or inconsistent: $($Entry.FullName)"
        }
        $key = "$Catalog/$Plugin"
        if ($found.Contains($key)) { throw "Duplicate required plugin source manifest: $key" }
        $found[$key] = $true
        $versions[$key] = @($version)
    }

    $archive = [IO.Compression.ZipFile]::OpenRead($CommonArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $entryPath = $entry.FullName.Replace('\', '/')
            if ($entryPath.Equals('data/profile/.codex/plugins/cache', [StringComparison]::OrdinalIgnoreCase) -or
                $entryPath.StartsWith('data/profile/.codex/plugins/cache/', [StringComparison]::OrdinalIgnoreCase)) {
                $pluginCacheEntries.Add($entryPath)
            }
            if ($entryPath -match '^tools/dotnet/sdk/[^/]+/FSharp(?:/|$)') {
                $fsharpSdkEntries.Add($entryPath)
            }
            if ($entryPath -match '^tools/dotnet/sdk/(?<version>[^/]+)/Roslyn/bincore/csc\.dll$') {
                $csharpSdkVersions[$matches['version']] = $true
            }
            if ($entryPath -match '^tools/dotnet/sdk/(?<version>[^/]+)/Roslyn/bincore/vbc\.dll$') {
                $visualBasicSdkVersions[$matches['version']] = $true
            }
            $match = [regex]::Match($entryPath,
                '^data/profile/\.codex/offline-marketplaces/openai-primary-runtime/plugins/([^/]+)/\.codex-plugin/plugin\.json$')
            if (-not $match.Success) { continue }
            Add-PluginSourceManifest $entry 'openai-primary-runtime' $match.Groups[1].Value 'Offline marketplace'
        }
    }
    finally { $archive.Dispose() }

    $archive = [IO.Compression.ZipFile]::OpenRead($X64MsixPath)
    try {
        foreach ($entry in $archive.Entries) {
            $match = [regex]::Match($entry.FullName,
                '^app/resources/plugins/openai-bundled/plugins/([^/]+)/\.codex-plugin/plugin\.json$')
            if (-not $match.Success) { continue }
            Add-PluginSourceManifest $entry 'openai-bundled' $match.Groups[1].Value 'Signed x64 MSIX'
        }
    }
    finally { $archive.Dispose() }

    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($catalog in $expectedPlugins.Keys) {
        foreach ($plugin in $expectedPlugins[$catalog]) {
            $key = "$catalog/$plugin"
            if (-not $found.Contains($key)) { $missing.Add($key) }
        }
    }
    $compilerSdkVersions = @($csharpSdkVersions.Keys | Where-Object {
            $visualBasicSdkVersions.ContainsKey($_)
        } | Sort-Object)
    $result = [ordered]@{
        ExpectedPluginCount = 12
        FoundPluginCount = $found.Count
        MissingPlugins = @($missing | Sort-Object)
        UnexpectedPlugins = @($unexpected | Sort-Object -Unique)
        PluginCacheEntryCount = $pluginCacheEntries.Count
        PluginCacheOmitted = $pluginCacheEntries.Count -eq 0
        FSharpSdkEntryCount = $fsharpSdkEntries.Count
        FSharpSdkOmitted = $fsharpSdkEntries.Count -eq 0
        CompilerSdkVersions = $compilerSdkVersions
        CSharpVisualBasicSdkRetained = $compilerSdkVersions.Count -gt 0
        Versions = [ordered]@{}
        Valid = $found.Count -eq 12 -and $missing.Count -eq 0 -and $unexpected.Count -eq 0 -and
            $pluginCacheEntries.Count -eq 0 -and $fsharpSdkEntries.Count -eq 0 -and
            $compilerSdkVersions.Count -gt 0
    }
    foreach ($key in @($versions.Keys | Sort-Object)) {
        $result.Versions[$key] = @($versions[$key] | Sort-Object)
    }
    return [pscustomobject]$result
}

function Copy-CompactRelease([string]$From, [string]$To, [object]$Manifest) {
    if (Test-Path -LiteralPath $To) { throw "Manual-start target must not exist: $To" }
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    & robocopy.exe $From $To /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /MT:16 /XJ /NFL /NDL /NP /NJH /NJS | Out-Null
    $exitCode = [int]$LASTEXITCODE
    if ($exitCode -ge 8) { throw "Manual-start compact release copy failed with robocopy exit code $exitCode." }
    $actual = Get-RelativeFiles $To
    if (-not (Test-ExactStringSet $expectedFiles $actual)) {
        throw 'Manual-start copy does not contain exactly the compact release files.'
    }
    $contract = Get-ManagedFileManifestContract $Manifest
    $snapshot = Get-ManifestBoundManagedFileSnapshot $To $contract
    if (-not $snapshot.MatchesManifest) {
        throw 'Manual-start copy does not match every managed-file manifest length and SHA-256.'
    }
    return [pscustomobject][ordered]@{
        RobocopyExitCode = $exitCode
        ManagedFiles = $snapshot
    }
}

function Test-PathAtOrBelow([string]$Candidate, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    $boundary = $Root.TrimEnd('\')
    return $Candidate.Equals($boundary, [StringComparison]::OrdinalIgnoreCase) -or
        $Candidate.StartsWith($boundary + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Initialize-ExecutionVolumeInterop {
    if ($null -ne ('LFPortable.ExecutionVolumeNative' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace LFPortable
{
    public static class ExecutionVolumeNative
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetVolumeInformation(
            string rootPathName,
            StringBuilder volumeNameBuffer,
            uint volumeNameSize,
            out uint volumeSerialNumber,
            out uint maximumComponentLength,
            out uint fileSystemFlags,
            StringBuilder fileSystemNameBuffer,
            uint fileSystemNameSize);
    }
}
'@
}

function Get-ExecutionVolumeToken([string]$Root) {
    $fullRoot = [IO.Path]::GetFullPath($Root)
    $volumeRoot = [IO.Path]::GetPathRoot($fullRoot)
    [uint32]$serial = 0
    [uint32]$maximumComponentLength = 0
    [uint32]$flags = 0
    try {
        Initialize-ExecutionVolumeInterop
        if (-not [string]::IsNullOrWhiteSpace($volumeRoot) -and
            [LFPortable.ExecutionVolumeNative]::GetVolumeInformation($volumeRoot, $null, [uint32]0,
                [ref]$serial, [ref]$maximumComponentLength, [ref]$flags, $null, [uint32]0)) {
            return 'vol-' + $serial.ToString('X8', [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    catch { }

    $input = [Text.Encoding]::UTF8.GetBytes($fullRoot.TrimEnd('\').ToUpperInvariant())
    $digest = $null
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($input) }
        finally { $sha.Dispose() }
        return 'path-' + (-join @($digest[0..7] | ForEach-Object { $_.ToString('x2') }))
    }
    finally {
        [Array]::Clear($input, 0, $input.Length)
        if ($null -ne $digest) { [Array]::Clear($digest, 0, $digest.Length) }
    }
}

function Get-ExecutionFamilyRoot([string]$Root) {
    try {
        $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($local) -or -not [IO.Path]::IsPathRooted($local)) { return $null }
        return [IO.Path]::GetFullPath((Join-Path $local ('LFPortable\execution\' +
                    (Get-ExecutionVolumeToken $Root)))).TrimEnd('\')
    }
    catch { return $null }
}

function Test-ExecutionDesktopProcessPath([string]$Path, [string]$ExecutionFamilyRoot) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($ExecutionFamilyRoot)) {
        return $false
    }
    try {
        if (-not [string]::Equals([IO.Path]::GetFileName($Path), 'CodexDesktop.exe',
                [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $full = [IO.Path]::GetFullPath($Path)
        $family = [IO.Path]::GetFullPath($ExecutionFamilyRoot).TrimEnd('\')
        $prefix = $family + '\'
        if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $segments = @($full.Substring($prefix.Length).Split([char[]]@('\'), [StringSplitOptions]::None))
        if ($segments.Count -ne 5 -or
            $segments[0] -notin @('x64', 'arm64') -or
            -not [string]::Equals($segments[2], 'app', [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($segments[3], 'current', [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($segments[4], 'CodexDesktop.exe', [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $match = [regex]::Match($segments[1],
            '^desktop-lf-(?<launcher>[^-]+)-pkg-c-(?<common>[0-9a-f]{16})-d-(?<desktop>[0-9a-f]{16})$',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) { return $false }
        $launcherVersion = $null
        return [Version]::TryParse($match.Groups['launcher'].Value, [ref]$launcherVersion) -and
            [string]::Equals($match.Groups['launcher'].Value, $launcherVersion.ToString(), [StringComparison]::Ordinal)
    }
    catch { return $false }
}

function Get-ExecutionImageExpectation([string]$Root, [object]$Manifest) {
    $artifacts = Get-ObjectProperty $Manifest 'PackageArtifacts'
    $common = Get-ObjectProperty $artifacts 'Common'
    $launcherVersion = [string](Get-ObjectProperty $Manifest 'LauncherVersion')
    $commonSha256 = [string](Get-ObjectProperty $common 'Sha256')
    $desktopSha256 = [string](Get-ObjectProperty (Get-ObjectProperty $artifacts 'X64') 'Sha256')
    if ($launcherVersion -notmatch '^\d+\.\d+\.\d+\.\d+$' -or
        $commonSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
        $desktopSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'Sandbox release manifest cannot establish the x64 execution-image identity.'
    }
    $familyRoot = Get-ExecutionFamilyRoot $Root
    if ([string]::IsNullOrWhiteSpace($familyRoot)) {
        throw 'Sandbox cannot establish the local execution-image family root.'
    }
    $directoryName = 'desktop-lf-' + $launcherVersion + '-pkg-c-' +
        $commonSha256.Substring(0, 16).ToLowerInvariant() + '-d-' +
        $desktopSha256.Substring(0, 16).ToLowerInvariant()
    $architectureRoot = Join-Path $familyRoot 'x64'
    $versionRoot = Join-Path $architectureRoot $directoryName
    [pscustomobject][ordered]@{
        Architecture = 'x64'
        FamilyRoot = $familyRoot
        ArchitectureRoot = $architectureRoot
        DirectoryName = $directoryName
        VersionRoot = $versionRoot
        ExecutablePath = Join-Path $versionRoot 'app\current\CodexDesktop.exe'
        RequiredRelativeFiles = @(
            'app\current\ChatGPT.exe'
            'app\current\CodexDesktop.exe'
            'app\current\resources\app.asar'
            'runtime\dependencies\node\bin\node.exe'
            'runtime\dependencies\python\python.exe'
            'runtime\dependencies\native\git\cmd\git.exe'
            'tools\dotnet\dotnet.exe'
        )
        CommonPackageSha256 = $commonSha256.ToUpperInvariant()
        DesktopPackageSha256 = $desktopSha256.ToUpperInvariant()
    }
}

function Get-ExecutionImageAudit([object]$Expected) {
    $versionRootExists = Test-Path -LiteralPath $Expected.VersionRoot -PathType Container
    $missing = New-Object 'System.Collections.Generic.List[string]'
    if ($versionRootExists) {
        foreach ($relative in @($Expected.RequiredRelativeFiles)) {
            if (-not (Test-Path -LiteralPath (Join-Path $Expected.VersionRoot $relative) -PathType Leaf)) {
                $missing.Add($relative)
            }
        }
    }
    else {
        foreach ($relative in @($Expected.RequiredRelativeFiles)) { $missing.Add($relative) }
    }

    $residues = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $Expected.ArchitectureRoot -PathType Container) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $Expected.ArchitectureRoot -Directory -Force -ErrorAction Stop)) {
            if ($entry.Name -like '.stage-*' -or $entry.Name -like '.backup-*' -or
                $entry.Name -like '.invalid-*') {
                $residues.Add($entry.Name)
            }
        }
    }
    $directoryNameMatchesExpected = $versionRootExists -and
        [string]::Equals((Get-Item -LiteralPath $Expected.VersionRoot -Force -ErrorAction Stop).Name,
            $Expected.DirectoryName, [StringComparison]::Ordinal)
    $executableExists = Test-Path -LiteralPath $Expected.ExecutablePath -PathType Leaf
    $portableProfileDataPresent = Test-Path -LiteralPath (Join-Path $Expected.VersionRoot 'data') -PathType Container
    $desktopPackageStagingPresent = Test-Path -LiteralPath (Join-Path $Expected.VersionRoot '.desktop-package') -PathType Container
    $archiveDerivedShapeValid = -not $portableProfileDataPresent -and -not $desktopPackageStagingPresent
    $valid = $versionRootExists -and $directoryNameMatchesExpected -and $executableExists -and
        $missing.Count -eq 0 -and $residues.Count -eq 0 -and $archiveDerivedShapeValid
    [pscustomobject][ordered]@{
        FamilyRoot = $Expected.FamilyRoot
        ArchitectureRoot = $Expected.ArchitectureRoot
        ExpectedDirectoryName = $Expected.DirectoryName
        VersionRoot = $Expected.VersionRoot
        VersionRootExists = $versionRootExists
        DirectoryNameMatchesExpected = $directoryNameMatchesExpected
        ExecutablePath = $Expected.ExecutablePath
        ExecutableExists = $executableExists
        RequiredFilesMissing = @($missing)
        TransactionResidues = @($residues | Sort-Object)
        NoTransactionResidues = $residues.Count -eq 0
        PortableProfileDataPresent = $portableProfileDataPresent
        DesktopPackageStagingPresent = $desktopPackageStagingPresent
        ArchiveDerivedShapeValid = $archiveDerivedShapeValid
        Valid = $valid
    }
}

function Initialize-SandboxProcessTerminator {
    if ($null -ne ('LfSandboxProcessTerminator' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class LfSandboxProcessTerminator
{
    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME
    {
        public uint LowDateTime;
        public uint HighDateTime;
    }

    private const uint PROCESS_TERMINATE = 0x0001;
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint SYNCHRONIZE = 0x00100000;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_TIMEOUT = 0x00000102;
    private const uint WAIT_FAILED = 0xFFFFFFFF;
    private const uint STILL_ACTIVE = 259;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(IntPtr processHandle, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(IntPtr processHandle, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetProcessId(IntPtr processHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetProcessTimes(IntPtr processHandle, out FILETIME creationTime,
        out FILETIME exitTime, out FILETIME kernelTime, out FILETIME userTime);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageName(IntPtr processHandle, uint flags,
        StringBuilder executablePath, ref uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    public static IntPtr CaptureForExitEvidence(int processId)
    {
        if (processId <= 0) throw new ArgumentOutOfRangeException("processId");
        IntPtr handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
            false, unchecked((uint)processId));
        if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),
            "Unable to capture a native Sandbox process handle for exit-code evidence.");
        return handle;
    }

    public static IntPtr CaptureForTermination(int processId)
    {
        if (processId <= 0) throw new ArgumentOutOfRangeException("processId");
        IntPtr handle = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
            false, unchecked((uint)processId));
        if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),
            "Unable to open the Sandbox Codex process for the recovery fault injection.");
        return handle;
    }

    public static void TerminateWithExitCode(IntPtr processHandle, uint exitCode)
    {
        if (processHandle == IntPtr.Zero) throw new ArgumentException("A native process handle is required.",
            "processHandle");
        if (!TerminateProcess(processHandle, exitCode)) throw new Win32Exception(Marshal.GetLastWin32Error(),
            "Unable to inject the requested Sandbox Codex exit code.");
    }

    public static bool WaitForExit(IntPtr processHandle, int milliseconds)
    {
        if (processHandle == IntPtr.Zero) throw new ArgumentException("A native process handle is required.",
            "processHandle");
        if (milliseconds < 0) throw new ArgumentOutOfRangeException("milliseconds");
        uint result = WaitForSingleObject(processHandle, unchecked((uint)milliseconds));
        if (result == WAIT_OBJECT_0) return true;
        if (result == WAIT_TIMEOUT) return false;
        if (result == WAIT_FAILED) throw new Win32Exception(Marshal.GetLastWin32Error(),
            "Unable to wait for the Sandbox process exit.");
        throw new InvalidOperationException("WaitForSingleObject returned an unexpected result.");
    }

    public static uint GetExitCode(IntPtr processHandle)
    {
        if (processHandle == IntPtr.Zero) throw new ArgumentException("A native process handle is required.",
            "processHandle");
        uint exitCode;
        if (!GetExitCodeProcess(processHandle, out exitCode)) throw new Win32Exception(Marshal.GetLastWin32Error(),
            "Unable to read the native Sandbox process exit code.");
        return exitCode;
    }

    public static uint GetCapturedProcessId(IntPtr processHandle)
    {
        if (processHandle == IntPtr.Zero) throw new ArgumentException("A native process handle is required.",
            "processHandle");
        uint processId = GetProcessId(processHandle);
        if (processId == 0) throw new Win32Exception(Marshal.GetLastWin32Error(),
            "Unable to identify the captured Sandbox process handle.");
        return processId;
    }

    public static string GetCapturedImagePath(IntPtr processHandle)
    {
        if (processHandle == IntPtr.Zero) throw new ArgumentException("A native process handle is required.",
            "processHandle");
        StringBuilder path = new StringBuilder(32768);
        uint size = unchecked((uint)path.Capacity);
        if (!QueryFullProcessImageName(processHandle, 0, path, ref size))
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Unable to read the captured Sandbox process image path.");
        return path.ToString();
    }

    public static string GetCapturedCreationTimeUtc(IntPtr processHandle)
    {
        if (processHandle == IntPtr.Zero) throw new ArgumentException("A native process handle is required.",
            "processHandle");
        FILETIME creationTime;
        FILETIME exitTime;
        FILETIME kernelTime;
        FILETIME userTime;
        if (!GetProcessTimes(processHandle, out creationTime, out exitTime, out kernelTime, out userTime))
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Unable to read the captured Sandbox process creation time.");
        long fileTime = unchecked((long)(((ulong)creationTime.HighDateTime << 32) |
            creationTime.LowDateTime));
        return DateTime.FromFileTimeUtc(fileTime).ToString("o");
    }

    public static bool CloseProcessHandle(IntPtr processHandle)
    {
        if (processHandle == IntPtr.Zero) return true;
        return CloseHandle(processHandle);
    }
}
'@
}

function Close-SandboxNativeProcessHandle([object]$Handle) {
    if ($null -eq $Handle) { return }
    try { $nativeHandle = [IntPtr]$Handle } catch { return }
    if ($nativeHandle -eq [IntPtr]::Zero) { return }
    try { [void][LfSandboxProcessTerminator]::CloseProcessHandle($nativeHandle) } catch { }
}

function ConvertTo-UnsignedExitCode([int]$ExitCode) {
    return [BitConverter]::ToUInt32([BitConverter]::GetBytes($ExitCode), 0)
}

function Initialize-MandatoryProcessStartTrace {
    if ($null -ne ('LfSandboxProcessStartTrace' -as [type])) { return }
    Add-Type -AssemblyName System.Management
    $traceReferences = if ($PSVersionTable.PSEdition -ceq 'Core') {
        @(
            [System.Management.ManagementEventWatcher].Assembly.Location
            [System.ComponentModel.Component].Assembly.Location
        )
    }
    else { @('System.Management', 'System') }
    Add-Type -ReferencedAssemblies $traceReferences -TypeDefinition @'
using System;
using System.Globalization;
using System.Management;
using System.Runtime.CompilerServices;

public sealed class LfSandboxProcessStartTraceRecord
{
    public int EventOrdinal { get; private set; }
    public string ProviderTimeCreated { get; private set; }
    public string ReceivedUtc { get; private set; }
    public string ProcessName { get; private set; }
    public int ProcessId { get; private set; }
    public int ParentProcessId { get; private set; }
    public int SessionId { get; private set; }

    public LfSandboxProcessStartTraceRecord(int eventOrdinal, string providerTimeCreated,
        string receivedUtc, string processName, int processId, int parentProcessId,
        int sessionId)
    {
        EventOrdinal = eventOrdinal;
        ProviderTimeCreated = providerTimeCreated;
        ReceivedUtc = receivedUtc;
        ProcessName = processName;
        ProcessId = processId;
        ParentProcessId = parentProcessId;
        SessionId = sessionId;
    }
}

public sealed class LfSandboxProcessStartTrace : IDisposable
{
    private const int MaximumEvents = 32768;
    private readonly LfSandboxProcessStartTraceRecord[] records =
        new LfSandboxProcessStartTraceRecord[MaximumEvents];
    private ManagementEventWatcher watcher;
    private Exception failure;
    private int recordCount;
    private int nextOrdinal;
    private volatile bool started;
    private volatile bool disposing;

    public string QueryText
    {
        get { return "SELECT * FROM Win32_ProcessStartTrace"; }
    }

    [MethodImpl(MethodImplOptions.Synchronized)]
    public void Start()
    {
        if (started) throw new InvalidOperationException("The process-start trace is already active.");
        watcher = new ManagementEventWatcher(new WqlEventQuery(QueryText));
        watcher.EventArrived += OnEventArrived;
        watcher.Stopped += OnStopped;
        try
        {
            watcher.Start();
            started = true;
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    [MethodImpl(MethodImplOptions.Synchronized)]
    public void EnsureHealthy()
    {
        if (!started || watcher == null)
            throw new InvalidOperationException("The Win32_ProcessStartTrace watcher is not active.");
        if (failure != null)
            throw new InvalidOperationException("The Win32_ProcessStartTrace watcher failed.", failure);
    }

    [MethodImpl(MethodImplOptions.Synchronized)]
    public LfSandboxProcessStartTraceRecord[] Snapshot()
    {
        EnsureHealthy();
        int count = recordCount;
        if (count < 0 || count >= MaximumEvents)
            throw new InvalidOperationException(
                "The Win32_ProcessStartTrace event buffer reached its fixed limit and may be truncated.");
        LfSandboxProcessStartTraceRecord[] snapshot =
            new LfSandboxProcessStartTraceRecord[count];
        Array.Copy(records, snapshot, count);
        for (int i = 0; i < snapshot.Length; i++)
            if (snapshot[i] == null)
                throw new InvalidOperationException("The Win32_ProcessStartTrace event buffer is incomplete.");
        return snapshot;
    }

    [MethodImpl(MethodImplOptions.Synchronized)]
    private void OnEventArrived(object sender, EventArrivedEventArgs e)
    {
        try
        {
            ManagementBaseObject value = e.NewEvent;
            string processName = Convert.ToString(value["ProcessName"],
                CultureInfo.InvariantCulture) ?? string.Empty;
            int processId = unchecked((int)Convert.ToUInt32(value["ProcessID"],
                CultureInfo.InvariantCulture));
            int parentProcessId = unchecked((int)Convert.ToUInt32(value["ParentProcessID"],
                CultureInfo.InvariantCulture));
            int sessionId = value["SessionID"] == null ? -1 :
                unchecked((int)Convert.ToUInt32(value["SessionID"], CultureInfo.InvariantCulture));
            string providerTime = Convert.ToString(value["TIME_CREATED"],
                CultureInfo.InvariantCulture) ?? string.Empty;
            if (disposing) return;
            int slot = recordCount;
            if (slot >= MaximumEvents)
            {
                failure = new InvalidOperationException(
                    "The Win32_ProcessStartTrace event buffer exceeded its fixed limit.");
                return;
            }
            nextOrdinal++;
            records[slot] = new LfSandboxProcessStartTraceRecord(nextOrdinal, providerTime,
                DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture), processName,
                processId, parentProcessId, sessionId);
            recordCount = slot + 1;
        }
        catch (Exception ex)
        {
            if (failure == null) failure = ex;
        }
    }

    [MethodImpl(MethodImplOptions.Synchronized)]
    private void OnStopped(object sender, StoppedEventArgs e)
    {
        if (!disposing && failure == null)
            failure = new InvalidOperationException(
                "The Win32_ProcessStartTrace watcher stopped unexpectedly: " + e.Status.ToString());
    }

    public void Dispose()
    {
        if (disposing) return;
        disposing = true;
        ManagementEventWatcher current = watcher;
        if (current != null)
        {
            try { current.Stop(); } catch { }
            current.EventArrived -= OnEventArrived;
            current.Stopped -= OnStopped;
            current.Dispose();
        }
        watcher = null;
        started = false;
    }
}
'@
}

function Start-MandatoryProcessStartTrace {
    Initialize-MandatoryProcessStartTrace
    $trace = New-Object LfSandboxProcessStartTrace
    try {
        $trace.Start()
        $trace.EnsureHealthy()
        return $trace
    }
    catch {
        try { $trace.Dispose() } catch { }
        throw 'Windows Sandbox cannot establish the mandatory Win32_ProcessStartTrace ManagementEventWatcher.'
    }
}

function Get-MandatoryProcessStartTraceSnapshot([object]$Trace) {
    if ($null -eq $Trace) { throw 'The mandatory process-start trace is unavailable.' }
    $Trace.EnsureHealthy()
    return @($Trace.Snapshot() | Sort-Object EventOrdinal)
}

function Get-MandatoryProcessStartTraceCursor([object]$Trace) {
    $records = @(Get-MandatoryProcessStartTraceSnapshot $Trace)
    if ($records.Count -eq 0) { return 0 }
    return [int]($records | Select-Object -Last 1).EventOrdinal
}

function Wait-ForMandatoryProcessStartTraceRecord([object]$Trace, [int]$ProcessId,
    [int]$ParentProcessId, [int]$SessionId, [string]$ProcessName, [int]$MinimumOrdinal,
    [int]$Seconds, [string]$Label) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $matches = @(
            Get-MandatoryProcessStartTraceSnapshot $Trace | Where-Object {
                [int]$_.EventOrdinal -gt $MinimumOrdinal -and
                    [int]$_.ProcessId -eq $ProcessId -and
                    [int]$_.ParentProcessId -eq $ParentProcessId -and
                    [int]$_.SessionId -eq $SessionId -and
                    [string]::Equals([string]$_.ProcessName, $ProcessName,
                        [StringComparison]::OrdinalIgnoreCase)
            }
        )
        if ($matches.Count -gt 1) { throw "Process-start trace duplicated $Label." }
        if ($matches.Count -eq 1) { return $matches[0] }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for Win32_ProcessStartTrace evidence for $Label."
}

function Invoke-MandatoryProcessStartTraceProbe([object]$Trace, [int]$SessionId,
    [string]$Label) {
    $commandProcessor = [Environment]::GetEnvironmentVariable('ComSpec')
    if ([string]::IsNullOrWhiteSpace($commandProcessor) -or
        -not [IO.Path]::IsPathRooted($commandProcessor) -or
        -not (Test-Path -LiteralPath $commandProcessor -PathType Leaf)) {
        throw 'Windows Sandbox cannot locate the process-start trace readiness probe executable.'
    }
    $cursor = Get-MandatoryProcessStartTraceCursor $Trace
    $probe = Start-Process -FilePath $commandProcessor -ArgumentList @('/d', '/c', 'exit 0') `
        -PassThru -WindowStyle Hidden
    try {
        $record = Wait-ForMandatoryProcessStartTraceRecord $Trace $probe.Id $PID $SessionId `
            ([IO.Path]::GetFileName($commandProcessor)) $cursor 15 $Label
        $probe.WaitForExit()
        if ($probe.ExitCode -ne 0) { throw "The process-start trace $Label probe failed." }
        return [pscustomobject][ordered]@{
            ProcessId = $probe.Id
            ParentProcessId = $PID
            ProcessName = [IO.Path]::GetFileName($commandProcessor)
            ExitCode = $probe.ExitCode
            TraceEventOrdinal = [int]$record.EventOrdinal
            TraceBound = $true
        }
    }
    finally { $probe.Dispose() }
}

function Wait-ForMandatoryProcessStartTraceQuiescence([object]$Trace,
    [int]$QuietMilliseconds, [int]$TimeoutSeconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastCursor = Get-MandatoryProcessStartTraceCursor $Trace
    $quiet = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 100
        $cursor = Get-MandatoryProcessStartTraceCursor $Trace
        if ($cursor -ne $lastCursor) {
            $lastCursor = $cursor
            $quiet.Restart()
        }
        if ($quiet.ElapsedMilliseconds -ge $QuietMilliseconds) { return $lastCursor }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The mandatory process-start trace did not reach a quiescent checkpoint.'
}

function ConvertTo-ProcessStartTraceEvidence([object]$Record) {
    if ($null -eq $Record) { return $null }
    return [pscustomobject][ordered]@{
        EventOrdinal = [int]$Record.EventOrdinal
        ProviderTimeCreated = [string]$Record.ProviderTimeCreated
        ReceivedUtc = [string]$Record.ReceivedUtc
        ProcessName = [string]$Record.ProcessName
        ProcessId = [int]$Record.ProcessId
        ParentProcessId = [int]$Record.ParentProcessId
        SessionId = [int]$Record.SessionId
    }
}

function Get-ExecutionDesktopRootProcesses([string]$Root, [int]$LauncherProcessId) {
    $familyRoot = Get-ExecutionFamilyRoot $Root
    if ([string]::IsNullOrWhiteSpace($familyRoot)) { return @() }
    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            [int]$_.ParentProcessId -eq $LauncherProcessId -and
                (Test-ExecutionDesktopProcessPath ([string]$_.ExecutablePath) $familyRoot)
        })
    }
    catch {
        throw 'Sandbox cannot enumerate direct CodexDesktop.exe processes for the self-repair proof.'
    }
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in $processes) {
        try {
            $process = Get-Process -Id ([int]$candidate.ProcessId) -ErrorAction Stop
            $process.Refresh()
            if ($process.HasExited) { continue }
            $processStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
            $result.Add([pscustomobject][ordered]@{
                    Process = $process
                    ProcessId = [int]$candidate.ProcessId
                    ParentProcessId = [int]$candidate.ParentProcessId
                    ExecutablePath = [string]$candidate.ExecutablePath
                    ProcessStartUtc = $processStartUtc
                    FirstObservedUtc = [DateTime]::UtcNow.ToString('o')
                })
        }
        catch { }
    }
    return @($result.ToArray())
}

function Get-ExecutionDesktopProcessRecords([string]$Root) {
    $familyRoot = Get-ExecutionFamilyRoot $Root
    if ([string]::IsNullOrWhiteSpace($familyRoot)) { return @() }
    try {
        return @(
            Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                Test-ExecutionDesktopProcessPath ([string]$_.ExecutablePath) $familyRoot
            } | ForEach-Object {
                [pscustomobject][ordered]@{
                    ProcessId = [int]$_.ProcessId
                    ParentProcessId = [int]$_.ParentProcessId
                    ExecutablePath = [string]$_.ExecutablePath
                }
            }
        )
    }
    catch {
        throw 'Sandbox cannot enumerate local execution-image desktop processes for post-handoff recovery.'
    }
}

function Get-ExecutionDesktopAttemptKey([int]$ProcessId, [string]$ProcessStartUtc) {
    if ($ProcessId -le 0 -or [string]::IsNullOrWhiteSpace($ProcessStartUtc)) {
        throw 'Sandbox execution-image root process identity is incomplete.'
    }
    return ([string]$ProcessId + '|' + $ProcessStartUtc)
}

function Add-ExecutionDesktopAttemptObservations([hashtable]$Attempts, [object[]]$Candidates) {
    foreach ($candidate in @($Candidates)) {
        $key = Get-ExecutionDesktopAttemptKey ([int]$candidate.ProcessId) `
            ([string]$candidate.ProcessStartUtc)
        if ($Attempts.ContainsKey($key)) { continue }
        $Attempts[$key] = [pscustomobject][ordered]@{
            ObservationOrdinal = $Attempts.Count + 1
            ProcessId = [int]$candidate.ProcessId
            ParentProcessId = [int]$candidate.ParentProcessId
            ExecutablePath = [string]$candidate.ExecutablePath
            ProcessStartUtc = [string]$candidate.ProcessStartUtc
            FirstObservedUtc = [string]$candidate.FirstObservedUtc
        }
    }
}

function ConvertTo-ExecutionAttemptEvidence([object]$Attempt, [object]$Expected,
    [object]$TraceRecord) {
    if ($null -eq $Attempt) { return $null }
    [pscustomobject][ordered]@{
        ProcessId = [int]$Attempt.ProcessId
        ParentProcessId = [int]$Attempt.ParentProcessId
        ExecutablePath = [string]$Attempt.ExecutablePath
        ProcessStartUtc = [string]$Attempt.ProcessStartUtc
        AttemptKey = Get-ExecutionDesktopAttemptKey ([int]$Attempt.ProcessId) `
            ([string]$Attempt.ProcessStartUtc)
        IsExecutionImagePath = Test-ExecutionDesktopProcessPath $Attempt.ExecutablePath $Expected.FamilyRoot
        MatchesExpectedExecutionPath = [string]::Equals([string]$Attempt.ExecutablePath,
            [string]$Expected.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)
        FirstObservedUtc = [string]$Attempt.FirstObservedUtc
        TraceBound = $null -ne $TraceRecord
        TraceEventOrdinal = if ($null -eq $TraceRecord) { $null } else { [int]$TraceRecord.EventOrdinal }
        TraceReceivedUtc = if ($null -eq $TraceRecord) { $null } else { [string]$TraceRecord.ReceivedUtc }
    }
}

function Assert-NoUnexpectedDesktopExecutablePath([string]$Root, [object]$Expected) {
    $unexpected = @(
        Get-TargetDesktopProcesses $Root | Where-Object {
            try {
                [string]::Equals([IO.Path]::GetFileName($_.Path), 'CodexDesktop.exe',
                    [StringComparison]::OrdinalIgnoreCase) -and
                    -not [string]::Equals([IO.Path]::GetFullPath($_.Path),
                        [IO.Path]::GetFullPath($Expected.ExecutablePath),
                        [StringComparison]::OrdinalIgnoreCase)
            }
            catch { $false }
        }
    )
    if ($unexpected.Count -ne 0) {
        throw 'Observed CodexDesktop.exe outside the expected local execution image.'
    }
}

function Wait-ForExecutionDesktopRoot([string]$Root, [object]$Expected, [int]$LauncherProcessId,
    [int]$ExcludeProcessId, [string]$ExcludeProcessStartUtc, [int]$Seconds, [string]$Label, [Diagnostics.Process]$Launcher,
    [Collections.IDictionary]$ProgressAudit, [Collections.IDictionary]$RecoveryProgressAudit,
    [hashtable]$Attempts) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if ($null -ne $ProgressAudit) { Add-LauncherProgressSample $Launcher $ProgressAudit }
        if ($null -ne $RecoveryProgressAudit) { Add-LauncherProgressSample $Launcher $RecoveryProgressAudit }
        Assert-NoUnexpectedDesktopExecutablePath $Root $Expected
        $candidates = @(Get-ExecutionDesktopRootProcesses $Root $LauncherProcessId)
        Add-ExecutionDesktopAttemptObservations $Attempts $candidates
        $wrongVersion = @($candidates | Where-Object {
                -not [string]::Equals([string]$_.ExecutablePath, [string]$Expected.ExecutablePath,
                    [StringComparison]::OrdinalIgnoreCase)
            })
        if ($wrongVersion.Count -ne 0) {
            throw 'Observed a Codex Desktop root process from an unexpected local execution-image version.'
        }
        $matches = @($candidates | Where-Object {
                -not ([int]$_.ProcessId -eq $ExcludeProcessId -and
                    -not [string]::IsNullOrWhiteSpace($ExcludeProcessStartUtc) -and
                    [string]::Equals([string]$_.ProcessStartUtc, $ExcludeProcessStartUtc,
                        [StringComparison]::Ordinal))
            })
        if ($matches.Count -gt 1) { throw "Observed multiple root processes while waiting for $Label." }
        if ($matches.Count -eq 1) {
            Initialize-SandboxProcessTerminator
            $capturedHandle = [IntPtr]::Zero
            $handleTransferred = $false
            try {
                $capturedHandle = [LfSandboxProcessTerminator]::CaptureForTermination(
                    $matches[0].ProcessId)
                if ([int][LfSandboxProcessTerminator]::GetCapturedProcessId($capturedHandle) -ne
                    [int]$matches[0].ProcessId -or
                    -not [string]::Equals(
                        [LfSandboxProcessTerminator]::GetCapturedCreationTimeUtc($capturedHandle),
                        [string]$matches[0].ProcessStartUtc, [StringComparison]::Ordinal) -or
                    -not [string]::Equals(
                        [IO.Path]::GetFullPath([LfSandboxProcessTerminator]::GetCapturedImagePath($capturedHandle)),
                        [IO.Path]::GetFullPath([string]$Expected.ExecutablePath),
                        [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'The captured Codex Desktop handle does not match the trace-bound process instance and image path.'
                }
                $candidateWithHandle = [pscustomobject][ordered]@{
                    Process = $matches[0].Process
                    ProcessId = [int]$matches[0].ProcessId
                    ParentProcessId = [int]$matches[0].ParentProcessId
                    ExecutablePath = [string]$matches[0].ExecutablePath
                    ProcessStartUtc = [string]$matches[0].ProcessStartUtc
                    AttemptKey = Get-ExecutionDesktopAttemptKey ([int]$matches[0].ProcessId) `
                        ([string]$matches[0].ProcessStartUtc)
                    FirstObservedUtc = [string]$matches[0].FirstObservedUtc
                    ExitHandle = $capturedHandle
                }
                $handleTransferred = $true
                return $candidateWithHandle
            }
            finally {
                if (-not $handleTransferred) {
                    Close-SandboxNativeProcessHandle $capturedHandle
                }
            }
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Label."
}

function Wait-ForCapturedProcessExit([int]$ProcessId, [object]$ProcessHandle, [int]$Seconds, [string]$Label,
    [Diagnostics.Process]$Launcher, [Collections.IDictionary]$ProgressAudit,
    [Collections.IDictionary]$RecoveryProgressAudit) {
    if ($null -eq $ProcessHandle -or [IntPtr]$ProcessHandle -eq [IntPtr]::Zero) {
        throw "The native process handle for $Label is unavailable."
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if ($null -ne $ProgressAudit) { Add-LauncherProgressSample $Launcher $ProgressAudit }
        if ($null -ne $RecoveryProgressAudit) { Add-LauncherProgressSample $Launcher $RecoveryProgressAudit }
        if ([LfSandboxProcessTerminator]::WaitForExit([IntPtr]$ProcessHandle, 0)) {
            [uint32]$nativeExitCode = [LfSandboxProcessTerminator]::GetExitCode(
                [IntPtr]$ProcessHandle)
            if ($nativeExitCode -eq 259) {
                throw "$Label signaled exit but GetExitCodeProcess still returned STILL_ACTIVE."
            }
            return [pscustomobject][ordered]@{
                ProcessId = $ProcessId
                ProcessExited = $true
                ExitCode = $nativeExitCode
                ObservedExitCode = '0x' + $nativeExitCode.ToString('X8')
            }
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Label."
}

function Wait-ForPostHandoffDelay([object]$Attempt, [int]$MinimumMilliseconds) {
    if ($MinimumMilliseconds -le 9000) {
        throw 'Post-handoff recovery verification must wait longer than the startup confirmation window.'
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            $Attempt.Process.Refresh()
            if ($Attempt.Process.HasExited) {
                throw 'Codex Desktop exited before the post-handoff recovery fault injection.'
            }
        }
        catch {
            throw 'Codex Desktop could not remain alive through the post-handoff recovery delay.'
        }
        Start-Sleep -Milliseconds 100
    } while ($timer.ElapsedMilliseconds -le $MinimumMilliseconds)
    return [int]$timer.ElapsedMilliseconds
}

function Wait-ForPostHandoffExecutionImageInvalidation([string]$Root, [object]$Expected,
    [int[]]$KnownProcessIds, [int]$Seconds,
    [System.Collections.Generic.List[int]]$UnexpectedProcessIds, [object]$RecoveryHelper) {
    if ($null -eq $RecoveryHelper -or $null -eq $RecoveryHelper.ExitHandle -or
        [IntPtr]$RecoveryHelper.ExitHandle -eq [IntPtr]::Zero) {
        throw 'The post-handoff recovery helper native handle is unavailable.'
    }
    $known = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($processId in @($KnownProcessIds)) { [void]$known.Add([int]$processId) }
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $records = @(Get-ExecutionDesktopProcessRecords $Root)
        $pending = New-Object 'System.Collections.Generic.List[object]'
        foreach ($record in $records) {
            if (-not $known.Contains([int]$record.ProcessId)) { $pending.Add($record) }
        }
        $madeProgress = $true
        while ($pending.Count -ne 0 -and $madeProgress) {
            $madeProgress = $false
            foreach ($record in @($pending.ToArray())) {
                if ($known.Contains([int]$record.ParentProcessId)) {
                    [void]$known.Add([int]$record.ProcessId)
                    [void]$pending.Remove($record)
                    $madeProgress = $true
                }
            }
        }
        foreach ($record in $pending) {
            $processId = [int]$record.ProcessId
            if (-not $UnexpectedProcessIds.Contains($processId)) {
                $UnexpectedProcessIds.Add($processId)
            }
        }
        if ($UnexpectedProcessIds.Count -ne 0) {
            throw 'Watchdog recovery started a new local execution-image desktop process before a manual launcher action.'
        }

        $versionRootExists = Test-Path -LiteralPath $Expected.VersionRoot -PathType Container
        if (-not $versionRootExists -and $records.Count -eq 0) {
            return [pscustomobject][ordered]@{
                VersionRootDeleted = $true
                NoExecutionDesktopProcesses = $true
                ObservedDesktopProcessIds = @($known | Sort-Object)
                CompletedUtc = [DateTime]::UtcNow.ToString('o')
            }
        }
        if ([LfSandboxProcessTerminator]::WaitForExit(
                [IntPtr]$RecoveryHelper.ExitHandle, 0)) {
            [uint32]$helperExitCode = [LfSandboxProcessTerminator]::GetExitCode(
                [IntPtr]$RecoveryHelper.ExitHandle)
            throw ('The post-handoff recovery helper exited with status 0x' +
                $helperExitCode.ToString('X8') +
                ' before invalidating the local execution image.')
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Timed out waiting for post-handoff watchdog invalidation of the local execution image.'
}

function Wait-ForExecutionDesktopMainWindow([string]$Root, [object]$Expected,
    [object]$Attempt, [int]$LauncherProcessId, [int]$Seconds, [Diagnostics.Process]$Launcher,
    [Collections.IDictionary]$ProgressAudit, [Collections.IDictionary]$RecoveryProgressAudit,
    [hashtable]$Attempts) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if ($null -ne $ProgressAudit) { Add-LauncherProgressSample $Launcher $ProgressAudit }
        if ($null -ne $RecoveryProgressAudit) { Add-LauncherProgressSample $Launcher $RecoveryProgressAudit }
        Assert-NoUnexpectedDesktopExecutablePath $Root $Expected
        $candidates = @(Get-ExecutionDesktopRootProcesses $Root $LauncherProcessId)
        Add-ExecutionDesktopAttemptObservations $Attempts $candidates
        if ($Attempts.Count -gt 2) { throw 'Observed more than one Codex Desktop retry root process.' }
        try {
            $Attempt.Process.Refresh()
            if (-not $Attempt.Process.HasExited -and
                $Attempt.Process.MainWindowHandle -ne [IntPtr]::Zero) {
                return $Attempt.Process
            }
        }
        catch { }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Timed out waiting for the retried Codex Desktop main window.'
}

function Wait-ForExecutionDesktopHandoff([string]$Root, [object]$Expected,
    [int]$LauncherProcessId, [int]$Seconds, [Diagnostics.Process]$Launcher,
    [Collections.IDictionary]$ProgressAudit, [Collections.IDictionary]$RecoveryProgressAudit,
    [hashtable]$Attempts) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if ($null -ne $ProgressAudit) { Add-LauncherProgressSample $Launcher $ProgressAudit }
        if ($null -ne $RecoveryProgressAudit) { Add-LauncherProgressSample $Launcher $RecoveryProgressAudit }
        Assert-NoUnexpectedDesktopExecutablePath $Root $Expected
        $candidates = @(Get-ExecutionDesktopRootProcesses $Root $LauncherProcessId)
        Add-ExecutionDesktopAttemptObservations $Attempts $candidates
        if ($Attempts.Count -gt 2) { throw 'Observed more than one Codex Desktop retry root process.' }
        try {
            $Launcher.Refresh()
            if ($Launcher.HasExited) { return $true }
        }
        catch { return $true }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Get-SessionProcessStartTraceRecords([object]$Trace, [int]$SessionId,
    [int]$MinimumOrdinal = 0) {
    return @(
        Get-MandatoryProcessStartTraceSnapshot $Trace | Where-Object {
            [int]$_.SessionId -eq $SessionId -and [int]$_.EventOrdinal -gt $MinimumOrdinal
        }
    )
}

function Get-DesktopProcessStartTraceRecords([object]$Trace, [int]$SessionId,
    [int]$MinimumOrdinal = 0) {
    return @(
        Get-SessionProcessStartTraceRecords $Trace $SessionId $MinimumOrdinal | Where-Object {
            [string]::Equals([string]$_.ProcessName, 'CodexDesktop.exe',
                [StringComparison]::OrdinalIgnoreCase)
        }
    )
}

function Assert-DirectDesktopProcessStartTraceSequence([object]$Trace, [int]$SessionId,
    [int]$MinimumOrdinal, [int]$LauncherProcessId, [int[]]$ExpectedProcessIds,
    [string]$Label) {
    [void](Wait-ForMandatoryProcessStartTraceQuiescence $Trace 750 20)
    $records = @(
        Get-DesktopProcessStartTraceRecords $Trace $SessionId $MinimumOrdinal | Where-Object {
            [int]$_.ParentProcessId -eq $LauncherProcessId
        } | Sort-Object EventOrdinal
    )
    if ($records.Count -ne $ExpectedProcessIds.Count) {
        throw "$Label did not emit the exact required direct-child CodexDesktop process-start sequence."
    }
    for ($index = 0; $index -lt $ExpectedProcessIds.Count; $index++) {
        if ([int]$records[$index].ProcessId -ne [int]$ExpectedProcessIds[$index]) {
            throw "$Label process-start sequence is out of order or bound to the wrong PID."
        }
    }
    return [pscustomobject][ordered]@{
        LauncherProcessId = $LauncherProcessId
        ExpectedProcessIds = @($ExpectedProcessIds)
        RootEvents = @($records | ForEach-Object { ConvertTo-ProcessStartTraceEvidence $_ })
        ExactSequence = $true
    }
}

function Get-RecoveryHelperProcessStartTrace([object]$Trace, [int]$SessionId,
    [int]$MinimumOrdinal, [int]$LauncherProcessId, [string]$PortableRoot) {
    [void](Wait-ForMandatoryProcessStartTraceQuiescence $Trace 750 20)
    $records = @(
        Get-SessionProcessStartTraceRecords $Trace $SessionId $MinimumOrdinal | Where-Object {
            [int]$_.ParentProcessId -eq $LauncherProcessId -and
                [string]$_.ProcessName -like 'LFRecovery-*.exe'
        } | Sort-Object EventOrdinal
    )
    if ($records.Count -ne 1) {
        throw 'The manual restart did not emit exactly one traceable LF recovery helper.'
    }
    $record = $records[0]
    $processRecord = Wait-Until {
        @(Get-CimInstance Win32_Process -Filter ("ProcessId = " + [int]$record.ProcessId) `
                -ErrorAction Stop | Select-Object -First 1)
    } 15 'the trace-bound LF recovery helper process metadata'
    if ([int]$processRecord.ProcessId -ne [int]$record.ProcessId -or
        [int]$processRecord.ParentProcessId -ne [int]$record.ParentProcessId) {
        throw 'The trace-bound LF recovery helper PID was reused by an unexpected parent process.'
    }
    $path = [string]$processRecord.ExecutablePath
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData) -or -not [IO.Path]::IsPathRooted($localAppData)) {
        throw 'The Sandbox local application-data path is unavailable for LF recovery-helper validation.'
    }
    $scratchBase = [IO.Path]::GetFullPath((Join-Path $localAppData 'LFPortable\scratch')).TrimEnd('\')
    $fullPath = if ([string]::IsNullOrWhiteSpace($path)) { $null } else {
        [IO.Path]::GetFullPath($path)
    }
    $portableFull = [IO.Path]::GetFullPath($PortableRoot).TrimEnd('\')
    $fixedLocalPath = -not [string]::IsNullOrWhiteSpace($fullPath) -and
        $fullPath.StartsWith($scratchBase + '\', [StringComparison]::OrdinalIgnoreCase) -and
        -not ($fullPath.Equals($portableFull, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($portableFull + '\', [StringComparison]::OrdinalIgnoreCase)) -and
        (New-Object IO.DriveInfo([IO.Path]::GetPathRoot($fullPath))).DriveType -eq [IO.DriveType]::Fixed
    if (-not $fixedLocalPath -or
        -not [string]::Equals([IO.Path]::GetFileName($fullPath), [string]$record.ProcessName,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The trace-bound LF recovery helper is not running from fixed local scratch.'
    }
    $process = Get-Process -Id ([int]$record.ProcessId) -ErrorAction Stop
    $process.Refresh()
    if ($process.HasExited) { throw 'The trace-bound LF recovery helper exited before its instance could be captured.' }
    $processStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
    Initialize-SandboxProcessTerminator
    $exitHandle = [IntPtr]::Zero
    try {
        $exitHandle = [LfSandboxProcessTerminator]::CaptureForExitEvidence([int]$record.ProcessId)
        if ([int][LfSandboxProcessTerminator]::GetCapturedProcessId($exitHandle) -ne
            [int]$record.ProcessId -or
            -not [string]::Equals(
                [LfSandboxProcessTerminator]::GetCapturedCreationTimeUtc($exitHandle),
                $processStartUtc, [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [IO.Path]::GetFullPath([LfSandboxProcessTerminator]::GetCapturedImagePath($exitHandle)),
                $fullPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The captured LF recovery-helper handle does not match the trace-bound process instance and image path.'
        }
        return [pscustomobject][ordered]@{
            Process = $process
            ExitHandle = $exitHandle
            Event = $record
            Evidence = [pscustomobject][ordered]@{
                ProcessId = [int]$record.ProcessId
                ParentProcessId = [int]$record.ParentProcessId
                ProcessName = [string]$record.ProcessName
                ExecutablePath = $fullPath
                FixedLocalScratchPath = $fixedLocalPath
                TraceEventOrdinal = [int]$record.EventOrdinal
                TraceBound = $true
            }
        }
    }
    catch {
        Close-SandboxNativeProcessHandle $exitHandle
        throw
    }
}

function Wait-ForTraceBoundProcessExit([Diagnostics.Process]$Process, [object]$ProcessHandle,
    [int]$Seconds,
    [string]$Label) {
    if ($null -eq $Process -or $null -eq $ProcessHandle -or
        [IntPtr]$ProcessHandle -eq [IntPtr]::Zero) {
        throw "$Label native process handle is unavailable."
    }
    if (-not [LfSandboxProcessTerminator]::WaitForExit([IntPtr]$ProcessHandle, $Seconds * 1000)) {
        throw "Timed out waiting for $Label to exit."
    }
    [uint32]$nativeExitCode = [LfSandboxProcessTerminator]::GetExitCode([IntPtr]$ProcessHandle)
    if ($nativeExitCode -eq 259) {
        throw "$Label signaled exit but GetExitCodeProcess still returned STILL_ACTIVE."
    }
    return [pscustomobject][ordered]@{
        ProcessId = $Process.Id
        ProcessExited = $true
        ExitCode = $nativeExitCode
        ObservedExitCode = '0x' + $nativeExitCode.ToString('X8')
    }
}

function Wait-ForNoExecutionDesktopProcesses([string]$Root, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $records = @(Get-ExecutionDesktopProcessRecords $Root)
        if ($records.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Complete-MandatoryProcessStartTraceAudit([object]$Trace, [int]$SessionId,
    [int]$MinimumOrdinal, [object[]]$ExpectedRoots) {
    [void](Wait-ForMandatoryProcessStartTraceQuiescence $Trace 750 20)
    $allRecords = @(Get-SessionProcessStartTraceRecords $Trace $SessionId $MinimumOrdinal |
            Sort-Object EventOrdinal)
    $records = @($allRecords | Where-Object {
            [string]::Equals([string]$_.ProcessName, 'CodexDesktop.exe',
                [StringComparison]::OrdinalIgnoreCase)
        })
    $expectedOrdinals = New-Object 'System.Collections.Generic.HashSet[int]'
    $expectedRootsByOrdinal = @{}
    $bindings = New-Object 'System.Collections.Generic.List[object]'
    $allBindingsValid = $true
    foreach ($expected in @($ExpectedRoots)) {
        $expectedProcessId = [int]$expected.ProcessId
        $parentPid = [int]$expected.ParentProcessId
        $traceEventOrdinal = [int]$expected.TraceEventOrdinal
        if ($expectedProcessId -le 0 -or $parentPid -le 0 -or $traceEventOrdinal -le 0 -or
            -not $expectedOrdinals.Add($traceEventOrdinal)) {
            $allBindingsValid = $false
        }
        else {
            $expectedRootsByOrdinal[$traceEventOrdinal] = [pscustomobject]@{
                ProcessId = $expectedProcessId
                ParentProcessId = $parentPid
            }
        }
        $matches = @($records | Where-Object {
                [int]$_.EventOrdinal -eq $traceEventOrdinal -and
                    [int]$_.ProcessId -eq $expectedProcessId -and [int]$_.ParentProcessId -eq $parentPid
            })
        $valid = $matches.Count -eq 1
        if (-not $valid) { $allBindingsValid = $false }
        $bindings.Add([pscustomobject][ordered]@{
                Label = [string]$expected.Label
                ProcessId = $expectedProcessId
                ParentProcessId = $parentPid
                TraceEventOrdinal = $traceEventOrdinal
                MatchCount = $matches.Count
                TraceEvent = if ($matches.Count -eq 1) {
                    ConvertTo-ProcessStartTraceEvidence $matches[0]
                } else { $null }
                Valid = $valid
            })
    }

    $allowedInstanceByProcessId = @{}
    $unexpected = New-Object 'System.Collections.Generic.List[object]'
    foreach ($record in $allRecords) {
        $eventOrdinal = [int]$record.EventOrdinal
        $processId = [int]$record.ProcessId
        $parentProcessId = [int]$record.ParentProcessId
        $expectedRoot = if ($expectedRootsByOrdinal.ContainsKey($eventOrdinal)) {
            $expectedRootsByOrdinal[$eventOrdinal]
        } else { $null }
        $isExpectedRoot = $null -ne $expectedRoot -and
            $processId -eq [int]$expectedRoot.ProcessId -and
            $parentProcessId -eq [int]$expectedRoot.ParentProcessId
        $parentInstanceAllowed = $allowedInstanceByProcessId.ContainsKey($parentProcessId) -and
            [bool]$allowedInstanceByProcessId[$parentProcessId]
        $instanceAllowed = $isExpectedRoot -or $parentInstanceAllowed

        # A new start event always replaces the prior lifecycle associated
        # with this numeric PID, including its ancestry authorization.
        $allowedInstanceByProcessId[$processId] = $instanceAllowed
        if ([string]::Equals([string]$record.ProcessName, 'CodexDesktop.exe',
                [StringComparison]::OrdinalIgnoreCase) -and -not $instanceAllowed) {
            $unexpected.Add((ConvertTo-ProcessStartTraceEvidence $record))
        }
    }
    return [pscustomobject][ordered]@{
        Provider = 'System.Management.ManagementEventWatcher'
        EventClass = 'Win32_ProcessStartTrace'
        SessionId = $SessionId
        MinimumEventOrdinal = $MinimumOrdinal
        RecordCount = $records.Count
        RelevantEvents = @($records | ForEach-Object { ConvertTo-ProcessStartTraceEvidence $_ })
        ExpectedRootBindings = $bindings.ToArray()
        AllExpectedRootBindingsValid = $allBindingsValid
        UnexpectedProcessStarts = $unexpected.ToArray()
        NoUnexpectedProcessStarts = $unexpected.Count -eq 0
        Passed = $allBindingsValid -and $unexpected.Count -eq 0
    }
}

function Get-TargetProcesses([string]$Root) {
    $bootstrapper = Join-Path $Root 'CodexPortable.exe'
    $launcherRoot = (Join-Path $Root 'CodexData\tools\launchers').TrimEnd('\') + '\'
    $desktopRoot = (Join-Path $Root 'CodexData\app\current').TrimEnd('\') + '\'
    $executionFamilyRoot = Get-ExecutionFamilyRoot $Root
    return @(
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try {
                $path = $_.Path
                -not [string]::IsNullOrWhiteSpace($path) -and
                    ($path.Equals($bootstrapper, [StringComparison]::OrdinalIgnoreCase) -or
                        $path.StartsWith($launcherRoot, [StringComparison]::OrdinalIgnoreCase) -or
                        $path.StartsWith($desktopRoot, [StringComparison]::OrdinalIgnoreCase) -or
                        (Test-ExecutionDesktopProcessPath $path $executionFamilyRoot))
            }
            catch { $false }
        }
    )
}

function Get-TargetDesktopProcesses([string]$Root) {
    $desktopRoot = (Join-Path $Root 'CodexData\app\current').TrimEnd('\') + '\'
    $executionFamilyRoot = Get-ExecutionFamilyRoot $Root
    return @(
        Get-TargetProcesses $Root | Where-Object {
            try {
                ($_.Path.StartsWith($desktopRoot, [StringComparison]::OrdinalIgnoreCase) -or
                    (Test-ExecutionDesktopProcessPath $_.Path $executionFamilyRoot)) -and
                    ($_.ProcessName -ieq 'CodexDesktop' -or $_.ProcessName -ieq 'ChatGPT')
            }
            catch { $false }
        }
    )
}

function Get-TargetAppCurrentProcesses([string]$Root) {
    $desktopRoot = (Join-Path $Root 'CodexData\app\current').TrimEnd('\') + '\'
    $executionFamilyRoot = Get-ExecutionFamilyRoot $Root
    return @(
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try {
                $path = $_.Path
                -not [string]::IsNullOrWhiteSpace($path) -and
                    ($path.StartsWith($desktopRoot, [StringComparison]::OrdinalIgnoreCase) -or
                        (Test-ExecutionDesktopProcessPath $path $executionFamilyRoot))
            }
            catch { $false }
        }
    )
}

function Get-ProcessSnapshot([System.Diagnostics.Process[]]$Processes) {
    $snapshot = New-Object 'System.Collections.Generic.List[object]'
    foreach ($process in @($Processes)) {
        try { $process.Refresh() } catch { }
        $id = $null
        $processName = $null
        $path = $null
        $hasExited = $null
        $exitCode = $null
        $mainWindowHandle = $null
        $mainWindowTitle = $null
        try { $id = $process.Id } catch { }
        try { $processName = $process.ProcessName } catch { }
        try { $path = $process.Path } catch { }
        try { $hasExited = $process.HasExited } catch { }
        if ($hasExited -eq $true) { try { $exitCode = $process.ExitCode } catch { } }
        try { $mainWindowHandle = $process.MainWindowHandle.ToInt64() } catch { }
        try { $mainWindowTitle = $process.MainWindowTitle } catch { }
        $snapshot.Add([ordered]@{
            Id = $id
            ProcessName = $processName
            Path = $path
            HasExited = $hasExited
            ExitCode = $exitCode
            MainWindowHandle = $mainWindowHandle
            MainWindowTitle = $mainWindowTitle
        })
    }
    return @($snapshot.ToArray())
}

function Protect-DiagnosticText([string]$Text, [string[]]$Secrets) {
    if ($null -eq $Text) { return $null }
    $protected = [string]$Text
    foreach ($secret in @($Secrets)) {
        if (-not [string]::IsNullOrWhiteSpace($secret)) {
            $protected = $protected.Replace($secret, '[REDACTED]')
        }
    }
    $protected = [regex]::Replace($protected,
        '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer [REDACTED]')
    $protected = [regex]::Replace($protected,
        '(?i)\bsk-[A-Za-z0-9._-]{8,}\b', '[REDACTED]')
    $protected = [regex]::Replace($protected,
        '(?i)\bsandbox-[0-9a-f]{32}\b', '[REDACTED]')
    $assignmentPattern = '(?im)(?<prefix>["'']?(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|token|password|secret)["'']?\s*[:=]\s*)(?<value>"[^"\r\n]*"|''[^''\r\n]*''|[^\s,;\r\n]+)'
    return [regex]::Replace($protected, $assignmentPattern, '${prefix}[REDACTED]')
}

function Get-SanitizedLauncherLogTail([string]$Root, [string[]]$Secrets) {
    $logsRoot = Join-Path $Root 'CodexData\logs'
    $log = @(
        Get-ChildItem -LiteralPath $logsRoot -Filter 'launcher-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
    )
    if ($log.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Found = $false
            FileName = $null
            LastWriteUtc = $null
            SourceLength = 0
            TailLineLimit = 100
            TailCharacterLimit = 32768
            TailWasTruncated = $false
            Text = $null
        }
    }

    $lines = @(Get-Content -LiteralPath $log[0].FullName -Tail 100 -ErrorAction Stop |
        ForEach-Object { [string]$_ })
    $text = Protect-DiagnosticText ($lines -join "`r`n") $Secrets
    $truncated = $text.Length -gt 32768
    if ($truncated) { $text = $text.Substring($text.Length - 32768) }
    return [pscustomobject][ordered]@{
        Found = $true
        FileName = $log[0].Name
        LastWriteUtc = $log[0].LastWriteTimeUtc.ToString('o')
        SourceLength = $log[0].Length
        TailLineLimit = 100
        TailCharacterLimit = 32768
        TailWasTruncated = $truncated
        Text = $text
    }
}

function Stop-TargetProcesses([string]$Root) {
    $initial = @(Get-TargetProcesses $Root)
    foreach ($process in $initial) {
        try {
            $process.Refresh()
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) { $null = $process.CloseMainWindow() }
        }
        catch { }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $remaining = @(Get-TargetProcesses $Root)
    } while ($remaining.Count -ne 0 -and [DateTime]::UtcNow -lt $deadline)
    $forced = New-Object 'System.Collections.Generic.List[int]'
    foreach ($process in $remaining) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            $forced.Add($process.Id)
        }
        catch { }
    }
    Start-Sleep -Milliseconds 500
    $final = @(Get-TargetProcesses $Root)
    return [pscustomobject][ordered]@{
        Scope = 'Executable paths under the Sandbox target portable root and its associated local execution-image family'
        InitialProcessIds = @($initial | Select-Object -ExpandProperty Id)
        ForceStoppedProcessIds = @($forced)
        RemainingProcessIds = @($final | Select-Object -ExpandProperty Id)
        Succeeded = $final.Count -eq 0
    }
}

function Get-InstalledPluginAudit([string]$CacheRoot) {
    $found = @{}
    $invalid = New-Object 'System.Collections.Generic.List[string]'
    $unexpected = New-Object 'System.Collections.Generic.List[string]'
    # Windows PowerShell 5.1 can reject a PSCustomObject passed through the
    # generic List[object].Add binder. ArrayList keeps the diagnostic path
    # type-safe without changing the validation result contract.
    $observedVersions = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $CacheRoot -PathType Container) {
        foreach ($catalogRoot in @(Get-ChildItem -LiteralPath $CacheRoot -Directory -Force)) {
            $catalog = $catalogRoot.Name
            if (-not $expectedPlugins.Contains($catalog)) { $unexpected.Add($catalog); continue }
            foreach ($pluginRoot in @(Get-ChildItem -LiteralPath $catalogRoot.FullName -Directory -Force)) {
                $plugin = $pluginRoot.Name
                if ($expectedPlugins[$catalog] -cnotcontains $plugin) { $unexpected.Add("$catalog/$plugin"); continue }
                foreach ($versionRoot in @(Get-ChildItem -LiteralPath $pluginRoot.FullName -Directory -Force)) {
                    $pluginManifest = Join-Path $versionRoot.FullName '.codex-plugin\plugin.json'
                    $manifestName = $null
                    $manifestVersion = $null
                    $manifestError = $null
                    $validVersion = $false
                    try {
                        $metadata = Get-Content -LiteralPath $pluginManifest -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                        $manifestName = [string]$metadata.name
                        $manifestVersion = [string]$metadata.version
                        if ($manifestName -cne $plugin -or $manifestVersion -cne $versionRoot.Name) {
                            throw 'manifest identity mismatch'
                        }
                        $validVersion = $true
                    }
                    catch {
                        $manifestError = $_.Exception.Message
                        $invalid.Add("$catalog/$plugin/$($versionRoot.Name)")
                    }
                    $null = $observedVersions.Add([pscustomobject][ordered]@{
                            Catalog = $catalog
                            Plugin = $plugin
                            VersionDirectory = $versionRoot.Name
                            ManifestPath = $pluginManifest
                            ManifestExists = Test-Path -LiteralPath $pluginManifest -PathType Leaf
                            ManifestName = $manifestName
                            ManifestVersion = $manifestVersion
                            Error = $manifestError
                            Valid = $validVersion
                        })
                    if ($validVersion) { $found["$catalog/$plugin"] = $true }
                }
            }
        }
    }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($catalog in $expectedPlugins.Keys) {
        foreach ($plugin in $expectedPlugins[$catalog]) {
            $key = "$catalog/$plugin"
            if (-not $found.Contains($key)) { $missing.Add($key) }
        }
    }
    return [pscustomobject][ordered]@{
        CacheRoot = $CacheRoot
        CacheRootExists = Test-Path -LiteralPath $CacheRoot -PathType Container
        ExpectedPluginCount = 12
        FoundPluginCount = $found.Count
        MissingPlugins = @($missing | Sort-Object)
        InvalidPluginVersions = @($invalid | Sort-Object -Unique)
        UnexpectedPluginRoots = @($unexpected | Sort-Object -Unique)
        ObservedVersions = @($observedVersions)
        Valid = $found.Count -eq 12 -and $missing.Count -eq 0 -and $invalid.Count -eq 0 -and $unexpected.Count -eq 0
    }
}

function Initialize-SandboxStartButtonProbe {
    if ($null -eq ('LfSandboxStartButtonProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class LfSandboxProgressBarSample {
    public long Handle { get; set; }
    public string ClassName { get; set; }
    public string StyleFlagsHex { get; set; }
    public bool HasIndeterminateStyle { get; set; }
    public int Minimum { get; set; }
    public int Maximum { get; set; }
    public int Position { get; set; }
}

public sealed class LfSandboxLauncherProgressSnapshot {
    public string[] VisibleLabels { get; set; }
    public LfSandboxProgressBarSample[] ProgressBars { get; set; }
}

public sealed class LfSandboxTopLevelWindowSnapshot {
    public long Handle { get; set; }
    public long OwnerHandle { get; set; }
    public string ClassName { get; set; }
    public string Title { get; set; }
    public bool IsEnabled { get; set; }
    public bool IsDialogLike { get; set; }
    public string[] VisibleChildTexts { get; set; }
}

public static class LfSandboxStartButtonProbe {
    private const uint BM_CLICK = 0x00f5;
    private const int GWL_STYLE = -16;
    private const uint GW_OWNER = 4;
    private const uint PBS_MARQUEE = 0x0008;
    private const uint PBM_GETRANGE = 0x0407;
    private const uint PBM_GETPOS = 0x0408;
    private const uint SMTO_ABORTIFHUNG = 0x0002;
    private delegate bool EnumChildProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumChildWindows(IntPtr parent, EnumChildProc callback, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumChildProc callback, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hwnd, StringBuilder className, int count);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowEnabled(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SendMessageTimeout(IntPtr hwnd, uint message, IntPtr wParam,
        IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
    private static extern int GetWindowLong32(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hwnd, int index);

    private static IntPtr GetWindowStyle(IntPtr hwnd) {
        return IntPtr.Size == 8 ? GetWindowLongPtr64(hwnd, GWL_STYLE) :
            new IntPtr(GetWindowLong32(hwnd, GWL_STYLE));
    }

    private static int GetProgressValue(IntPtr hwnd, uint message, IntPtr wParam) {
        IntPtr result;
        if (!SendMessageTimeout(hwnd, message, wParam, IntPtr.Zero,
            SMTO_ABORTIFHUNG, 1000, out result)) return -1;
        return result.ToInt32();
    }

    private static string ReadWindowText(IntPtr hwnd) {
        int length = GetWindowTextLength(hwnd);
        if (length <= 0 || length > 4096) return String.Empty;
        StringBuilder text = new StringBuilder(length + 1);
        return GetWindowText(hwnd, text, text.Capacity) == 0 ? String.Empty : text.ToString().Trim();
    }

    private static string ReadClassName(IntPtr hwnd) {
        StringBuilder className = new StringBuilder(256);
        return GetClassName(hwnd, className, className.Capacity) == 0 ? String.Empty : className.ToString();
    }

    private static string[] ReadVisibleChildTexts(IntPtr parent) {
        List<string> labels = new List<string>();
        EnumChildWindows(parent, delegate(IntPtr child, IntPtr ignored) {
            if (!IsWindowVisible(child)) return true;
            string text = ReadWindowText(child);
            if (text.Length != 0 && !labels.Contains(text) && labels.Count < 128) labels.Add(text);
            return true;
        }, IntPtr.Zero);
        return labels.ToArray();
    }

    public static string ClickStartCodexButton(IntPtr parent) {
        string clicked = null;
        EnumChildWindows(parent, delegate(IntPtr child, IntPtr ignored) {
            if (!IsWindowEnabled(child)) return true;
            StringBuilder className = new StringBuilder(128);
            if (GetClassName(child, className, className.Capacity) == 0) return true;
            string classValue = className.ToString();
            // WinForms controls are commonly exposed as Button, but themed
            // .NET Framework builds use WindowsForms10.BUTTON.*. Accept only
            // those two button-class forms; do not probe arbitrary controls.
            if (!String.Equals(classValue, "Button", StringComparison.OrdinalIgnoreCase) &&
                !classValue.StartsWith("WindowsForms10.BUTTON", StringComparison.OrdinalIgnoreCase)) return true;
            int length = GetWindowTextLength(child);
            if (length <= 0 || length > 4096) return true;
            StringBuilder text = new StringBuilder(length + 1);
            GetWindowText(child, text, text.Capacity);
            string value = text.ToString().Trim();
            if (!String.Equals(value, "Start Codex", StringComparison.Ordinal) &&
                !String.Equals(value, "\u542f\u52a8 Codex", StringComparison.Ordinal)) return true;
            IntPtr result;
            if (!SendMessageTimeout(child, BM_CLICK, IntPtr.Zero, IntPtr.Zero,
                SMTO_ABORTIFHUNG, 5000, out result)) return true;
            clicked = value;
            return false;
        }, IntPtr.Zero);
        return clicked;
    }

    public static LfSandboxLauncherProgressSnapshot CaptureProgress(IntPtr parent) {
        List<string> labels = new List<string>();
        List<LfSandboxProgressBarSample> bars = new List<LfSandboxProgressBarSample>();
        EnumChildWindows(parent, delegate(IntPtr child, IntPtr ignored) {
            if (!IsWindowVisible(child)) return true;
            StringBuilder className = new StringBuilder(256);
            if (GetClassName(child, className, className.Capacity) == 0) return true;
            string classValue = className.ToString();
            string label = ReadWindowText(child);
            if (label.Length != 0 && !labels.Contains(label) && labels.Count < 128) labels.Add(label);
            if (classValue.IndexOf("msctls_progress32", StringComparison.OrdinalIgnoreCase) < 0) return true;

            uint style = unchecked((uint)GetWindowStyle(child).ToInt64());
            bars.Add(new LfSandboxProgressBarSample {
                Handle = child.ToInt64(),
                ClassName = classValue,
                StyleFlagsHex = "0x" + style.ToString("X8"),
                HasIndeterminateStyle = (style & PBS_MARQUEE) != 0,
                Minimum = GetProgressValue(child, PBM_GETRANGE, new IntPtr(1)),
                Maximum = GetProgressValue(child, PBM_GETRANGE, IntPtr.Zero),
                Position = GetProgressValue(child, PBM_GETPOS, IntPtr.Zero)
            });
            return true;
        }, IntPtr.Zero);
        return new LfSandboxLauncherProgressSnapshot {
            VisibleLabels = labels.ToArray(),
            ProgressBars = bars.ToArray()
        };
    }

    public static LfSandboxTopLevelWindowSnapshot[] CaptureTopLevelWindows(int processId) {
        List<LfSandboxTopLevelWindowSnapshot> windows = new List<LfSandboxTopLevelWindowSnapshot>();
        EnumWindows(delegate(IntPtr window, IntPtr ignored) {
            if (!IsWindowVisible(window) || windows.Count >= 32) return true;
            uint ownerProcessId;
            GetWindowThreadProcessId(window, out ownerProcessId);
            if (ownerProcessId != unchecked((uint)processId)) return true;
            string className = ReadClassName(window);
            IntPtr owner = GetWindow(window, GW_OWNER);
            windows.Add(new LfSandboxTopLevelWindowSnapshot {
                Handle = window.ToInt64(),
                OwnerHandle = owner.ToInt64(),
                ClassName = className,
                Title = ReadWindowText(window),
                IsEnabled = IsWindowEnabled(window),
                IsDialogLike = String.Equals(className, "#32770", StringComparison.OrdinalIgnoreCase) ||
                    owner != IntPtr.Zero,
                VisibleChildTexts = ReadVisibleChildTexts(window)
            });
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
}
'@
    }
}

function Get-LauncherWindowSnapshot([Diagnostics.Process]$Launcher, [string[]]$Secrets) {
    if ($null -eq $Launcher) { return @() }
    try { $launcherProcessId = $Launcher.Id }
    catch { return @() }
    return @(
        [LfSandboxStartButtonProbe]::CaptureTopLevelWindows($launcherProcessId) |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    Handle = $_.Handle
                    OwnerHandle = $_.OwnerHandle
                    ClassName = Protect-DiagnosticText ([string]$_.ClassName) $Secrets
                    Title = Protect-DiagnosticText ([string]$_.Title) $Secrets
                    IsEnabled = [bool]$_.IsEnabled
                    IsDialogLike = [bool]$_.IsDialogLike
                    VisibleChildTexts = @($_.VisibleChildTexts | ForEach-Object {
                        Protect-DiagnosticText ([string]$_) $Secrets
                    })
                }
            }
    )
}

function New-LauncherProgressAudit {
    return [ordered]@{
        RawSampleCount = 0
        ProgressBarObserved = $false
        IndeterminateStyleObserved = $false
        ProgressRangeObserved = $false
        InvalidProgressRangeObserved = $false
        ObservedPositions = New-Object 'System.Collections.Generic.HashSet[int]'
        HighestPositionByHandle = @{}
        PositionIncreaseObserved = $false
        RecoveryProgressBaselineReset = $false
        AmbiguousLabels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        GenericStatusLabels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        ExplicitStageLabels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        ExplicitStageKinds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        RecoveryObservedStages = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        RecoveryStepNumbers = New-Object 'System.Collections.Generic.HashSet[int]'
        RecoveryTransitionSteps = New-Object 'System.Collections.Generic.List[int]'
        RecoveryTransitionStages = New-Object 'System.Collections.Generic.List[string]'
        RecoverySequenceValid = $true
        Samples = New-Object 'System.Collections.Generic.List[object]'
        LastSignature = $null
        SamplesTruncated = $false
    }
}

function Reset-RecoveryProgressBaseline([Collections.IDictionary]$Audit) {
    if ([bool]$Audit.RecoveryProgressBaselineReset) { return $false }

    $Audit.ObservedPositions.Clear()
    $Audit.HighestPositionByHandle.Clear()
    $Audit.PositionIncreaseObserved = $false
    $Audit.RecoveryProgressBaselineReset = $true
    return $true
}

function Register-DeterminateProgressMeasurements([object[]]$Bars, [Collections.IDictionary]$Audit) {
    foreach ($bar in @($Bars)) {
        $minimum = [int]$bar.Minimum
        $maximum = [int]$bar.Maximum
        $position = [int]$bar.Position
        # SendMessageTimeout returns -1 when the launcher is tearing down its
        # progress control. That is an unavailable sample, not a displayed
        # invalid range. Real values remain subject to the strict range gate.
        if ($minimum -eq -1 -or $maximum -eq -1 -or $position -eq -1) {
            continue
        }
        if ($maximum -le $minimum -or $position -lt $minimum -or $position -gt $maximum) {
            $Audit.InvalidProgressRangeObserved = $true
            continue
        }

        $Audit.ProgressRangeObserved = $true
        $null = $Audit.ObservedPositions.Add($position)
        $handle = [string]$bar.Handle
        if ($Audit.HighestPositionByHandle.ContainsKey($handle)) {
            if ($position -gt [int]$Audit.HighestPositionByHandle[$handle]) {
                $Audit.PositionIncreaseObserved = $true
                $Audit.HighestPositionByHandle[$handle] = $position
            }
        }
        else {
            $Audit.HighestPositionByHandle[$handle] = $position
        }
    }
}

function Register-ExplicitStageLabels([string[]]$Labels, [Collections.IDictionary]$Audit) {
    $startButtonChinese = (-join @([char]0x542F, [char]0x52A8)) + ' Codex'
    $startButtonLabels = @('Start Codex', $startButtonChinese)
    $stageRules = @(
        [pscustomobject]@{ Kind = 'Validating'; Token = (-join @([char]0x6821, [char]0x9A8C)) }
        [pscustomobject]@{ Kind = 'Extracting'; Token = (-join @([char]0x5C55, [char]0x5F00)) }
        [pscustomobject]@{ Kind = 'Installing'; Token = (-join @([char]0x5B89, [char]0x88C5)) }
        [pscustomobject]@{ Kind = 'Verifying'; Token = (-join @([char]0x590D, [char]0x6838)) }
        [pscustomobject]@{ Kind = 'Starting'; Token = (-join @([char]0x542F, [char]0x52A8)) }
        [pscustomobject]@{ Kind = 'Rebuilding'; Token = (-join @([char]0x91CD, [char]0x5EFA)) }
        [pscustomobject]@{ Kind = 'Ready'; Token = (-join @([char]0x5C31, [char]0x7EEA)) }
        [pscustomobject]@{ Kind = 'Confirming'; Token = (-join @([char]0x786E, [char]0x8BA4)) }
        [pscustomobject]@{ Kind = 'Validating'; Token = 'Validating' }
        [pscustomobject]@{ Kind = 'Extracting'; Token = 'Extracting' }
        [pscustomobject]@{ Kind = 'Installing'; Token = 'Installing' }
        [pscustomobject]@{ Kind = 'Verifying'; Token = 'Verifying' }
        [pscustomobject]@{ Kind = 'Starting'; Token = 'Starting' }
        [pscustomobject]@{ Kind = 'Rebuilding'; Token = 'Rebuilding' }
        [pscustomobject]@{ Kind = 'Ready'; Token = 'ready' }
        [pscustomobject]@{ Kind = 'Confirming'; Token = 'Confirming' }
    )
    foreach ($label in @($Labels)) {
        if ([string]::IsNullOrWhiteSpace($label) -or $startButtonLabels -contains $label) { continue }
        foreach ($rule in $stageRules) {
            if ($label.IndexOf($rule.Token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $null = $Audit.ExplicitStageLabels.Add($label)
                $null = $Audit.ExplicitStageKinds.Add($rule.Kind)
            }
        }
    }
}

function Register-RecoveryProgressLabels([string[]]$Labels, [Collections.IDictionary]$Audit) {
    $sampleSteps = New-Object 'System.Collections.Generic.HashSet[int]'
    $chineseStepPrefix = -join @([char]0x7B2C, [char]0x0020)
    $chineseStepSuffix = -join @([char]0x002F, [char]0x0034, [char]0x0020, [char]0x6B65)
    $chineseStepPattern = '^' + [regex]::Escape($chineseStepPrefix) +
        '(?<step>[1-4])' + [regex]::Escape($chineseStepSuffix) +
        '(?:\s+\u00B7\s+\d+%)?$'
    foreach ($label in @($Labels)) {
        $match = [regex]::Match($label, '^Step (?<step>[1-4]) of 4(?:\s+\u00B7\s+\d+%)?$',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) { $match = [regex]::Match($label, $chineseStepPattern) }
        if (-not $match.Success) { continue }
        $step = [int]$match.Groups['step'].Value
        $null = $sampleSteps.Add($step)
    }

    $validatingChinese = -join @(
        [char]0x68C0, [char]0x67E5, [char]0x672C, [char]0x673A,
        [char]0x6267, [char]0x884C, [char]0x955C, [char]0x50CF)
    $rebuildingChinese = -join @(
        [char]0x91CD, [char]0x5EFA, [char]0x672C, [char]0x673A,
        [char]0x6267, [char]0x884C, [char]0x955C, [char]0x50CF)
    $readyChinese = -join @(
        [char]0x672C, [char]0x673A, [char]0x6267, [char]0x884C,
        [char]0x955C, [char]0x50CF, [char]0x5DF2, [char]0x5C31, [char]0x7EEA)
    $confirmingChinese = (-join @([char]0x786E, [char]0x8BA4)) + ' Codex ' +
        (-join @([char]0x542F, [char]0x52A8))
    $stageRules = @(
        [pscustomobject]@{
            Name = 'ValidatingLocalExecutionImage'
            Step = 1
            Labels = @($validatingChinese, 'Validating local execution image')
        }
        [pscustomobject]@{
            Name = 'RebuildingLocalExecutionImage'
            Step = 2
            Labels = @($rebuildingChinese, 'Rebuilding local execution image')
        }
        [pscustomobject]@{
            Name = 'LocalExecutionImageReady'
            Step = 3
            Labels = @($readyChinese, 'Local execution image ready')
        }
        [pscustomobject]@{
            Name = 'ConfirmingRetriedDesktopStart'
            Step = 4
            Labels = @($confirmingChinese, 'Confirming Codex startup')
        }
    )
    $matchedRules = New-Object 'System.Collections.Generic.List[object]'
    $matchedRuleNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($label in @($Labels)) {
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        $labelText = [string]$label
        $labelMatches = New-Object 'System.Collections.Generic.List[object]'
        foreach ($rule in $stageRules) {
            $ruleMatches = $false
            foreach ($candidate in @($rule.Labels)) {
                $candidateText = [string]$candidate
                if ([string]::IsNullOrWhiteSpace($candidateText)) { continue }
                if ([string]::Equals($labelText, $candidateText,
                            [StringComparison]::OrdinalIgnoreCase) -or
                    $labelText.IndexOf($candidateText,
                            [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $ruleMatches = $true
                    break
                }
            }
            if ($ruleMatches) { $labelMatches.Add($rule) }
        }
        if ($labelMatches.Count -gt 1) {
            # A single visible control must identify one recovery stage. If a
            # future UI label combines two stage names, fail closed instead of
            # guessing which transition the sampler observed.
            $Audit.RecoverySequenceValid = $false
            return
        }
        if ($labelMatches.Count -eq 1) {
            $rule = $labelMatches[0]
            if ($matchedRuleNames.Add([string]$rule.Name)) {
                $matchedRules.Add($rule)
            }
        }
    }

    # Window text is captured across several controls and can briefly contain
    # only one half of a transition. Record only coherent step+stage frames;
    # repeated samples of the same frame do not constitute a new transition.
    if ($sampleSteps.Count -eq 0 -or $matchedRules.Count -eq 0) { return }
    if ($sampleSteps.Count -ne 1 -or $matchedRules.Count -ne 1) {
        $Audit.RecoverySequenceValid = $false
        return
    }
    $currentStep = 0
    foreach ($candidate in $sampleSteps) { $currentStep = [int]$candidate; break }
    $currentRule = $matchedRules[0]
    if ($currentStep -ne [int]$currentRule.Step) { return }

    $currentStage = [string]$currentRule.Name
    if ($currentStep -eq 1 -and $Audit.RecoveryTransitionSteps.Count -eq 0 -and
        -not [bool]$Audit.RecoveryProgressBaselineReset -and
        [string]::Equals($currentStage, [string]$stageRules[0].Name,
            [StringComparison]::Ordinal)) {
        $null = Reset-RecoveryProgressBaseline $Audit
    }
    $null = $Audit.RecoveryStepNumbers.Add($currentStep)
    $null = $Audit.RecoveryObservedStages.Add($currentStage)
    $transitionCount = $Audit.RecoveryTransitionSteps.Count
    if ($transitionCount -ne 0 -and
        [int]$Audit.RecoveryTransitionSteps[$transitionCount - 1] -eq $currentStep -and
        [string]::Equals([string]$Audit.RecoveryTransitionStages[$transitionCount - 1],
            $currentStage, [StringComparison]::Ordinal)) {
        return
    }

    $Audit.RecoveryTransitionSteps.Add($currentStep)
    $Audit.RecoveryTransitionStages.Add($currentStage)
    $transitionCount = $Audit.RecoveryTransitionSteps.Count
    if ($currentStep -ne $transitionCount -or
        -not [string]::Equals($currentStage, [string]$stageRules[$currentStep - 1].Name,
            [StringComparison]::Ordinal)) {
        $Audit.RecoverySequenceValid = $false
    }
}

function Register-GenericStatusLabels([string[]]$Labels, [Collections.IDictionary]$Audit) {
    $genericInitializationChinese = -join @(
        [char]0x6B63
        [char]0x5728
        [char]0x521D
        [char]0x59CB
        [char]0x5316
    )
    $genericStartPreparationChinese = -join @(
        [char]0x6B63
        [char]0x5728
        [char]0x51C6
        [char]0x5907
        [char]0x542F
        [char]0x52A8
    )
    $genericFirstLaunchPreparationChinese = -join @(
        [char]0x6B63
        [char]0x5728
        [char]0x51C6
        [char]0x5907
        [char]0x9996
        [char]0x6B21
        [char]0x542F
        [char]0x52A8
    )
    $genericPreparationEnglish = 'Pre' + 'paring'
    $genericStatuses = @(
        $genericInitializationChinese
        $genericPreparationEnglish
        $genericStartPreparationChinese
        ($genericPreparationEnglish + ' to start')
        $genericFirstLaunchPreparationChinese
        ($genericPreparationEnglish + ' first launch')
    )
    foreach ($label in @($Labels)) {
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        $normalized = $label.Trim().TrimEnd([char[]]@([char]0x2026, [char]0x002E))
        foreach ($genericStatus in $genericStatuses) {
            if ([string]::Equals($normalized, $genericStatus, [StringComparison]::OrdinalIgnoreCase)) {
                $null = $Audit.GenericStatusLabels.Add($label)
                break
            }
        }
    }
}

function Add-LauncherProgressSample([Diagnostics.Process]$Launcher, [Collections.IDictionary]$Audit) {
    try {
        $Launcher.Refresh()
        if ($Launcher.HasExited -or $Launcher.MainWindowHandle -eq [IntPtr]::Zero) { return }
        $raw = [LfSandboxStartButtonProbe]::CaptureProgress($Launcher.MainWindowHandle)
        $labels = @($raw.VisibleLabels | ForEach-Object { [string]$_ })
        $bars = @($raw.ProgressBars | ForEach-Object {
            [pscustomobject][ordered]@{
                Handle = $_.Handle
                ClassName = $_.ClassName
                StyleFlagsHex = $_.StyleFlagsHex
                HasIndeterminateStyle = [bool]$_.HasIndeterminateStyle
                Minimum = $_.Minimum
                Maximum = $_.Maximum
                Position = $_.Position
            }
        })
        $Audit.RawSampleCount = [int]$Audit.RawSampleCount + 1
        if ($bars.Count -ne 0) { $Audit.ProgressBarObserved = $true }
        if (@($bars | Where-Object { $_.HasIndeterminateStyle }).Count -ne 0) {
            $Audit.IndeterminateStyleObserved = $true
        }
        Register-ExplicitStageLabels $labels $Audit
        Register-GenericStatusLabels $labels $Audit
        $null = Register-RecoveryProgressLabels $labels $Audit
        Register-DeterminateProgressMeasurements $bars $Audit

        $ambiguousChineseLabel = -join @(
            [char]0x6B63
            [char]0x5728
            [char]0x5904
            [char]0x7406
        )
        $ambiguousEnglishLabel = 'Work' + 'ing'
        foreach ($label in $labels) {
            if ($label.IndexOf($ambiguousChineseLabel, [StringComparison]::Ordinal) -ge 0 -or
                $label.IndexOf($ambiguousEnglishLabel, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $null = $Audit.AmbiguousLabels.Add($label)
            }
        }

        $styleSignature = @($bars | ForEach-Object {
            $_.ClassName + ':' + $_.StyleFlagsHex + ':' + $_.Minimum + ':' + $_.Maximum + ':' + $_.Position
        }) -join '|'
        $signature = ($labels -join [char]0x1F) + [char]0x1E + $styleSignature
        if ($signature -cne $Audit.LastSignature) {
            $Audit.LastSignature = $signature
            $sample = [pscustomobject][ordered]@{
                SampledUtc = [DateTime]::UtcNow.ToString('o')
                VisibleLabels = $labels
                ProgressBars = $bars
            }
            if ($Audit.Samples.Count -lt 64) { $Audit.Samples.Add($sample) }
            else { $Audit.SamplesTruncated = $true }
        }
    }
    catch {
        # A closing launcher may invalidate its HWND between process refresh
        # and child enumeration. The aggregate gate still requires at least
        # one successful post-click progress-control observation.
    }
}

function Complete-LauncherProgressAudit([Collections.IDictionary]$Audit,
    [bool]$RequireRecoveryProgress = $false) {
    $ambiguousLabels = @($Audit.AmbiguousLabels | Sort-Object)
    $genericStatusLabels = @($Audit.GenericStatusLabels | Sort-Object)
    $observedPositions = @($Audit.ObservedPositions | Sort-Object)
    $explicitStageLabels = @($Audit.ExplicitStageLabels | Sort-Object)
    $explicitStageKinds = @($Audit.ExplicitStageKinds | Sort-Object)
    $progressRangeValid = [bool]$Audit.ProgressRangeObserved -and -not [bool]$Audit.InvalidProgressRangeObserved
    $progressAdvanced = $progressRangeValid -and $observedPositions.Count -ge 2 -and [bool]$Audit.PositionIncreaseObserved
    $explicitStagesObserved = $explicitStageLabels.Count -ge 3 -and $explicitStageKinds.Count -ge 3
    $genericPassed = [bool]$Audit.ProgressBarObserved -and -not [bool]$Audit.IndeterminateStyleObserved -and
        $ambiguousLabels.Count -eq 0 -and $genericStatusLabels.Count -eq 0 -and $progressAdvanced -and
        $explicitStagesObserved
    $recoveryRequiredStages = @(
        'ValidatingLocalExecutionImage'
        'RebuildingLocalExecutionImage'
        'LocalExecutionImageReady'
        'ConfirmingRetriedDesktopStart'
    )
    $recoveryObservedStages = @($recoveryRequiredStages | Where-Object {
            $Audit.RecoveryObservedStages.Contains($_)
        })
    $recoveryRequiredStagesObserved = $recoveryObservedStages.Count -eq $recoveryRequiredStages.Count
    $recoveryStepNumbers = @($Audit.RecoveryStepNumbers | Sort-Object)
    $recoveryTransitionSteps = @($Audit.RecoveryTransitionSteps | ForEach-Object { [int]$_ })
    $recoveryTransitionStages = @($Audit.RecoveryTransitionStages | ForEach-Object { [string]$_ })
    $recoverySequenceOrdered = [bool]$Audit.RecoverySequenceValid -and
        $recoveryTransitionSteps.Count -eq 4 -and $recoveryTransitionStages.Count -eq 4
    if ($recoverySequenceOrdered) {
        for ($index = 0; $index -lt 4; $index++) {
            if ($recoveryTransitionSteps[$index] -ne ($index + 1) -or
                -not [string]::Equals($recoveryTransitionStages[$index],
                    $recoveryRequiredStages[$index], [StringComparison]::Ordinal)) {
                $recoverySequenceOrdered = $false
                break
            }
        }
    }
    $recoveryFourStepPlanObserved = $recoveryRequiredStagesObserved -and
        $recoveryStepNumbers.Count -eq 4 -and
        @(Compare-Object -ReferenceObject @(1, 2, 3, 4) -DifferenceObject $recoveryStepNumbers).Count -eq 0 -and
        $recoverySequenceOrdered
    $passed = $genericPassed -and (-not $RequireRecoveryProgress -or $recoveryFourStepPlanObserved)
    return [pscustomobject][ordered]@{
        RawSampleCount = [int]$Audit.RawSampleCount
        ProgressBarObserved = [bool]$Audit.ProgressBarObserved
        IndeterminateStyleObserved = [bool]$Audit.IndeterminateStyleObserved
        ProgressRangeObserved = [bool]$Audit.ProgressRangeObserved
        InvalidProgressRangeObserved = [bool]$Audit.InvalidProgressRangeObserved
        ProgressRangeValid = $progressRangeValid
        ObservedPositions = $observedPositions
        DistinctPositionCount = $observedPositions.Count
        PositionIncreaseObserved = [bool]$Audit.PositionIncreaseObserved
        RecoveryProgressBaselineReset = [bool]$Audit.RecoveryProgressBaselineReset
        ProgressAdvanced = $progressAdvanced
        AmbiguousLabels = $ambiguousLabels
        GenericStatusLabels = $genericStatusLabels
        ExplicitStageLabels = $explicitStageLabels
        ExplicitStageKinds = $explicitStageKinds
        ExplicitStageLabelCount = $explicitStageLabels.Count
        ExplicitStageKindCount = $explicitStageKinds.Count
        ExplicitStagesObserved = $explicitStagesObserved
        RecoveryRequiredStages = $recoveryRequiredStages
        RecoveryObservedStages = $recoveryObservedStages
        RecoveryRequiredStagesObserved = $recoveryRequiredStagesObserved
        RecoveryStepNumbers = $recoveryStepNumbers
        RecoveryTransitionSteps = $recoveryTransitionSteps
        RecoveryTransitionStages = $recoveryTransitionStages
        RecoverySequenceValid = [bool]$Audit.RecoverySequenceValid
        RecoverySequenceOrdered = $recoverySequenceOrdered
        RecoveryFourStepPlanObserved = $recoveryFourStepPlanObserved
        SamplesTruncated = [bool]$Audit.SamplesTruncated
        Samples = @($Audit.Samples | ForEach-Object { $_ })
        Passed = $passed
    }
}

function Save-LauncherProgressAudit([Collections.IDictionary]$Manual,
    [Diagnostics.Process]$Launcher, [Collections.IDictionary]$Audit) {
    if ($null -eq $Audit -or $null -eq $Manual['Launcher']) { return }
    if ($null -ne $Launcher) { Add-LauncherProgressSample $Launcher $Audit }
    $Manual['Launcher']['Progress'] = Complete-LauncherProgressAudit $Audit
}

function Save-SelfRepairRuntimeEvidence([Collections.IDictionary]$Manual,
    [object]$Expected, [hashtable]$Attempts,
    [Collections.IDictionary]$RecoveryProgressAudit) {
    $selfRepair = $Manual['SelfRepair']
    if ($null -eq $selfRepair) { return }
    if ($null -ne $Expected) {
        $selfRepair['ExecutionImage'] = Get-ExecutionImageAudit $Expected
    }
    if ($null -ne $Attempts -and $null -ne $Expected) {
        $observed = @(
            $Attempts.Values |
                Sort-Object { [int]$_.ObservationOrdinal } |
                ForEach-Object { ConvertTo-ExecutionAttemptEvidence $_ $Expected }
        )
        $selfRepair['ObservedRootAttempts'] = $observed
        $selfRepair['ObservedRootAttemptCount'] = $observed.Count
        $selfRepair['RetryCount'] = [Math]::Max(0, $observed.Count - 1)
        $initialAttempt = $selfRepair['InitialAttempt']
        $retryAttempt = $selfRepair['RetryAttempt']
        $selfRepair['PollingExactlyOneRetry'] = $observed.Count -eq 2 -and
            $null -ne $initialAttempt -and $null -ne $retryAttempt -and
            -not [string]::Equals([string]$initialAttempt.AttemptKey,
                [string]$retryAttempt.AttemptKey, [StringComparison]::Ordinal)
    }
    if ($null -ne $RecoveryProgressAudit) {
        $selfRepair['RecoveryProgress'] = Complete-LauncherProgressAudit $RecoveryProgressAudit $true
    }
}

function Save-PostHandoffRecoveryRuntimeEvidence([Collections.IDictionary]$Manual,
    [object]$Expected, [hashtable]$Attempts,
    [Collections.IDictionary]$ProgressAudit) {
    $selfRepair = $Manual['SelfRepair']
    if ($null -eq $selfRepair) { return }
    $postHandoff = $selfRepair['PostHandoffRecovery']
    if ($null -eq $postHandoff) { return }
    $manualRestart = $postHandoff['ManualRestart']
    if ($null -eq $manualRestart) { return }

    if ($null -ne $Expected) {
        $manualRestart['ExecutionImage'] = Get-ExecutionImageAudit $Expected
    }
    if ($null -ne $Attempts -and $null -ne $Expected) {
        $observed = @(
            $Attempts.Values |
                Sort-Object { [int]$_.ObservationOrdinal } |
                ForEach-Object { ConvertTo-ExecutionAttemptEvidence $_ $Expected }
        )
        $manualRestart['ObservedRootAttempts'] = $observed
        $manualRestart['ObservedRootAttemptCount'] = $observed.Count
        $manualRestart['PollingExactlyOneRootAttempt'] = $observed.Count -eq 1
    }
    if ($null -ne $ProgressAudit) {
        $manualRestart['Progress'] = Complete-LauncherProgressAudit $ProgressAudit
    }
}

function Get-ManualStartFailureDiagnostics([string]$Root,
    [Diagnostics.Process]$Launcher, [string[]]$Secrets) {
    $collectionErrors = New-Object 'System.Collections.Generic.List[string]'
    $targetProcesses = @()
    $appCurrentProcesses = @()
    $namedDesktopProcesses = @()
    $launcherWindows = @()
    $launcherLogTail = $null
    $pluginCacheAudit = $null

    try { $targetProcesses = Get-ProcessSnapshot @(Get-TargetProcesses $Root) }
    catch {
        $collectionErrors.Add('TargetProcesses: ' +
            (Protect-DiagnosticText $_.Exception.Message $Secrets))
    }
    try { $appCurrentProcesses = Get-ProcessSnapshot @(Get-TargetAppCurrentProcesses $Root) }
    catch {
        $collectionErrors.Add('AppCurrentProcesses: ' +
            (Protect-DiagnosticText $_.Exception.Message $Secrets))
    }
    try { $namedDesktopProcesses = Get-ProcessSnapshot @(Get-TargetDesktopProcesses $Root) }
    catch {
        $collectionErrors.Add('NamedDesktopProcesses: ' +
            (Protect-DiagnosticText $_.Exception.Message $Secrets))
    }
    try { $launcherWindows = Get-LauncherWindowSnapshot $Launcher $Secrets }
    catch {
        $collectionErrors.Add('LauncherWindows: ' +
            (Protect-DiagnosticText $_.Exception.Message $Secrets))
    }
    try { $launcherLogTail = Get-SanitizedLauncherLogTail $Root $Secrets }
    catch {
        $collectionErrors.Add('LauncherLogTail: ' +
            (Protect-DiagnosticText $_.Exception.Message $Secrets))
    }
    try {
        $pluginCacheAudit = Get-InstalledPluginAudit (
            Join-Path $Root 'CodexData\data\profile\.codex\plugins\cache')
    }
    catch {
        $collectionErrors.Add('PluginCacheAudit: ' +
            (Protect-DiagnosticText $_.Exception.Message $Secrets))
    }

    return [pscustomobject][ordered]@{
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
        TargetProcesses = @($targetProcesses)
        AppCurrentProcesses = @($appCurrentProcesses)
        NamedDesktopProcesses = @($namedDesktopProcesses)
        LauncherWindows = @($launcherWindows)
        LauncherLogTail = $launcherLogTail
        PluginCacheAudit = $pluginCacheAudit
        CollectionErrors = @($collectionErrors)
    }
}

function Invoke-ManualStart([string]$Root, [object]$Manifest) {
    $manual = [ordered]@{
        Executed = $true
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        Passed = $false
        Error = $null
        ZeroState = $null
        EphemeralApiConfiguration = $null
        Launcher = $null
        InitialConfig = $null
        SelfRepair = [ordered]@{
            Required = $true
            Architecture = 'x64'
            InitialExecutionImageAbsent = $false
            InitialAttempt = $null
            Injection = [ordered]@{
                Attempted = $false
                Method = 'TerminateProcess'
                RequestedExitCode = '0xC0000006'
                TargetProcessId = $null
                TerminateProcessSucceeded = $false
                ProcessExited = $false
                ObservedExitCode = $null
                ObservedExitCodeMatches = $false
            }
            RetryAttempt = $null
            ObservedRootAttempts = @()
            ObservedRootAttemptCount = 0
            RetryCount = 0
            PollingExactlyOneRetry = $false
            TraceExactlyOneRetry = $false
            ExactlyOneRetry = $false
            EarlyStartupDesktopFromExpectedLocalExecutionImage = $false
            EarlyStartupPassed = $false
            FinalDesktopFromExpectedLocalExecutionImage = $false
            ExecutionImage = $null
            RecoveryProgress = $null
            ManagedRelease = [ordered]@{
                ManifestFileCount = 10
                AfterCopy = $null
                BeforeLateFault = $null
                AfterLateWatchdog = $null
                BeforeNormalExit = @()
                AfterNormalExit = @()
                NormalExitComparison = $null
                AllMatchManifest = $false
                AllIdentical = $false
            }
            ProcessStartTrace = [ordered]@{
                Required = $true
                Provider = 'System.Management.ManagementEventWatcher'
                EventClass = 'Win32_ProcessStartTrace'
                Query = 'SELECT * FROM Win32_ProcessStartTrace'
                Available = $false
                SessionId = $null
                SubscriptionStartedUtc = $null
                StartProbe = $null
                EndProbe = $null
                FirstLaunch = $null
                LateFaultWindow = $null
                ManualLaunch = $null
                FinalAudit = $null
                RelevantEvents = @()
                Healthy = $false
                Passed = $false
            }
            NormalExitControl = [ordered]@{
                Required = $true
                Method = 'TerminateProcess'
                RequestedExitCode = '0x00000000'
                TargetProcessId = $null
                Attempted = $false
                TerminateProcessSucceeded = $false
                ProcessExited = $false
                ObservedExitCode = $null
                ObservedExitCodeMatches = $false
                TraceCursor = $null
                NewCodexStartEvents = @()
                NoAutomaticRestart = $false
                RecoveryHelper = $null
                RecoveryHelperExited = $false
                RecoveryHelperExitCode = $null
                RecoveryHelperExitCodeMatches = $false
                Probe = [ordered]@{
                    RelativePath = '.lf-sandbox-normal-exit-preservation-probe'
                    Path = $null
                    Sha256 = $null
                    Created = $false
                    Preserved = $false
                }
                VersionRootPreserved = $false
                NoExecutionDesktopProcesses = $false
                ExecutionImage = $null
                ManagedFilesUnchanged = $false
                Passed = $false
            }
            PostHandoffRecovery = [ordered]@{
                Required = $true
                StartupConfirmationWindowMilliseconds = 9000
                MinimumDelayMilliseconds = 10000
                ActualDelayMilliseconds = 0
                RetryAliveBeforeInjection = $false
                Probe = [ordered]@{
                    RelativePath = '.lf-sandbox-post-handoff-recovery-probe'
                    Path = $null
                    Created = $false
                    RemovedByWatchdog = $false
                    AbsentAfterManualRestart = $false
                }
                ManagedFiles = [ordered]@{
                    BeforeFault = @()
                    AfterWatchdog = @()
                    Comparison = $null
                }
                KnownExecutionDesktopProcessIds = @()
                Injection = [ordered]@{
                    Attempted = $false
                    Method = 'TerminateProcess'
                    RequestedExitCode = '0xC0000006'
                    TargetProcessId = $null
                    TerminateProcessSucceeded = $false
                    ProcessExited = $false
                    ObservedExitCode = $null
                    ObservedExitCodeMatches = $false
                }
                Watchdog = [ordered]@{
                    AutomaticRestartProcessIds = @()
                    AutomaticRestartObserved = $false
                    TraceAutomaticRestartEvents = @()
                    TraceNoAutomaticRestart = $false
                    RecoveryHelper = $null
                    ArmedAndAvailableAfterHandoff = $false
                    RecoveryHelperExited = $false
                    RecoveryHelperExitCode = $null
                    RecoveryHelperExitCodeMatches = $false
                    VersionRootDeleted = $false
                    NoExecutionDesktopProcesses = $false
                    ExecutionImageReappearedBeforeManualAction = $false
                    ObservedDesktopProcessIds = @()
                    CompletedUtc = $null
                }
                ManualRestart = [ordered]@{
                    BootstrapperProcessId = $null
                    CoreLauncherProcessId = $null
                    WindowTitle = $null
                    StartButtonLabel = $null
                    ActualButtonClicked = $false
                    PreClickExecutionDesktopProcessCount = $null
                    RootAttempt = $null
                    ObservedRootAttempts = @()
                    ObservedRootAttemptCount = 0
                    PollingExactlyOneRootAttempt = $false
                    TraceExactlyOneRootAttempt = $false
                    ExactlyOneRootAttempt = $false
                    TraceRootSequence = $null
                    RecoveryHelper = $null
                    MainWindowObserved = $false
                    WindowTitleAfterStart = $null
                    LauncherExitedAfterHandoff = $false
                    Progress = $null
                    ExecutionImage = $null
                }
                Passed = $false
            }
            Passed = $false
        }
        DerivedState = $null
        FailureDiagnostics = $null
        Cleanup = $null
    }
    $progressAudit = $null
    $recoveryProgressAudit = $null
    $postHandoffProgressAudit = $null
    $launcher = $null
    $launcherStartUtc = $null
    $postHandoffLauncher = $null
    $diagnosticLauncher = $null
    $ephemeralApiKey = $null
    $executionExpectation = $null
    $managedFileContract = $null
    $executionAttempts = @{}
    $postHandoffAttempts = @{}
    $processStartTrace = $null
    $traceSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $firstStartTraceCursor = 0
    $lateFaultTraceCursor = 0
    $manualStartTraceCursor = 0
    $lateRecoveryHelper = $null
    $finalRecoveryHelper = $null
    $initialRoot = $null
    $retryRoot = $null
    $finalDesktopRoot = $null
    $initialRootExitHandle = [IntPtr]::Zero
    $retryRootExitHandle = [IntPtr]::Zero
    $finalDesktopExitHandle = [IntPtr]::Zero
    try {
        $copyEvidence = Copy-CompactRelease $SourceRoot $Root $Manifest
        $managedFileContract = Get-ManagedFileManifestContract $Manifest
        $copyExitCode = [int]$copyEvidence.RobocopyExitCode
        $manual.SelfRepair.ManagedRelease.AfterCopy = $copyEvidence.ManagedFiles
        $manual.SelfRepair.ManagedRelease.AllMatchManifest = [bool]$copyEvidence.ManagedFiles.MatchesManifest
        if (-not $manual.SelfRepair.ManagedRelease.AllMatchManifest) {
            throw 'Manual-start managed-file copy evidence does not bind every file to the release manifest.'
        }
        $executionExpectation = Get-ExecutionImageExpectation $Root $Manifest
        $initialExecutionImage = Get-ExecutionImageAudit $executionExpectation
        $manual.SelfRepair.InitialExecutionImageAbsent = -not (Test-Path -LiteralPath $executionExpectation.VersionRoot)
        $manual.SelfRepair.ExecutionImage = $initialExecutionImage
        $dataRoot = Join-Path $Root 'CodexData\data'
        $configRoot = Join-Path $dataRoot 'config'
        $secretsRoot = Join-Path $dataRoot 'secrets'
        $configToml = Join-Path $dataRoot 'profile\.codex\config.toml'
        $globalStatePath = Join-Path $dataRoot 'profile\.codex\.codex-global-state.json'
        $globalStateBackupPath = $globalStatePath + '.bak'
        $payloadRoot = Join-Path $Root 'CodexData\app\current'
        $runtimeCacheRoot = Join-Path $dataRoot 'profile\.cache\codex-runtimes'
        $pluginCacheRoot = Join-Path $dataRoot 'profile\.codex\plugins\cache'
        $zeroState = [ordered]@{
            CopyRobocopyExitCode = $copyExitCode
            CopiedManagedFileCount = [int]$copyEvidence.ManagedFiles.FileCount
            CopiedManagedFilesMatchManifest = [bool]$copyEvidence.ManagedFiles.MatchesManifest
            CopiedManagedFiles = @($copyEvidence.ManagedFiles.Files)
            ConfigTomlExists = Test-Path -LiteralPath $configToml
            GlobalStateExists = Test-Path -LiteralPath $globalStatePath
            GlobalStateBackupExists = Test-Path -LiteralPath $globalStateBackupPath
            ExpandedPayloadExists = Test-Path -LiteralPath $payloadRoot
            RuntimeCacheExists = Test-Path -LiteralPath $runtimeCacheRoot
            PluginCacheExists = Test-Path -LiteralPath $pluginCacheRoot
            ExpectedLocalExecutionImage = $executionExpectation.VersionRoot
            InitialLocalExecutionImageAbsent = $manual.SelfRepair.InitialExecutionImageAbsent
            FirstManagedExecutableAction = 'Start CodexPortable.exe only after manifest-bound copy validation and trace readiness'
        }
        # Persist the pre-start snapshot even on a failure so the exported
        # proof identifies whether a runtime or plugin cache contaminated the
        # supposedly fresh manual-start target.
        $manual.ZeroState = $zeroState
        if ($zeroState.ConfigTomlExists -or $zeroState.GlobalStateExists -or
            $zeroState.GlobalStateBackupExists -or $zeroState.ExpandedPayloadExists -or
            $zeroState.RuntimeCacheExists -or $zeroState.PluginCacheExists) {
            throw 'Manual-start target was not zero-state before the first launcher action.'
        }
        if (-not $manual.SelfRepair.InitialExecutionImageAbsent) {
            throw 'The expected local execution image existed before the first manual-start launcher action.'
        }

        # Preconfigure a disposable local endpoint so the actual Start Codex
        # click can reach the desktop startup path without any network access.
        $utf8 = New-Object Text.UTF8Encoding($false)
        New-Item -ItemType Directory -Path $configRoot, $secretsRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $configRoot 'custom-api-url.txt'), "http://127.0.0.1:9`r`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $configRoot 'custom-model.txt'), "sandbox-local-probe`r`n", $utf8)
        $ephemeralApiKey = 'sandbox-' + [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText((Join-Path $secretsRoot 'api-key.txt'), ($ephemeralApiKey + "`r`n"), $utf8)
        $manual.EphemeralApiConfiguration = [ordered]@{
            BaseUrl = 'http://127.0.0.1:9'
            Model = 'sandbox-local-probe'
            ApiKeyWritten = $true
            KeyValueRecorded = $false
            NetworkDisabledBySandbox = $true
        }

        $processStartTrace = Start-MandatoryProcessStartTrace
        $manual.SelfRepair.ProcessStartTrace.Available = $true
        $manual.SelfRepair.ProcessStartTrace.SessionId = $traceSessionId
        $manual.SelfRepair.ProcessStartTrace.SubscriptionStartedUtc = [DateTime]::UtcNow.ToString('o')
        $manual.SelfRepair.ProcessStartTrace.StartProbe = Invoke-MandatoryProcessStartTraceProbe `
            $processStartTrace $traceSessionId 'start-of-test readiness'

        $bootstrapper = Join-Path $Root 'CodexPortable.exe'
        $bootstrap = Start-Process -FilePath $bootstrapper -WorkingDirectory $Root -PassThru
        $launcher = Wait-Until {
            @(Get-TargetProcesses $Root | Where-Object {
                try { $_.Path.StartsWith((Join-Path $Root 'CodexData\tools\launchers').TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and $_.MainWindowHandle -ne [IntPtr]::Zero }
                catch { $false }
            } | Select-Object -First 1)
        } 180 'the manual-start LF launcher window'
        $launcher.Refresh()
        $launcherStartUtc = $launcher.StartTime.ToUniversalTime().ToString('o')
        $initialConfigText = Wait-Until {
            if (-not (Test-Path -LiteralPath $configToml -PathType Leaf)) { return $false }
            $text = Get-Content -LiteralPath $configToml -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($text)) { return $false }
            return $text
        } 120 'the initial launcher-generated config.toml'
        $initialFollowUpQueueMode = Get-DesktopFollowUpQueueMode $initialConfigText
        if (-not $initialFollowUpQueueMode.Valid) {
            throw 'Initial launcher-generated config.toml does not contain desktop.followUpQueueMode = steer.'
        }
        $manual.InitialConfig = [ordered]@{
            FollowUpQueueMode = $initialFollowUpQueueMode.Value
            FollowUpQueueModeValid = $initialFollowUpQueueMode.Valid
        }
        $firstStartTraceCursor = Wait-ForMandatoryProcessStartTraceQuiescence `
            $processStartTrace 750 20
        $clickedLabel = Wait-Until {
            [LfSandboxStartButtonProbe]::ClickStartCodexButton($launcher.MainWindowHandle)
        } 120 'the actual Start Codex button'
        $manual.Launcher = [ordered]@{
            BootstrapperProcessId = $bootstrap.Id
            CoreProcessId = $launcher.Id
            WindowTitle = $launcher.MainWindowTitle
            StartButtonLabel = $clickedLabel
            ActualButtonClicked = $true
        }
        $progressAudit = New-LauncherProgressAudit
        $manual['Launcher']['Progress'] = Complete-LauncherProgressAudit $progressAudit
        Add-LauncherProgressSample $launcher $progressAudit

        $initialRoot = Wait-ForExecutionDesktopRoot $Root $executionExpectation $launcher.Id 0 $null `
            $TimeoutSeconds 'the first local execution-image Codex Desktop root process' `
            $launcher $progressAudit $null $executionAttempts
        $initialTraceRecord = Wait-ForMandatoryProcessStartTraceRecord $processStartTrace `
            $initialRoot.ProcessId $launcher.Id $traceSessionId 'CodexDesktop.exe' `
            $firstStartTraceCursor 20 'the initial Codex Desktop root'
        $manual.SelfRepair.InitialAttempt = ConvertTo-ExecutionAttemptEvidence `
            $executionAttempts[[string]$initialRoot.AttemptKey] $executionExpectation $initialTraceRecord
        if (-not $manual.SelfRepair.InitialAttempt.IsExecutionImagePath -or
            -not $manual.SelfRepair.InitialAttempt.MatchesExpectedExecutionPath) {
            throw 'The first Codex Desktop root process did not use the expected local execution image.'
        }

        $recoveryProgressAudit = New-LauncherProgressAudit
        $manual.SelfRepair.RecoveryProgress = Complete-LauncherProgressAudit $recoveryProgressAudit $true
        Initialize-SandboxProcessTerminator
        [uint32]$requestedExitCode = [Convert]::ToUInt32('C0000006', 16)
        $manual.SelfRepair.Injection.TargetProcessId = $initialRoot.ProcessId
        $manual.SelfRepair.Injection.Attempted = $true
        $initialRootExitHandle = $initialRoot.ExitHandle
        try {
            [LfSandboxProcessTerminator]::TerminateWithExitCode($initialRootExitHandle, $requestedExitCode)
            $manual.SelfRepair.Injection.TerminateProcessSucceeded = $true
            $exitEvidence = Wait-ForCapturedProcessExit $initialRoot.ProcessId $initialRootExitHandle 30 `
                'the injected first Codex Desktop root process to exit' $launcher `
                $progressAudit $recoveryProgressAudit
        }
        finally {
            Close-SandboxNativeProcessHandle $initialRoot.ExitHandle
            $initialRoot.ExitHandle = [IntPtr]::Zero
            $initialRootExitHandle = [IntPtr]::Zero
        }
        $manual.SelfRepair.Injection.ProcessExited = $exitEvidence.ProcessExited
        $manual.SelfRepair.Injection.ObservedExitCode = $exitEvidence.ObservedExitCode
        $manual.SelfRepair.Injection.ObservedExitCodeMatches = [string]::Equals(
            [string]$exitEvidence.ObservedExitCode,
            [string]$manual.SelfRepair.Injection.RequestedExitCode,
            [StringComparison]::Ordinal)
        if (-not $manual.SelfRepair.Injection.ObservedExitCodeMatches) {
            throw 'The injected first Codex Desktop process did not expose exit code 0xC0000006.'
        }

        $retryRoot = Wait-ForExecutionDesktopRoot $Root $executionExpectation $launcher.Id `
            $initialRoot.ProcessId $initialRoot.ProcessStartUtc $TimeoutSeconds `
            'the single repaired Codex Desktop retry root process' `
            $launcher $progressAudit $recoveryProgressAudit $executionAttempts
        $retryTraceRecord = Wait-ForMandatoryProcessStartTraceRecord $processStartTrace `
            $retryRoot.ProcessId $launcher.Id $traceSessionId 'CodexDesktop.exe' `
            ([int]$initialTraceRecord.EventOrdinal) 20 'the repaired Codex Desktop retry root'
        $manual.SelfRepair.RetryAttempt = ConvertTo-ExecutionAttemptEvidence `
            $executionAttempts[[string]$retryRoot.AttemptKey] $executionExpectation $retryTraceRecord
        if (-not $manual.SelfRepair.RetryAttempt.IsExecutionImagePath -or
            -not $manual.SelfRepair.RetryAttempt.MatchesExpectedExecutionPath -or
            [string]::Equals([string]$manual.SelfRepair.RetryAttempt.AttemptKey,
                [string]$manual.SelfRepair.InitialAttempt.AttemptKey,
                [StringComparison]::Ordinal) -or
            [int]$manual.SelfRepair.RetryAttempt.TraceEventOrdinal -eq
                [int]$manual.SelfRepair.InitialAttempt.TraceEventOrdinal) {
            throw 'The repaired Codex Desktop retry did not use a distinct root process from the expected local execution image.'
        }

        $desktopWindow = Wait-ForExecutionDesktopMainWindow $Root $executionExpectation `
            $retryRoot $launcher.Id 180 $launcher $progressAudit $recoveryProgressAudit $executionAttempts
        $finalDesktopMainWindowObserved = $desktopWindow.MainWindowHandle -ne [IntPtr]::Zero
        $launcherExitedAfterRetry = Wait-ForExecutionDesktopHandoff `
            $Root $executionExpectation $launcher.Id 20 $launcher $progressAudit `
            $recoveryProgressAudit $executionAttempts
        if (-not $launcherExitedAfterRetry) {
            throw 'The launcher did not complete the retried Codex Desktop handoff.'
        }

        $firstLaunchTrace = Assert-DirectDesktopProcessStartTraceSequence $processStartTrace `
            $traceSessionId $firstStartTraceCursor $launcher.Id `
            @($initialRoot.ProcessId, $retryRoot.ProcessId) 'The early self-repair launch'
        $manual.SelfRepair.ProcessStartTrace.FirstLaunch = $firstLaunchTrace
        $manual.SelfRepair.TraceExactlyOneRetry = [bool]$firstLaunchTrace.ExactSequence
        $manual.SelfRepair.ExactlyOneRetry = $manual.SelfRepair.TraceExactlyOneRetry

        Save-SelfRepairRuntimeEvidence $manual $executionExpectation $executionAttempts $recoveryProgressAudit
        try {
            $retryRoot.Process.Refresh()
            $earlyStartupDesktopAlive = -not $retryRoot.Process.HasExited
        }
        catch { $earlyStartupDesktopAlive = $false }
        $manual.SelfRepair.EarlyStartupDesktopFromExpectedLocalExecutionImage = $earlyStartupDesktopAlive -and
            $finalDesktopMainWindowObserved -and
            $manual.SelfRepair.RetryAttempt.MatchesExpectedExecutionPath
        $manual.SelfRepair.EarlyStartupPassed = $manual.SelfRepair.InitialExecutionImageAbsent -and
            $manual.SelfRepair.InitialAttempt.MatchesExpectedExecutionPath -and
            $manual.SelfRepair.Injection.Attempted -and
            $manual.SelfRepair.Injection.TerminateProcessSucceeded -and
            $manual.SelfRepair.Injection.ProcessExited -and
            $manual.SelfRepair.Injection.ObservedExitCodeMatches -and
            $manual.SelfRepair.RetryAttempt.MatchesExpectedExecutionPath -and
            $manual.SelfRepair.ExactlyOneRetry -and
            $manual.SelfRepair.EarlyStartupDesktopFromExpectedLocalExecutionImage -and
            $manual.SelfRepair.ExecutionImage.Valid -and
            $manual.SelfRepair.RecoveryProgress.Passed -and
            $launcherExitedAfterRetry
        if (-not $manual.SelfRepair.EarlyStartupPassed) {
            throw 'The local execution-image self-repair proof did not satisfy its deterministic retry contract.'
        }

        Add-LauncherProgressSample $launcher $progressAudit
        Save-LauncherProgressAudit $manual $launcher $progressAudit
        if (-not $manual.Launcher.Progress.Passed) {
            throw 'The post-click launcher progress UI did not satisfy the determinate, explicit-status contract.'
        }

        # The launcher has detached after the 9-second confirmation window. A
        # later mapped-image failure must leave the USB-managed release alone,
        # remove only the local execution image, and wait for a future user
        # Start Codex click instead of relaunching Desktop by itself.
        $postHandoff = $manual.SelfRepair.PostHandoffRecovery
        # Commit blocks until the helper sets its armed acknowledgement. Seeing
        # this trace-bound helper alive after its launcher exited therefore
        # proves that late-fault ownership survived the UI handoff.
        $lateRecoveryHelper = Get-RecoveryHelperProcessStartTrace $processStartTrace `
            $traceSessionId $firstStartTraceCursor $launcher.Id $Root
        $postHandoff.Watchdog.RecoveryHelper = $lateRecoveryHelper.Evidence
        try {
            $lateRecoveryHelper.Process.Refresh()
            $lateRecoveryHelperAlive = -not $lateRecoveryHelper.Process.HasExited
        }
        catch { $lateRecoveryHelperAlive = $false }
        $postHandoff.Watchdog.ArmedAndAvailableAfterHandoff = $launcherExitedAfterRetry -and
            $lateRecoveryHelperAlive -and $lateRecoveryHelper.Evidence.TraceBound -and
            $lateRecoveryHelper.Evidence.FixedLocalScratchPath -and
            $lateRecoveryHelper.Evidence.ParentProcessId -eq $launcher.Id
        if (-not $postHandoff.Watchdog.ArmedAndAvailableAfterHandoff) {
            throw 'The trace-bound LF recovery helper was not armed and available after launcher handoff.'
        }
        $postHandoff.ActualDelayMilliseconds = Wait-ForPostHandoffDelay $retryRoot `
            ([int]$postHandoff.MinimumDelayMilliseconds)
        try {
            $retryRoot.Process.Refresh()
            $postHandoff.RetryAliveBeforeInjection = -not $retryRoot.Process.HasExited
        }
        catch { $postHandoff.RetryAliveBeforeInjection = $false }
        if (-not $postHandoff.RetryAliveBeforeInjection) {
            throw 'The repaired Codex Desktop root did not remain alive for the post-handoff fault injection.'
        }

        if (-not (Test-Path -LiteralPath $executionExpectation.VersionRoot -PathType Container)) {
            throw 'The expected local execution image disappeared before the post-handoff fault injection.'
        }
        $postHandoff.Probe.Path = Join-Path $executionExpectation.VersionRoot $postHandoff.Probe.RelativePath
        [IO.File]::WriteAllText($postHandoff.Probe.Path,
            'LF Sandbox post-handoff local execution-image recovery probe', $utf8)
        $postHandoff.Probe.Created = Test-Path -LiteralPath $postHandoff.Probe.Path -PathType Leaf
        if (-not $postHandoff.Probe.Created) {
            throw 'Sandbox could not create the post-handoff local execution-image probe.'
        }

        $managedReleaseBeforeFault = Get-ManifestBoundManagedFileSnapshot $Root $managedFileContract
        $manual.SelfRepair.ManagedRelease.BeforeLateFault = $managedReleaseBeforeFault
        if (-not $managedReleaseBeforeFault.MatchesManifest) {
            throw 'Managed portable-release files changed before the post-handoff fault injection.'
        }
        $managedFilesBeforeFault = Get-ManagedFileHashSnapshot $Root
        $postHandoff.ManagedFiles.BeforeFault = ConvertTo-ManagedFileHashEvidence $managedFilesBeforeFault
        $knownExecutionDesktopRecords = @(Get-ExecutionDesktopProcessRecords $Root)
        $knownExecutionDesktopProcessIds = @(
            $knownExecutionDesktopRecords | Select-Object -ExpandProperty ProcessId | Sort-Object -Unique
        )
        $postHandoff.KnownExecutionDesktopProcessIds = $knownExecutionDesktopProcessIds
        if ($knownExecutionDesktopProcessIds.Count -eq 0 -or
            $knownExecutionDesktopProcessIds -notcontains $retryRoot.ProcessId) {
            throw 'Sandbox could not establish the live local execution-image process family before the post-handoff fault injection.'
        }

        $lateFaultTraceCursor = Wait-ForMandatoryProcessStartTraceQuiescence `
            $processStartTrace 750 20
        $manual.SelfRepair.ProcessStartTrace.LateFaultWindow = [ordered]@{
            Cursor = $lateFaultTraceCursor
            UnexpectedCodexStarts = @()
            NoAutomaticRestart = $false
        }
        $postHandoff.Injection.TargetProcessId = $retryRoot.ProcessId
        $postHandoff.Injection.Attempted = $true
        $retryRootExitHandle = $retryRoot.ExitHandle
        try {
            [LfSandboxProcessTerminator]::TerminateWithExitCode($retryRootExitHandle, $requestedExitCode)
            $postHandoff.Injection.TerminateProcessSucceeded = $true
            $postHandoffExitEvidence = Wait-ForCapturedProcessExit $retryRoot.ProcessId $retryRootExitHandle 30 `
                'the post-handoff injected Codex Desktop root process to exit' $null $null $null
        }
        finally {
            Close-SandboxNativeProcessHandle $retryRoot.ExitHandle
            $retryRoot.ExitHandle = [IntPtr]::Zero
            $retryRootExitHandle = [IntPtr]::Zero
        }
        $postHandoff.Injection.ProcessExited = $postHandoffExitEvidence.ProcessExited
        $postHandoff.Injection.ObservedExitCode = $postHandoffExitEvidence.ObservedExitCode
        $postHandoff.Injection.ObservedExitCodeMatches = [string]::Equals(
            [string]$postHandoffExitEvidence.ObservedExitCode,
            [string]$postHandoff.Injection.RequestedExitCode,
            [StringComparison]::Ordinal)
        if (-not $postHandoff.Injection.ObservedExitCodeMatches) {
            throw 'The post-handoff injected Codex Desktop root did not expose exit code 0xC0000006.'
        }

        $automaticRestartProcessIds = New-Object 'System.Collections.Generic.List[int]'
        $watchdogEvidence = $null
        try {
            $watchdogEvidence = Wait-ForPostHandoffExecutionImageInvalidation $Root `
                $executionExpectation $knownExecutionDesktopProcessIds 210 $automaticRestartProcessIds `
                $lateRecoveryHelper
        }
        finally {
            $postHandoff.Watchdog.AutomaticRestartProcessIds = @($automaticRestartProcessIds | Sort-Object)
            $postHandoff.Watchdog.AutomaticRestartObserved = $automaticRestartProcessIds.Count -ne 0
        }
        $postHandoff.Watchdog.VersionRootDeleted = $watchdogEvidence.VersionRootDeleted
        $postHandoff.Watchdog.NoExecutionDesktopProcesses = $watchdogEvidence.NoExecutionDesktopProcesses
        $postHandoff.Watchdog.ObservedDesktopProcessIds = @($watchdogEvidence.ObservedDesktopProcessIds)
        $postHandoff.Watchdog.CompletedUtc = $watchdogEvidence.CompletedUtc
        $lateHelperExit = Wait-ForTraceBoundProcessExit $lateRecoveryHelper.Process `
            $lateRecoveryHelper.ExitHandle 30 `
            'the late-fault LF recovery helper'
        Close-SandboxNativeProcessHandle $lateRecoveryHelper.ExitHandle
        $lateRecoveryHelper.ExitHandle = [IntPtr]::Zero
        $postHandoff.Watchdog.RecoveryHelperExited = $lateHelperExit.ProcessExited
        $postHandoff.Watchdog.RecoveryHelperExitCode = $lateHelperExit.ObservedExitCode
        $postHandoff.Watchdog.RecoveryHelperExitCodeMatches = [string]::Equals(
            [string]$lateHelperExit.ObservedExitCode, '0x00000000', [StringComparison]::Ordinal)
        $postHandoff.Probe.RemovedByWatchdog = -not (Test-Path -LiteralPath $postHandoff.Probe.Path -PathType Leaf)
        if (-not $postHandoff.Watchdog.VersionRootDeleted -or
            -not $postHandoff.Watchdog.NoExecutionDesktopProcesses -or
            $postHandoff.Watchdog.AutomaticRestartObserved -or
            -not $postHandoff.Watchdog.RecoveryHelperExited -or
            -not $postHandoff.Watchdog.RecoveryHelperExitCodeMatches -or
            -not $postHandoff.Probe.RemovedByWatchdog) {
            throw 'Post-handoff watchdog recovery did not clean only the local execution image before a user restart.'
        }

        $lateFaultTraceEvents = @(Get-DesktopProcessStartTraceRecords $processStartTrace `
                $traceSessionId $lateFaultTraceCursor | ForEach-Object {
                ConvertTo-ProcessStartTraceEvidence $_
            })
        $postHandoff.Watchdog.TraceAutomaticRestartEvents = $lateFaultTraceEvents
        $postHandoff.Watchdog.TraceNoAutomaticRestart = $lateFaultTraceEvents.Count -eq 0
        $manual.SelfRepair.ProcessStartTrace.LateFaultWindow.UnexpectedCodexStarts = $lateFaultTraceEvents
        $manual.SelfRepair.ProcessStartTrace.LateFaultWindow.NoAutomaticRestart =
            $postHandoff.Watchdog.TraceNoAutomaticRestart
        if (-not $postHandoff.Watchdog.TraceNoAutomaticRestart) {
            throw 'Win32_ProcessStartTrace observed a CodexDesktop automatic launch after late watchdog recovery.'
        }

        $managedReleaseAfterWatchdog = Get-ManifestBoundManagedFileSnapshot $Root $managedFileContract
        $manual.SelfRepair.ManagedRelease.AfterLateWatchdog = $managedReleaseAfterWatchdog
        if (-not $managedReleaseAfterWatchdog.MatchesManifest -or
            -not (Compare-ManifestBoundManagedFileSnapshots $managedReleaseBeforeFault `
                    $managedReleaseAfterWatchdog).Unchanged) {
            throw 'Post-handoff watchdog recovery changed manifest-bound managed-file metadata.'
        }
        $managedFilesAfterWatchdog = Get-ManagedFileHashSnapshot $Root
        $postHandoff.ManagedFiles.AfterWatchdog = ConvertTo-ManagedFileHashEvidence $managedFilesAfterWatchdog
        $postHandoff.ManagedFiles.Comparison = Compare-ManagedFileHashSnapshots `
            $managedFilesBeforeFault $managedFilesAfterWatchdog
        if (-not $postHandoff.ManagedFiles.Comparison.Unchanged) {
            throw 'Post-handoff watchdog recovery modified one or more managed portable-release files.'
        }

        # Reopen the normal launcher and exercise the same user-visible button
        # path that a person uses after the watchdog has removed the bad image.
        $postHandoffBootstrap = Start-Process -FilePath $bootstrapper -WorkingDirectory $Root -PassThru
        $postHandoff.ManualRestart.BootstrapperProcessId = $postHandoffBootstrap.Id
        $postHandoffLauncher = Wait-Until {
            @(Get-TargetProcesses $Root | Where-Object {
                try {
                        $candidateStartUtc = $_.StartTime.ToUniversalTime().ToString('o')
                        -not ($_.Id -eq $launcher.Id -and
                            [string]::Equals($candidateStartUtc, $launcherStartUtc,
                                [StringComparison]::Ordinal)) -and
                        $_.Path.StartsWith((Join-Path $Root 'CodexData\tools\launchers').TrimEnd('\') + '\',
                                [StringComparison]::OrdinalIgnoreCase) -and
                            $_.MainWindowHandle -ne [IntPtr]::Zero
                    }
                    catch { $false }
                } | Select-Object -First 1)
        } 180 'the post-handoff manual-restart LF launcher window'
        $diagnosticLauncher = $postHandoffLauncher
        $postHandoffLauncher.Refresh()
        $postHandoff.ManualRestart.CoreLauncherProcessId = $postHandoffLauncher.Id
        $postHandoff.ManualRestart.WindowTitle = $postHandoffLauncher.MainWindowTitle
        $preClickExecutionDesktopRecords = @(Get-ExecutionDesktopProcessRecords $Root)
        $postHandoff.ManualRestart.PreClickExecutionDesktopProcessCount = $preClickExecutionDesktopRecords.Count
        $postHandoff.Watchdog.ExecutionImageReappearedBeforeManualAction =
            Test-Path -LiteralPath $executionExpectation.VersionRoot -PathType Container
        if ($preClickExecutionDesktopRecords.Count -ne 0) {
            $postHandoff.Watchdog.AutomaticRestartProcessIds = @(
                $postHandoff.Watchdog.AutomaticRestartProcessIds +
                    @($preClickExecutionDesktopRecords | Select-Object -ExpandProperty ProcessId | Sort-Object -Unique) |
                    Sort-Object -Unique
            )
            $postHandoff.Watchdog.AutomaticRestartObserved = $true
        }
        if ($postHandoff.ManualRestart.PreClickExecutionDesktopProcessCount -ne 0 -or
            $postHandoff.Watchdog.ExecutionImageReappearedBeforeManualAction) {
            throw 'Codex Desktop or its local execution image reappeared before the post-handoff manual Start Codex action.'
        }

        $manualStartTraceCursor = Wait-ForMandatoryProcessStartTraceQuiescence `
            $processStartTrace 750 20
        $postHandoff.ManualRestart.StartButtonLabel = Wait-Until {
            [LfSandboxStartButtonProbe]::ClickStartCodexButton($postHandoffLauncher.MainWindowHandle)
        } 120 'the post-handoff actual Start Codex button'
        $postHandoff.ManualRestart.ActualButtonClicked = $true
        $postHandoffProgressAudit = New-LauncherProgressAudit
        Add-LauncherProgressSample $postHandoffLauncher $postHandoffProgressAudit
        $finalDesktopRoot = Wait-ForExecutionDesktopRoot $Root $executionExpectation `
            $postHandoffLauncher.Id 0 $null `
            $TimeoutSeconds 'the post-handoff manually restarted Codex Desktop root process' `
            $postHandoffLauncher $postHandoffProgressAudit $null $postHandoffAttempts
        $finalDesktopTraceRecord = Wait-ForMandatoryProcessStartTraceRecord $processStartTrace `
            $finalDesktopRoot.ProcessId $postHandoffLauncher.Id $traceSessionId 'CodexDesktop.exe' `
            $manualStartTraceCursor 20 'the manually restarted Codex Desktop root'
        $postHandoff.ManualRestart.RootAttempt = ConvertTo-ExecutionAttemptEvidence `
            $postHandoffAttempts[[string]$finalDesktopRoot.AttemptKey] $executionExpectation `
            $finalDesktopTraceRecord
        if (-not $postHandoff.ManualRestart.RootAttempt.IsExecutionImagePath -or
            -not $postHandoff.ManualRestart.RootAttempt.MatchesExpectedExecutionPath) {
            throw 'The post-handoff manually restarted Codex Desktop root did not use the rebuilt local execution image.'
        }
        $finalDesktopWindow = Wait-ForExecutionDesktopMainWindow $Root $executionExpectation `
            $finalDesktopRoot $postHandoffLauncher.Id 180 $postHandoffLauncher `
            $postHandoffProgressAudit $null $postHandoffAttempts
        $postHandoff.ManualRestart.MainWindowObserved =
            $finalDesktopWindow.MainWindowHandle -ne [IntPtr]::Zero
        $postHandoff.ManualRestart.WindowTitleAfterStart = $finalDesktopWindow.MainWindowTitle
        $postHandoff.ManualRestart.LauncherExitedAfterHandoff = Wait-ForExecutionDesktopHandoff `
            $Root $executionExpectation $postHandoffLauncher.Id 20 $postHandoffLauncher `
            $postHandoffProgressAudit $null $postHandoffAttempts
        if (-not $postHandoff.ManualRestart.LauncherExitedAfterHandoff) {
            throw 'The post-handoff manual-restart launcher did not complete the Codex Desktop handoff.'
        }
        $manualRestartTrace = Assert-DirectDesktopProcessStartTraceSequence $processStartTrace `
            $traceSessionId $manualStartTraceCursor $postHandoffLauncher.Id `
            @($finalDesktopRoot.ProcessId) 'The post-handoff manual restart'
        $postHandoff.ManualRestart.TraceRootSequence = $manualRestartTrace
        $postHandoff.ManualRestart.TraceExactlyOneRootAttempt = [bool]$manualRestartTrace.ExactSequence
        $finalRecoveryHelper = Get-RecoveryHelperProcessStartTrace $processStartTrace `
            $traceSessionId $manualStartTraceCursor $postHandoffLauncher.Id $Root
        $postHandoff.ManualRestart.RecoveryHelper = $finalRecoveryHelper.Evidence
        Save-PostHandoffRecoveryRuntimeEvidence $manual $executionExpectation `
            $postHandoffAttempts $postHandoffProgressAudit
        $postHandoff.ManualRestart.ExactlyOneRootAttempt =
            $postHandoff.ManualRestart.TraceExactlyOneRootAttempt
        if (-not $postHandoff.ManualRestart.Progress.Passed) {
            throw 'The post-handoff manual restart did not show determinate, explicit progress.'
        }
        $postHandoff.Probe.AbsentAfterManualRestart =
            -not (Test-Path -LiteralPath $postHandoff.Probe.Path -PathType Leaf)
        try {
            $finalDesktopRoot.Process.Refresh()
            $finalDesktopAlive = -not $finalDesktopRoot.Process.HasExited
        }
        catch { $finalDesktopAlive = $false }
        $manual.SelfRepair.FinalDesktopFromExpectedLocalExecutionImage = $finalDesktopAlive -and
            $postHandoff.ManualRestart.MainWindowObserved -and
            $postHandoff.ManualRestart.RootAttempt.MatchesExpectedExecutionPath
        $postHandoff.Passed = $postHandoff.RetryAliveBeforeInjection -and
            $postHandoff.ActualDelayMilliseconds -gt 9000 -and
            $postHandoff.Probe.Created -and $postHandoff.Probe.RemovedByWatchdog -and
            $postHandoff.Probe.AbsentAfterManualRestart -and
            $postHandoff.Injection.Attempted -and $postHandoff.Injection.TerminateProcessSucceeded -and
            $postHandoff.Injection.ProcessExited -and $postHandoff.Injection.ObservedExitCodeMatches -and
            $postHandoff.Watchdog.VersionRootDeleted -and $postHandoff.Watchdog.NoExecutionDesktopProcesses -and
            -not $postHandoff.Watchdog.AutomaticRestartObserved -and
            $postHandoff.Watchdog.TraceNoAutomaticRestart -and
            $postHandoff.Watchdog.ArmedAndAvailableAfterHandoff -and
            $postHandoff.Watchdog.RecoveryHelperExited -and
            $postHandoff.Watchdog.RecoveryHelperExitCodeMatches -and
            -not $postHandoff.Watchdog.ExecutionImageReappearedBeforeManualAction -and
            $postHandoff.ManagedFiles.Comparison.Unchanged -and
            $postHandoff.ManualRestart.ActualButtonClicked -and
            $postHandoff.ManualRestart.ExactlyOneRootAttempt -and
            $postHandoff.ManualRestart.MainWindowObserved -and
            $postHandoff.ManualRestart.LauncherExitedAfterHandoff -and
            $postHandoff.ManualRestart.Progress.Passed -and
            $postHandoff.ManualRestart.ExecutionImage.Valid -and
            $manual.SelfRepair.FinalDesktopFromExpectedLocalExecutionImage
        if (-not $postHandoff.Passed) {
            throw 'The post-handoff local execution-image watchdog recovery proof did not satisfy its deterministic contract.'
        }

        $payloadRequired = @('ChatGPT.exe', 'CodexDesktop.exe', 'resources\app.asar')
        $runtimeRoot = Join-Path $runtimeCacheRoot 'codex-primary-runtime'
        $runtimeRequired = @('runtime.json', 'dependencies\node\bin\node.exe', 'dependencies\python\python.exe', 'dependencies\native\git\cmd\git.exe')
        $payloadMissing = @($payloadRequired | Where-Object { -not (Test-Path -LiteralPath (Join-Path $payloadRoot $_) -PathType Leaf) })
        $runtimeMissing = @($runtimeRequired | Where-Object { -not (Test-Path -LiteralPath (Join-Path $runtimeRoot $_) -PathType Leaf) })
        if ($payloadMissing.Count -ne 0 -or $runtimeMissing.Count -ne 0) {
            throw 'Actual Start Codex did not produce every required desktop payload or runtime file.'
        }
        $pluginCache = $pluginCacheRoot
        $installedPlugins = Wait-Until {
            $audit = Get-InstalledPluginAudit $pluginCache
            if ($audit.Valid) { return $audit }
            return $false
        } $TimeoutSeconds 'all twelve versioned plugin-cache entries'
        $configText = Get-Content -LiteralPath $configToml -Raw -ErrorAction Stop
        $approval = @([regex]::Matches($configText, '(?m)^approval_policy\s*=\s*"(?<value>[^"]+)"\s*(?:#.*)?$'))
        $sandbox = @([regex]::Matches($configText, '(?m)^sandbox_mode\s*=\s*"(?<value>[^"]+)"\s*(?:#.*)?$'))
        $model = @([regex]::Matches($configText, '(?m)^model\s*=\s*"(?<value>[^"]+)"\s*(?:#.*)?$'))
        $followUpQueueMode = Get-DesktopFollowUpQueueMode $configText
        $permissionsValid = $approval.Count -eq 1 -and $sandbox.Count -eq 1 -and
            $approval[0].Groups['value'].Value -ceq 'never' -and $sandbox[0].Groups['value'].Value -ceq 'danger-full-access'
        $modelValid = $model.Count -eq 1 -and
            $model[0].Groups['value'].Value -ceq $manual.EphemeralApiConfiguration.Model
        if (-not $permissionsValid) { throw 'Actual Start Codex changed the config.toml root permission contract.' }
        if (-not $modelValid) { throw 'Actual Start Codex did not preserve the configured API model.' }
        if (-not $followUpQueueMode.Valid) { throw 'Actual Start Codex did not preserve desktop.followUpQueueMode = steer.' }
        $globalState = Get-GlobalStateOnboardingAudit $globalStatePath
        $globalStateBackup = Get-GlobalStateOnboardingAudit $globalStateBackupPath
        if (-not $globalState.Valid -or -not $globalStateBackup.Valid) {
            throw 'Actual Start Codex did not suppress the initial Try model announcement in both global-state copies.'
        }
        $manual.DerivedState = [ordered]@{
            PayloadRoot = $payloadRoot
            PayloadMissingFiles = @($payloadMissing)
            RuntimeRoot = $runtimeRoot
            RuntimeMissingFiles = @($runtimeMissing)
            PluginCache = $installedPlugins
            ConfigToml = [ordered]@{
                Path = $configToml
                ApprovalPolicy = $approval[0].Groups['value'].Value
                SandboxMode = $sandbox[0].Groups['value'].Value
                Model = $model[0].Groups['value'].Value
                FollowUpQueueMode = $followUpQueueMode.Value
                RootPermissionsStillValid = $permissionsValid
                ConfiguredModelStillValid = $modelValid
                FollowUpQueueModeValid = $followUpQueueMode.Valid
            }
            GlobalState = [ordered]@{
                Path = $globalStatePath
                BackupPath = $globalStateBackupPath
                SeenModelUpgradeList = @($globalState.SeenModelUpgradeList)
                BackupSeenModelUpgradeList = @($globalStateBackup.SeenModelUpgradeList)
                ExpectedDefaultModel = 'gpt-5.6-terra'
                ExpectedOfficialModelAnnouncement = 'gpt-5.6-sol'
                DefaultModelSeen = $globalState.DefaultModelSeen -and $globalStateBackup.DefaultModelSeen
                OfficialModelSeen = $globalState.OfficialModelSeen -and $globalStateBackup.OfficialModelSeen
                LatestModelSeenPresent = $globalState.LatestModelSeenPresent -and $globalStateBackup.LatestModelSeenPresent
                LatestModelSeenIsNull = $globalState.LatestModelSeenIsNull -and $globalStateBackup.LatestModelSeenIsNull
                OnboardingOverride = $globalState.OnboardingOverride
                BackupOnboardingOverride = $globalStateBackup.OnboardingOverride
                ProjectlessCompleted = $globalState.ProjectlessCompleted -and $globalStateBackup.ProjectlessCompleted
                WelcomePending = $globalState.WelcomePending
                BackupWelcomePending = $globalStateBackup.WelcomePending
                AnnouncementFlagsDismissed = $globalState.AnnouncementFlagsDismissed -and $globalStateBackup.AnnouncementFlagsDismissed
                Valid = $globalState.Valid -and $globalStateBackup.Valid
            }
            Desktop = [ordered]@{
                ProcessId = $finalDesktopRoot.ProcessId
                ExecutablePath = $manual.SelfRepair.PostHandoffRecovery.ManualRestart.RootAttempt.ExecutablePath
                WindowTitle = $finalDesktopWindow.MainWindowTitle
                MainWindowObserved = $finalDesktopWindow.MainWindowHandle -ne [IntPtr]::Zero
            }
        }

        # Negative control: a root process that exits with status 0 must leave
        # the verified local execution image intact and must not cause any
        # automatic Codex restart. The recovery helper is trace-bound so this
        # assertion waits for the actual post-handoff classifier to finish.
        $normalExit = $manual.SelfRepair.NormalExitControl
        if ($null -eq $finalRecoveryHelper -or $null -eq $finalRecoveryHelper.Process) {
            throw 'The normal-exit control has no trace-bound LF recovery helper.'
        }
        $normalExit.Probe.Path = Join-Path $executionExpectation.VersionRoot `
            $normalExit.Probe.RelativePath
        $normalProbeContent = 'LF Sandbox normal-exit preservation probe ' +
            [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($normalExit.Probe.Path, $normalProbeContent, $utf8)
        $normalExit.Probe.Created = Test-Path -LiteralPath $normalExit.Probe.Path -PathType Leaf
        if (-not $normalExit.Probe.Created) {
            throw 'Sandbox could not create the normal-exit execution-image preservation probe.'
        }
        $normalExit.Probe.Sha256 = (Get-FileHash -LiteralPath $normalExit.Probe.Path `
                -Algorithm SHA256).Hash.ToUpperInvariant()

        $managedReleaseBeforeNormalExit = Get-ManifestBoundManagedFileSnapshot $Root `
            $managedFileContract
        $manual.SelfRepair.ManagedRelease.BeforeNormalExit = $managedReleaseBeforeNormalExit
        if (-not $managedReleaseBeforeNormalExit.MatchesManifest) {
            throw 'Managed portable-release files changed before the normal-exit control.'
        }
        $normalExit.TraceCursor = Wait-ForMandatoryProcessStartTraceQuiescence `
            $processStartTrace 750 20
        $normalExit.TargetProcessId = $finalDesktopRoot.ProcessId
        $normalExit.Attempted = $true
        $finalDesktopExitHandle = $finalDesktopRoot.ExitHandle
        try {
            [LfSandboxProcessTerminator]::TerminateWithExitCode($finalDesktopExitHandle, [uint32]0)
            $normalExit.TerminateProcessSucceeded = $true
            $normalExitEvidence = Wait-ForCapturedProcessExit $finalDesktopRoot.ProcessId `
                $finalDesktopExitHandle 30 'the normal-exit Codex Desktop root process' $null $null $null
        }
        finally {
            Close-SandboxNativeProcessHandle $finalDesktopRoot.ExitHandle
            $finalDesktopRoot.ExitHandle = [IntPtr]::Zero
            $finalDesktopExitHandle = [IntPtr]::Zero
        }
        $normalExit.ProcessExited = $normalExitEvidence.ProcessExited
        $normalExit.ObservedExitCode = $normalExitEvidence.ObservedExitCode
        $normalExit.ObservedExitCodeMatches = [string]::Equals(
            [string]$normalExit.ObservedExitCode, [string]$normalExit.RequestedExitCode,
            [StringComparison]::Ordinal)
        if (-not $normalExit.ObservedExitCodeMatches) {
            throw 'The normal-exit control did not expose exit code 0x00000000.'
        }

        $helperExit = Wait-ForTraceBoundProcessExit $finalRecoveryHelper.Process `
            $finalRecoveryHelper.ExitHandle 30 `
            'the normal-exit LF recovery helper'
        Close-SandboxNativeProcessHandle $finalRecoveryHelper.ExitHandle
        $finalRecoveryHelper.ExitHandle = [IntPtr]::Zero
        $normalExit.RecoveryHelper = $finalRecoveryHelper.Evidence
        $normalExit.RecoveryHelperExited = $helperExit.ProcessExited
        $normalExit.RecoveryHelperExitCode = $helperExit.ObservedExitCode
        $normalExit.RecoveryHelperExitCodeMatches = [string]::Equals(
            [string]$helperExit.ObservedExitCode, '0x00000000', [StringComparison]::Ordinal)
        $normalExit.NoExecutionDesktopProcesses = Wait-ForNoExecutionDesktopProcesses $Root 30
        [void](Wait-ForMandatoryProcessStartTraceQuiescence $processStartTrace 750 20)
        $normalExit.NewCodexStartEvents = @(
            Get-DesktopProcessStartTraceRecords $processStartTrace $traceSessionId `
                ([int]$normalExit.TraceCursor) | ForEach-Object {
                ConvertTo-ProcessStartTraceEvidence $_
            }
        )
        $normalExit.NoAutomaticRestart = $normalExit.NewCodexStartEvents.Count -eq 0
        $normalExit.VersionRootPreserved = Test-Path -LiteralPath `
            $executionExpectation.VersionRoot -PathType Container
        $normalExit.Probe.Preserved = $normalExit.VersionRootPreserved -and
            (Test-Path -LiteralPath $normalExit.Probe.Path -PathType Leaf) -and
            [string]::Equals((Get-FileHash -LiteralPath $normalExit.Probe.Path `
                    -Algorithm SHA256).Hash.ToUpperInvariant(),
                [string]$normalExit.Probe.Sha256, [StringComparison]::Ordinal)
        $normalExit.ExecutionImage = Get-ExecutionImageAudit $executionExpectation
        $managedReleaseAfterNormalExit = Get-ManifestBoundManagedFileSnapshot $Root `
            $managedFileContract
        $manual.SelfRepair.ManagedRelease.AfterNormalExit = $managedReleaseAfterNormalExit
        $normalManagedComparison = Compare-ManifestBoundManagedFileSnapshots `
            $managedReleaseBeforeNormalExit $managedReleaseAfterNormalExit
        $manual.SelfRepair.ManagedRelease.NormalExitComparison = $normalManagedComparison
        $normalExit.ManagedFilesUnchanged = [bool]$normalManagedComparison.Unchanged

        $managedStages = @(
            $manual.SelfRepair.ManagedRelease.AfterCopy
            $manual.SelfRepair.ManagedRelease.BeforeLateFault
            $manual.SelfRepair.ManagedRelease.AfterLateWatchdog
            $manual.SelfRepair.ManagedRelease.BeforeNormalExit
            $manual.SelfRepair.ManagedRelease.AfterNormalExit
        )
        $manual.SelfRepair.ManagedRelease.AllMatchManifest =
            @($managedStages | Where-Object { $null -eq $_ -or -not [bool]$_.MatchesManifest }).Count -eq 0
        $allManagedStagesIdentical = $true
        foreach ($stage in ($managedStages | Select-Object -Skip 1)) {
            if (-not (Compare-ManifestBoundManagedFileSnapshots $managedStages[0] $stage).Unchanged) {
                $allManagedStagesIdentical = $false
                break
            }
        }
        $manual.SelfRepair.ManagedRelease.AllIdentical = $allManagedStagesIdentical
        $normalExit.Passed = $normalExit.Attempted -and $normalExit.TerminateProcessSucceeded -and
            $normalExit.ProcessExited -and $normalExit.ObservedExitCodeMatches -and
            $normalExit.RecoveryHelperExited -and $normalExit.RecoveryHelperExitCodeMatches -and
            $normalExit.NoExecutionDesktopProcesses -and $normalExit.NoAutomaticRestart -and
            $normalExit.VersionRootPreserved -and $normalExit.Probe.Preserved -and
            $normalExit.ExecutionImage.Valid -and $normalExit.ManagedFilesUnchanged -and
            $manual.SelfRepair.ManagedRelease.AllMatchManifest -and
            $manual.SelfRepair.ManagedRelease.AllIdentical
        if (-not $normalExit.Passed) {
            throw 'Normal exit incorrectly invalidated, rebuilt, or relaunched the local execution image.'
        }

        $expectedTraceRoots = @(
            [pscustomobject]@{ Label = 'InitialAttempt'; ProcessId = $initialRoot.ProcessId; ParentProcessId = $launcher.Id; TraceEventOrdinal = $initialTraceRecord.EventOrdinal }
            [pscustomobject]@{ Label = 'RetryAttempt'; ProcessId = $retryRoot.ProcessId; ParentProcessId = $launcher.Id; TraceEventOrdinal = $retryTraceRecord.EventOrdinal }
            [pscustomobject]@{ Label = 'ManualRestart'; ProcessId = $finalDesktopRoot.ProcessId; ParentProcessId = $postHandoffLauncher.Id; TraceEventOrdinal = $finalDesktopTraceRecord.EventOrdinal }
        )
        $finalTraceAudit = Complete-MandatoryProcessStartTraceAudit $processStartTrace `
            $traceSessionId $firstStartTraceCursor $expectedTraceRoots
        $manual.SelfRepair.ProcessStartTrace.FinalAudit = $finalTraceAudit
        $manual.SelfRepair.ProcessStartTrace.EndProbe = Invoke-MandatoryProcessStartTraceProbe `
            $processStartTrace $traceSessionId 'end-of-test readiness'
        $manual.SelfRepair.ProcessStartTrace.RelevantEvents = @(
            Get-SessionProcessStartTraceRecords $processStartTrace $traceSessionId 0 | Where-Object {
                [string]::Equals([string]$_.ProcessName, 'CodexDesktop.exe',
                    [StringComparison]::OrdinalIgnoreCase) -or
                    [string]$_.ProcessName -like 'LFRecovery-*.exe'
            } | ForEach-Object { ConvertTo-ProcessStartTraceEvidence $_ }
        )
        $manual.SelfRepair.ProcessStartTrace.Healthy = $true
        $manual.SelfRepair.ProcessStartTrace.Passed = $finalTraceAudit.Passed -and
            $manual.SelfRepair.ProcessStartTrace.FirstLaunch.ExactSequence -and
            $manual.SelfRepair.ProcessStartTrace.LateFaultWindow.NoAutomaticRestart -and
            $postHandoff.ManualRestart.TraceRootSequence.ExactSequence -and
            $manual.SelfRepair.ProcessStartTrace.StartProbe.TraceBound -and
            $manual.SelfRepair.ProcessStartTrace.EndProbe.TraceBound
        $manual.SelfRepair.Passed = $manual.SelfRepair.EarlyStartupPassed -and
            $postHandoff.Passed -and $normalExit.Passed -and
            $manual.SelfRepair.ProcessStartTrace.Passed -and
            $manual.SelfRepair.ManagedRelease.AllMatchManifest -and
            $manual.SelfRepair.ManagedRelease.AllIdentical
        if (-not $manual.SelfRepair.Passed) {
            throw 'The complete execution-image self-repair and negative-control proof failed.'
        }
        $manual.Passed = $manual.Launcher.ActualButtonClicked -and $manual.Launcher.Progress.Passed -and
            $manual.DerivedState.Desktop.MainWindowObserved -and
            $payloadMissing.Count -eq 0 -and $runtimeMissing.Count -eq 0 -and $installedPlugins.Valid -and
            $permissionsValid -and $modelValid -and $followUpQueueMode.Valid -and
            $globalState.Valid -and $globalStateBackup.Valid -and
            $manual.InitialConfig.FollowUpQueueModeValid -and $manual.SelfRepair.Passed
    }
    catch {
        $manual.Error = Protect-DiagnosticText $_.Exception.Message @($ephemeralApiKey)
        if ($null -ne $progressAudit) {
            try { Save-LauncherProgressAudit $manual $launcher $progressAudit } catch { }
        }
        try {
            Save-SelfRepairRuntimeEvidence $manual $executionExpectation $executionAttempts $recoveryProgressAudit
        }
        catch { }
        try {
            Save-PostHandoffRecoveryRuntimeEvidence $manual $executionExpectation `
                $postHandoffAttempts $postHandoffProgressAudit
        }
        catch { }
        $failureLauncher = if ($null -ne $diagnosticLauncher) { $diagnosticLauncher } else { $launcher }
        $manual.FailureDiagnostics = Get-ManualStartFailureDiagnostics $Root $failureLauncher @($ephemeralApiKey)
        $manual.Passed = $false
    }
    finally {
        if ($null -ne $progressAudit) {
            try { Save-LauncherProgressAudit $manual $launcher $progressAudit } catch { }
        }
        try {
            Save-SelfRepairRuntimeEvidence $manual $executionExpectation $executionAttempts $recoveryProgressAudit
        }
        catch { }
        try {
            Save-PostHandoffRecoveryRuntimeEvidence $manual $executionExpectation `
                $postHandoffAttempts $postHandoffProgressAudit
        }
        catch { }
        if (-not $manual.Passed -and $null -eq $manual.FailureDiagnostics) {
            $failureLauncher = if ($null -ne $diagnosticLauncher) { $diagnosticLauncher } else { $launcher }
            $manual.FailureDiagnostics = Get-ManualStartFailureDiagnostics $Root $failureLauncher @($ephemeralApiKey)
        }
        if ($null -ne $processStartTrace) {
            try {
                $processStartTrace.EnsureHealthy()
                if (@($manual.SelfRepair.ProcessStartTrace.RelevantEvents).Count -eq 0) {
                    $manual.SelfRepair.ProcessStartTrace.RelevantEvents = @(
                        Get-SessionProcessStartTraceRecords $processStartTrace $traceSessionId 0 | Where-Object {
                            [string]::Equals([string]$_.ProcessName, 'CodexDesktop.exe',
                                [StringComparison]::OrdinalIgnoreCase) -or
                                [string]$_.ProcessName -like 'LFRecovery-*.exe'
                        } | ForEach-Object { ConvertTo-ProcessStartTraceEvidence $_ }
                    )
                }
            }
            catch {
                $manual.SelfRepair.ProcessStartTrace.Healthy = $false
                $manual.SelfRepair.ProcessStartTrace.Passed = $false
                $manual.SelfRepair.Passed = $false
                $manual.Passed = $false
                if ($null -eq (Get-NullableObjectProperty $manual 'Error')) {
                    $manual.Error = 'Mandatory Win32_ProcessStartTrace evidence became unavailable or incomplete.'
                }
            }
            finally {
                try { $processStartTrace.Dispose() } catch { }
            }
        }
        if ($null -ne $finalRecoveryHelper -and $null -ne $finalRecoveryHelper.ExitHandle) {
            Close-SandboxNativeProcessHandle $finalRecoveryHelper.ExitHandle
            $finalRecoveryHelper.ExitHandle = [IntPtr]::Zero
        }
        if ($null -ne $lateRecoveryHelper -and $null -ne $lateRecoveryHelper.ExitHandle) {
            Close-SandboxNativeProcessHandle $lateRecoveryHelper.ExitHandle
            $lateRecoveryHelper.ExitHandle = [IntPtr]::Zero
        }
        foreach ($rootAttempt in @($initialRoot, $retryRoot, $finalDesktopRoot)) {
            if ($null -ne $rootAttempt -and $null -ne $rootAttempt.ExitHandle) {
                Close-SandboxNativeProcessHandle $rootAttempt.ExitHandle
                $rootAttempt.ExitHandle = [IntPtr]::Zero
            }
        }
        Close-SandboxNativeProcessHandle $initialRootExitHandle
        Close-SandboxNativeProcessHandle $retryRootExitHandle
        Close-SandboxNativeProcessHandle $finalDesktopExitHandle
        $initialRootExitHandle = [IntPtr]::Zero
        $retryRootExitHandle = [IntPtr]::Zero
        $finalDesktopExitHandle = [IntPtr]::Zero
        if ($null -ne $finalRecoveryHelper -and $null -ne $finalRecoveryHelper.Process) {
            try { $finalRecoveryHelper.Process.Dispose() } catch { }
        }
        if ($null -ne $lateRecoveryHelper -and $null -ne $lateRecoveryHelper.Process) {
            try { $lateRecoveryHelper.Process.Dispose() } catch { }
        }
        $manual.Cleanup = Stop-TargetProcesses $Root
        if (-not $manual.Cleanup.Succeeded) {
            $manual.Passed = $false
            if ($null -eq (Get-NullableObjectProperty $manual 'Error')) {
                $manual.Error = 'Could not close all Sandbox-owned manual-start processes.'
            }
        }
        $ephemeralApiKey = $null
        $manual.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    }
    return [pscustomobject]$manual
}

$result = [ordered]@{
    Contract = $contract
    Status = 'Running'
    Passed = $false
    StartedUtc = [DateTime]::UtcNow.ToString('o')
    SourceRoot = $SourceRoot
    ManifestPath = $ManifestPath
    ExpectedManagedFileCount = 10
    ExpectedPluginCount = 12
    ValidationArchitecture = 'x64'
    FollowUpQueueMode = 'steer'
    ManifestSha256 = $null
    ReleaseVersion = $null
    ManualStart = [ordered]@{ Executed = $false; Passed = $false }
}
$exitCode = 1

try {
    # Keep every executable initialization step inside the result-writing
    # boundary so a guest capability failure is exported to the host.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Initialize-SandboxStartButtonProbe
    foreach ($path in @($SourceRoot, $ManifestPath, $EvidenceRoot)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Required Sandbox mapping is missing: $path" }
    }
    $sourceFull = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
    $manifestFull = (Resolve-Path -LiteralPath $ManifestPath).Path
    $evidenceFull = (Resolve-Path -LiteralPath $EvidenceRoot).Path.TrimEnd('\')
    $manifest = Get-Content -LiteralPath $manifestFull -Raw | ConvertFrom-Json -ErrorAction Stop
    $result.SourceRoot = $sourceFull
    $result.ManifestPath = $manifestFull
    $result.ManifestSha256 = (Get-FileHash -LiteralPath $manifestFull -Algorithm SHA256).Hash.ToUpperInvariant()
    $result.ReleaseVersion = [string]$manifest.ReleaseVersion
    if ($result.ReleaseVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Release manifest has no valid four-part ReleaseVersion.' }

    $sourceFiles = Get-RelativeFiles $sourceFull
    $result.CompactRelease = [ordered]@{
        ExpectedManagedFileCount = 10
        SourceFileCount = $sourceFiles.Count
        ManifestFileCount = @($manifest.Files).Count
        SourceFileCountValid = $sourceFiles.Count -eq 10
        ManifestFileCountValid = @($manifest.Files).Count -eq 10
        SourcePathsValid = Test-ExactStringSet $expectedFiles $sourceFiles
        ManifestPathsValid = Test-ExactStringSet $expectedFiles @($manifest.Files | ForEach-Object { [string]$_.Path })
    }
    $result.Plugins = Get-PluginAudit `
        (Join-Path $sourceFull 'CodexData\packages\LFPortable-common.zip') `
        (Join-Path $sourceFull 'CodexData\packages\LFPortable-x64.msix')
    if (-not $result.CompactRelease.SourceFileCountValid -or -not $result.CompactRelease.ManifestFileCountValid -or
        -not $result.CompactRelease.SourcePathsValid -or -not $result.CompactRelease.ManifestPathsValid -or -not $result.Plugins.Valid) {
        throw 'Mapped canonical release does not satisfy the 10-file and 12-plugin compact contract.'
    }

    $validatorTarget = Join-Path $env:SystemDrive ('LFPortable-validator-' + $result.ReleaseVersion)
    $validatorResultPath = Join-Path $env:SystemDrive ('LFPortable-validator-' + $result.ReleaseVersion + '.json')
    $validatorScript = Join-Path $PSScriptRoot 'Validate-CompactFirstRun.ps1'
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File $validatorScript `
        -SourceRoot $sourceFull -ManifestPath $manifestFull -TargetRoot $validatorTarget -ResultPath $validatorResultPath -TimeoutSeconds $TimeoutSeconds
    $validatorExitCode = [int]$LASTEXITCODE
    $validatorResult = if (Test-Path -LiteralPath $validatorResultPath -PathType Leaf) {
        Get-Content -LiteralPath $validatorResultPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    else { $null }
    $validatorPresentation = Get-ObjectProperty $validatorResult 'PermissionPresentation'
    $validatorTryModelSuppressed = [bool](Get-ObjectProperty $validatorPresentation `
        'TryModelAnnouncementSuppressed')
    $result.Validator = [ordered]@{
        ExitCode = $validatorExitCode
        ResultWritten = $null -ne $validatorResult
        Passed = $null -ne $validatorResult -and [bool](Get-ObjectProperty $validatorResult 'Passed')
        Status = Get-ObjectProperty $validatorResult 'Status'
        Error = Get-ObjectProperty $validatorResult 'Error'
        TryModelAnnouncementSuppressed = $validatorTryModelSuppressed
    }
    if ($validatorExitCode -ne 0 -or -not $result.Validator.Passed -or
        $result.Validator.Status -cne 'Passed' -or
        -not $result.Validator.TryModelAnnouncementSuppressed) {
        throw 'The isolated zero-state validator did not pass; manual Start Codex was not attempted.'
    }

    $manualTarget = Join-Path $env:SystemDrive ('LFPortable-manual-' + $result.ReleaseVersion)
    $result.ManualStart = Invoke-ManualStart $manualTarget $manifest
    $result.Passed = $result.Validator.Passed -and $result.ManualStart.Passed
    $result.Status = if ($result.Passed) { 'Passed' } else { 'Failed' }
    $exitCode = if ($result.Passed) { 0 } else { 2 }
}
catch {
    $result.Error = $_.Exception.ToString()
    $result.Passed = $false
    $result.Status = 'Failed'
}
finally {
    $result.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    try {
        Write-Json (Join-Path $EvidenceRoot 'sandbox-first-run-result.json') $result
    }
    catch {
        # The host must never mistake a missing guest result for a successful
        # validation. There is no second write attempt because the mapped
        # evidence directory itself may be unavailable.
        $result.Passed = $false
        $result.Status = 'Failed'
        if ([string]::IsNullOrWhiteSpace([string](Get-NullableObjectProperty $result 'Error'))) {
            $result.Error = 'Could not write Sandbox validation result: ' + $_.Exception.Message
        }
        $exitCode = 1
        [Console]::Error.WriteLine('Could not write Sandbox validation result: ' + $_.Exception.Message)
    }
}

exit $exitCode
