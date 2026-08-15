[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,
    [Parameter(Mandatory = $true)]
    [string]$UsbRoot,
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [string]$ExpectedManifestSha256,
    # A temporary result exported by the isolated Windows Sandbox harness.
    # It is intentionally outside both the canonical release and USB tree.
    [string]$SandboxValidationResultPath,
    [ValidateRange(0, 86400)]
    [int]$WaitForPortableExitSeconds = 300,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop)) {
        throw "$Label is missing: $Path"
    }
    $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if ($full -match '^[A-Za-z]:\\$') { return $full }
    $full.TrimEnd('\')
}

function Assert-SourceIsNotUsb([string]$Path) {
    # The USB volume is a deployment target, never a release source.  This
    # guard also applies when the synchronizer is invoked directly instead of
    # through New-PortableRelease, preventing a stale/incomplete USB tree from
    # being treated as canonical input.
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notmatch '^[A-Za-z]:') { return }
    $driveInfo = $null
    try {
        $driveInfo = New-Object IO.DriveInfo($full.Substring(0, 1) + ':')
        if (-not $driveInfo.IsReady) { throw 'Source drive is not ready.' }
    }
    catch {
        throw "Unable to determine the source volume type for $full; refusing an unverified release source."
    }
    if ($driveInfo.DriveType -eq [IO.DriveType]::Removable -or
        [string]::Equals([string]$driveInfo.VolumeLabel, 'CODEX_USB', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release source '$full' is on a removable/CODEX_USB volume. Synchronize only from a separate canonical release directory; never from the USB installation."
    }
}

function Test-PathWithin([string]$Candidate, [string]$Root) {
    $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidateFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        $candidateFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparseAncestry([string]$Path, [string]$Label) {
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

function Convert-ToExtendedPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $full }
    if ($full.StartsWith('\\', [StringComparison]::Ordinal)) { return '\\?\UNC\' + $full.Substring(2) }
    '\\?\' + $full
}

function Convert-FromExtendedPath([string]$Path) {
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        return '\\' + $Path.Substring(8)
    }
    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        return $Path.Substring(4)
    }
    $Path
}

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::Open((Convert-ToExtendedPath $Path), [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-RelativePath([string]$Root, [string]$Path) {
    $Root = Convert-FromExtendedPath $Root
    $Path = Convert-FromExtendedPath $Path
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside root: $Path"
    }
    $relative = $pathFull.Substring($rootFull.Length).TrimStart('\').Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or
        @($relative.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0 -or
        $relative.Contains(':')) {
        throw "Unsafe relative path: $relative"
    }
    $relative
}

function Get-StrictJson([string]$Path) {
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json -ErrorAction Stop
}

function Get-ValidationProperty([object]$Value, [string]$Name, [string]$Label) {
    if ($null -eq $Value) { throw "$Label is missing." }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Label is missing property '$Name'." }
    return $property.Value
}

function Assert-ValidationTrue([object]$Value, [string]$Label) {
    if (-not ($Value -is [bool]) -or -not [bool]$Value) {
        throw "$Label must be the Boolean value true."
    }
}

function Assert-SandboxProofOutsideDeploymentTrees([string]$ResultPath, [string]$SourceRoot,
    [string]$UsbRoot, [switch]$RequireExistingFile) {
    $resultFull = [IO.Path]::GetFullPath($ResultPath)
    if ((Test-PathWithin $resultFull $SourceRoot) -or (Test-PathWithin $SourceRoot $resultFull) -or
        (Test-PathWithin $resultFull $UsbRoot) -or (Test-PathWithin $UsbRoot $resultFull)) {
        throw 'Windows Sandbox validation result must be outside both the canonical release and USB trees.'
    }
    if (-not (Test-Path -LiteralPath $resultFull -PathType Leaf)) {
        if ($RequireExistingFile) {
            throw "Windows Sandbox validation result is missing: $ResultPath"
        }
        return $resultFull
    }
    $resolvedResultFull = (Resolve-Path -LiteralPath $resultFull -ErrorAction Stop).Path
    Assert-NoReparseAncestry $resolvedResultFull 'Windows Sandbox validation result'
    return $resolvedResultFull
}

function Assert-SandboxFirstRunValidation([string]$ResultPath, [string]$ManifestHash,
    [string]$ReleaseVersion, [string]$ManifestFullPath, [string]$SourceRoot, [string]$UsbRoot) {
    if ([string]::IsNullOrWhiteSpace($ResultPath)) {
        throw 'USB synchronization requires a Windows Sandbox validation result path.'
    }
    $resultFull = Assert-SandboxProofOutsideDeploymentTrees $ResultPath $SourceRoot $UsbRoot -RequireExistingFile
    $resultItem = Get-Item -LiteralPath $resultFull -Force -ErrorAction Stop
    if (($resultItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $resultItem.Length -le 0 -or $resultItem.Length -gt 16MB) {
        throw 'Windows Sandbox validation result is not a safe regular JSON file.'
    }
    $manifestItem = Get-Item -LiteralPath $ManifestFullPath -Force -ErrorAction Stop
    if ($resultItem.LastWriteTimeUtc -lt $manifestItem.LastWriteTimeUtc) {
        throw 'Windows Sandbox validation result predates the canonical release manifest.'
    }

    $proof = Get-StrictJson $resultFull
    if ([string](Get-ValidationProperty $proof 'Contract' 'Windows Sandbox validation result') -cne
        'LF compact first-run Sandbox') {
        throw 'Windows Sandbox validation result has an unsupported contract.'
    }
    if ([string](Get-ValidationProperty $proof 'Status' 'Windows Sandbox validation result') -cne 'Passed') {
        throw 'Windows Sandbox validation result status is not Passed.'
    }
    Assert-ValidationTrue (Get-ValidationProperty $proof 'Passed' 'Windows Sandbox validation result') `
        'Windows Sandbox validation result Passed'
    if (-not ([string](Get-ValidationProperty $proof 'ManifestSha256' 'Windows Sandbox validation result')).Equals(
            $ManifestHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Windows Sandbox validation result does not bind to this release manifest hash.'
    }
    if (-not ([string](Get-ValidationProperty $proof 'ReleaseVersion' 'Windows Sandbox validation result')).Equals(
            $ReleaseVersion, [StringComparison]::Ordinal)) {
        throw 'Windows Sandbox validation result does not bind to this release version.'
    }
    if ([int](Get-ValidationProperty $proof 'ExpectedManagedFileCount' 'Windows Sandbox validation result') -ne 10 -or
        [int](Get-ValidationProperty $proof 'ExpectedPluginCount' 'Windows Sandbox validation result') -ne 12) {
        throw 'Windows Sandbox validation result has an unsupported compact release contract.'
    }

    $compact = Get-ValidationProperty $proof 'CompactRelease' 'Windows Sandbox validation result'
    foreach ($name in @('SourceFileCountValid', 'ManifestFileCountValid', 'SourcePathsValid', 'ManifestPathsValid')) {
        Assert-ValidationTrue (Get-ValidationProperty $compact $name 'Windows Sandbox compact release') `
            "Windows Sandbox compact release $name"
    }
    $plugins = Get-ValidationProperty $proof 'Plugins' 'Windows Sandbox validation result'
    if ([int](Get-ValidationProperty $plugins 'ExpectedPluginCount' 'Windows Sandbox plugin validation') -ne 12 -or
        [int](Get-ValidationProperty $plugins 'FoundPluginCount' 'Windows Sandbox plugin validation') -ne 12) {
        throw 'Windows Sandbox plugin validation did not inspect all required plugins.'
    }
    Assert-ValidationTrue (Get-ValidationProperty $plugins 'Valid' 'Windows Sandbox plugin validation') `
        'Windows Sandbox plugin validation Valid'

    $validator = Get-ValidationProperty $proof 'Validator' 'Windows Sandbox validation result'
    if ([int](Get-ValidationProperty $validator 'ExitCode' 'Windows Sandbox validator') -ne 0) {
        throw 'The isolated compact first-run validator did not exit successfully.'
    }
    Assert-ValidationTrue (Get-ValidationProperty $validator 'Passed' 'Windows Sandbox validator') `
        'Windows Sandbox validator Passed'

    $manualStart = Get-ValidationProperty $proof 'ManualStart' 'Windows Sandbox validation result'
    Assert-ValidationTrue (Get-ValidationProperty $manualStart 'Executed' 'Windows Sandbox manual start') `
        'Windows Sandbox manual start Executed'
    Assert-ValidationTrue (Get-ValidationProperty $manualStart 'Passed' 'Windows Sandbox manual start') `
        'Windows Sandbox manual start Passed'
    $zeroState = Get-ValidationProperty $manualStart 'ZeroState' 'Windows Sandbox manual start'
    foreach ($name in @('ConfigTomlExists', 'ExpandedPayloadExists', 'RuntimeCacheExists', 'PluginCacheExists')) {
        if ([bool](Get-ValidationProperty $zeroState $name 'Windows Sandbox manual-start zero state')) {
            throw "Windows Sandbox manual-start zero state $name must be false."
        }
    }
    $launcher = Get-ValidationProperty $manualStart 'Launcher' 'Windows Sandbox manual start'
    Assert-ValidationTrue (Get-ValidationProperty $launcher 'ActualButtonClicked' 'Windows Sandbox manual start launcher') `
        'Windows Sandbox manual Start Codex button click'
    $derived = Get-ValidationProperty $manualStart 'DerivedState' 'Windows Sandbox manual start'
    $config = Get-ValidationProperty $derived 'ConfigToml' 'Windows Sandbox manual start'
    Assert-ValidationTrue (Get-ValidationProperty $config 'RootPermissionsStillValid' 'Windows Sandbox config.toml') `
        'Windows Sandbox config.toml root permissions'

    [pscustomobject]@{
        ResultPath = $resultFull
        ManifestSha256 = $ManifestHash
        ReleaseVersion = $ReleaseVersion
        VerifiedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Assert-ExactPropertySet([object]$Value, [string[]]$Expected, [string]$Label) {
    $actual = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actual.Count -ne $Expected.Count -or
        @($Expected | Where-Object { -not ($actual -ccontains $_) }).Count -ne 0 -or
        @($actual | Where-Object { -not ($Expected -ccontains $_) }).Count -ne 0) {
        throw "$Label has an unsupported property set: $($actual -join ', ')"
    }
}

function Assert-PortableReleaseDescriptor([string]$Root, [hashtable]$ExpectedMetadata,
    [string]$ExpectedVersion, [string]$Label) {
    $descriptorPath = Join-Path $Root 'CodexData\portable-release.json'
    if (-not (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) {
        throw "$Label portable-release.json is missing."
    }
    $descriptor = Get-StrictJson $descriptorPath
    Assert-ExactPropertySet $descriptor @('SchemaVersion', 'ReleaseVersion', 'LauncherVersion', 'Files') `
        "$Label portable-release.json"
    if ([int]$descriptor.SchemaVersion -ne 1 -or
        -not ([string]$descriptor.ReleaseVersion).Equals($ExpectedVersion, [StringComparison]::Ordinal) -or
        -not ([string]$descriptor.LauncherVersion).Equals($ExpectedVersion, [StringComparison]::Ordinal)) {
        throw "$Label portable-release.json schema or version does not match the launcher set."
    }
    $descriptorFiles = @(
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
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $files = @($descriptor.Files)
    if ($files.Count -ne $descriptorFiles.Count) {
        throw "$Label portable-release.json must contain exactly $($descriptorFiles.Count) file entries."
    }
    foreach ($entry in $files) {
        Assert-ExactPropertySet $entry @('Path', 'Length', 'Sha256') "$Label portable-release.json file entry"
        $relative = [string]$entry.Path
        if (-not ($descriptorFiles -ccontains $relative) -or -not $seen.Add($relative)) {
            throw "$Label portable-release.json contains an unexpected or duplicate file entry: $relative"
        }
        $expected = $ExpectedMetadata[$relative]
        if ($null -eq $expected -or [long]$entry.Length -ne [long]$expected.Length -or
            -not ([string]$entry.Sha256).Equals([string]$expected.Sha256, [StringComparison]::Ordinal)) {
            throw "$Label portable-release.json hash or length differs for: $relative"
        }
    }
    foreach ($relative in $descriptorFiles) {
        if (-not $seen.Contains($relative)) { throw "$Label portable-release.json is missing: $relative" }
    }
}

function Get-PeMachine([string]$Path) {
    $stream = [IO.File]::Open((Convert-ToExtendedPath $Path), [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw "Invalid PE header: $Path" }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        if ($offset -lt 0 -or $offset -gt ($stream.Length - 6)) { throw "Invalid PE offset: $Path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature: $Path" }
        [int]$reader.ReadUInt16()
    }
    finally { $stream.Dispose() }
}

function Assert-PeMachine([string]$Path, [int]$Expected, [string]$Label) {
    $actual = Get-PeMachine $Path
    if ($actual -ne $Expected) { throw "$Label has PE machine 0x$('{0:X4}' -f $actual); expected 0x$('{0:X4}' -f $Expected)." }
}

function Assert-UsbVolume([string]$Root) {
    if ($Root -notmatch '^[A-Za-z]:\\$') {
        throw "USB root must be an explicit drive root such as E:\\; refusing ambiguous path: $Root"
    }
    $drive = $Root.Substring(0, 1)
    $volumeText = (& cmd.exe /d /c "vol $drive`:" 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $volumeText -notmatch '(?i)\bCODEX_USB\b') {
        throw "USB root $Root does not have the required CODEX_USB volume label."
    }
}

function Test-ManagedProcessPath([string]$Path, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path)
    # A process anywhere below the USB root can retain a file or keep stale
    # state alive while the atomic replacement is activated. Protect the whole
    # installation, including auxiliary tools such as voice-input helpers,
    # rather than maintaining a fragile allow-list of managed subdirectories.
    return $pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-PortableMutexName([string]$Root) {
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\').ToUpperInvariant()
    $rootBytes = [Text.Encoding]::UTF8.GetBytes($normalizedRoot)
    $digest = $null
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($rootBytes) }
        finally { $sha.Dispose() }
        $suffix = -join @($digest[0..15] | ForEach-Object { $_.ToString('x2') })
        'Local\CodexPortable-Desktop-' + $suffix
    }
    finally {
        [Array]::Clear($rootBytes, 0, $rootBytes.Length)
        if ($null -ne $digest) { [Array]::Clear($digest, 0, $digest.Length) }
    }
}

function Acquire-PortableMutex([string]$Name, [int]$TimeoutMilliseconds, [string]$Label) {
    $mutex = New-Object Threading.Mutex($false, $Name)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne($TimeoutMilliseconds, $false) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "$Label is still held after $TimeoutMilliseconds ms." }
        $mutex
    }
    catch {
        if (-not $acquired) { $mutex.Dispose() }
        throw
    }
}

function Release-PortableMutex([Threading.Mutex]$Mutex) {
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() }
    finally { $Mutex.Dispose() }
}

function Get-PortableProcesses([string]$Root) {
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            Test-ManagedProcessPath ([string]$_.ExecutablePath) $Root
        })
    }
    catch {
        return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try {
                $path = $_.Path
                Test-ManagedProcessPath $path $Root
            }
            catch { $false }
        })
    }
}

function Wait-ForPortableExit([string]$Root, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $running = @(Get-PortableProcesses $Root)
        if ($running.Count -eq 0) { return }
        if ([DateTime]::UtcNow -ge $deadline) {
            $details = @($running | ForEach-Object {
                $processId = if ($null -ne $_.PSObject.Properties['ProcessId']) {
                    [string]$_.ProcessId
                }
                else {
                    [string]$_.Id
                }
                $executablePath = if ($null -ne $_.PSObject.Properties['ExecutablePath']) {
                    [string]$_.ExecutablePath
                }
                else {
                    try { [string]$_.Path }
                    catch { '<path unavailable>' }
                }
                "$($_.Name) (PID $processId, $executablePath)"
            }) -join '; '
            throw "Managed portable processes are still running from ${Root}: $details. Close LF/Codex and its runtime tasks from this USB installation, then rerun synchronization; the synchronizer will not terminate them automatically."
        }
        Start-Sleep -Seconds ([Math]::Min(2, [Math]::Max(1, $Seconds)))
    } while ($true)
}

function Assert-ExactStringSet([string[]]$Expected, [string[]]$Actual, [string]$Label) {
    $expectedItems = @($Expected)
    $actualItems = @($Actual)
    if ($expectedItems.Count -ne $actualItems.Count) {
        throw "$Label has unexpected entries: $($actualItems -join ', ')"
    }
    foreach ($entry in $expectedItems) {
        if (-not ($actualItems -ccontains $entry)) { throw "$Label is missing required entry: $entry" }
    }
    foreach ($entry in $actualItems) {
        if (-not ($expectedItems -ccontains $entry)) { throw "$Label contains an unexpected entry: $entry" }
    }
}

function Assert-CompactTree([string]$Root, [string[]]$ExpectedDirectories, [string[]]$ExpectedFiles,
    [hashtable]$ExpectedMetadata, [string]$Label) {
    $extendedRoot = Convert-ToExtendedPath $Root
    $reparsePoints = @(Get-ChildItem -LiteralPath $extendedRoot -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop)
    if ($reparsePoints.Count -ne 0) { throw "$Label contains a reparse point: $($reparsePoints[0].FullName)" }
    $directories = @(Get-ChildItem -LiteralPath $extendedRoot -Recurse -Force -Directory -ErrorAction Stop |
        ForEach-Object { Get-RelativePath $Root $_.FullName })
    $files = @(Get-ChildItem -LiteralPath $extendedRoot -Recurse -Force -File -ErrorAction Stop |
        ForEach-Object { Get-RelativePath $Root $_.FullName })
    Assert-ExactStringSet $ExpectedDirectories $directories "$Label directories"
    Assert-ExactStringSet $ExpectedFiles $files "$Label files"
    foreach ($relative in $ExpectedFiles) {
        $item = Get-Item -LiteralPath (Join-Path $Root ($relative -replace '/', '\')) -Force -ErrorAction Stop
        $expectedLength = [long]$ExpectedMetadata[$relative].Length
        if ($item.Length -ne $expectedLength) {
            throw "$Label length mismatch: $relative (expected $expectedLength, actual $($item.Length))"
        }
    }
}

function Get-VerifiedManagedHashes([string]$Root, [string[]]$ExpectedFiles,
    [hashtable]$ExpectedMetadata, [string]$Label) {
    $hashes = @{}
    foreach ($relative in $ExpectedFiles) {
        $path = Join-Path $Root ($relative -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Label is missing managed file: $relative" }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label managed file is a reparse point: $relative" }
        $expectedLength = [long]$ExpectedMetadata[$relative].Length
        if ($item.Length -ne $expectedLength) {
            throw "$Label length mismatch: $relative (expected $expectedLength, actual $($item.Length))"
        }
        $hash = Get-Sha256 $path
        $expectedHash = [string]$ExpectedMetadata[$relative].Sha256
        if (-not $hash.Equals($expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label hash mismatch: $relative"
        }
        $hashes[$relative] = $hash.ToUpperInvariant()
    }
    $hashes
}

function Assert-LauncherSet([string]$Root, [string]$ExpectedVersion, [string]$Label) {
    $paths = [ordered]@{
        Bootstrapper = [pscustomobject]@{ Path = 'CodexPortable.exe'; Machine = 0x014c }
        X86 = [pscustomobject]@{ Path = 'CodexData/tools/launchers/CodexPortable.x86.exe'; Machine = 0x014c }
        X64 = [pscustomobject]@{ Path = 'CodexData/tools/launchers/CodexPortable.x64.exe'; Machine = 0x8664 }
        Arm64 = [pscustomobject]@{ Path = 'CodexData/tools/launchers/CodexPortable.arm64.exe'; Machine = 0xAA64 }
    }
    foreach ($entry in @($paths.GetEnumerator())) {
        $path = Join-Path $Root ($entry.Value.Path -replace '/', '\')
        Assert-PeMachine $path ([int]$entry.Value.Machine) "$Label $($entry.Key)"
        $version = [string](Get-Item -LiteralPath $path -Force).VersionInfo.FileVersion
        if ([string]::IsNullOrWhiteSpace($version) -or
            -not $version.Equals($ExpectedVersion, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label launcher version mismatch for $($entry.Key): expected $ExpectedVersion, actual $version"
        }
    }
}

function Get-UnknownPluginCacheDirectories([string]$Root, [System.Collections.IDictionary]$RequiredPlugins) {
    $unknown = New-Object 'System.Collections.Generic.List[string]'
    $cacheRoot = Join-Path $Root 'CodexData\data\profile\.codex\plugins\cache'
    foreach ($catalog in @($RequiredPlugins.Keys)) {
        $catalogRoot = Join-Path $cacheRoot ([string]$catalog)
        if (-not (Test-Path -LiteralPath $catalogRoot)) { continue }
        if (-not (Test-Path -LiteralPath $catalogRoot -PathType Container)) {
            throw "Plugin cache catalog is not a directory: $catalogRoot"
        }
        Assert-NoReparseAncestry $catalogRoot "USB plugin cache catalog $catalog"
        foreach ($directory in @(Get-ChildItem -LiteralPath $catalogRoot -Directory -Force -ErrorAction Stop)) {
            if (@($RequiredPlugins[$catalog]) -notcontains $directory.Name) {
                $unknown.Add((Get-RelativePath $Root $directory.FullName))
            }
        }
    }
    @($unknown)
}

function Move-Directory([string]$Source, [string]$Destination) {
    if (-not [IO.Directory]::Exists($Source)) { throw "Directory move source is missing: $Source" }
    if ([IO.Directory]::Exists($Destination) -or [IO.File]::Exists($Destination)) { throw "Directory move destination exists: $Destination" }
    [IO.Directory]::Move((Convert-ToExtendedPath $Source), (Convert-ToExtendedPath $Destination))
}

function Move-File([string]$Source, [string]$Destination) {
    if (-not [IO.File]::Exists($Source)) { throw "File move source is missing: $Source" }
    if ([IO.Directory]::Exists($Destination) -or [IO.File]::Exists($Destination)) { throw "File move destination exists: $Destination" }
    [IO.File]::Move((Convert-ToExtendedPath $Source), (Convert-ToExtendedPath $Destination))
}

$source = Resolve-FullPath $SourceRoot 'Source release'
$usb = Resolve-FullPath $UsbRoot 'USB root'
Assert-SourceIsNotUsb $source
$manifestFull = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $manifestFull -PathType Leaf)) { throw "Release manifest is missing: $manifestFull" }
if (Test-PathWithin $source $usb -or Test-PathWithin $usb $source) { throw 'Source release and USB root must be separate paths.' }
Assert-NoReparseAncestry $source 'Source release'
Assert-NoReparseAncestry $usb 'USB root'
Assert-NoReparseAncestry $manifestFull 'Release manifest'
Assert-UsbVolume $usb
if (-not [string]::IsNullOrWhiteSpace($SandboxValidationResultPath)) {
    $null = Assert-SandboxProofOutsideDeploymentTrees $SandboxValidationResultPath $source $usb
}

$manifestHash = Get-Sha256 $manifestFull
if (-not [string]::IsNullOrWhiteSpace($ExpectedManifestSha256) -and
    -not $manifestHash.Equals($ExpectedManifestSha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Release manifest hash changed before USB synchronization: expected $ExpectedManifestSha256, actual $manifestHash"
}
$manifest = Get-StrictJson $manifestFull
if ([int]$manifest.SchemaVersion -ne 4 -or [string]$manifest.Package -cne 'Codex Portable USB' -or
    [string]$manifest.Packaging -cne 'CompressedFirstRun') {
    throw 'Unsupported portable release manifest; schema 4 compact packaging is required.'
}

$canonicalDirectories = @(
    'CodexData',
    'CodexData/packages',
    'CodexData/tools',
    'CodexData/tools/launchers'
)
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
$managedRoots = @(
    'CodexPortable.exe',
    'CodexData/tools/launchers',
    'CodexData/packages',
    'CodexData/README.txt',
    'CodexData/THIRD_PARTY.txt',
    'CodexData/portable-release.json'
)
$replacementDirectoryRoots = @('CodexData\tools\launchers', 'CodexData\packages')
$fileRoots = @('CodexPortable.exe', 'CodexData\README.txt', 'CodexData\THIRD_PARTY.txt', 'CodexData\portable-release.json')
$requiredPlugins = [ordered]@{
    'openai-bundled' = @('sites', 'browser', 'chrome', 'computer-use', 'latex', 'deep-research', 'visualize')
    'openai-primary-runtime' = @('documents', 'pdf', 'presentations', 'spreadsheets', 'template-creator')
}
$invalidationRootList = New-Object 'System.Collections.Generic.List[string]'
foreach ($relative in @(
    'CodexData\app\current',
    'CodexData\tools\desktop-payloads',
    'CodexData\tools\dotnet',
    'CodexData\tools\gh',
    'CodexData\data\profile\.cache\codex-runtimes',
    'CodexData\data\profile\.codex\offline-marketplaces'
)) { $invalidationRootList.Add($relative) }
foreach ($catalog in @($requiredPlugins.Keys)) {
    foreach ($plugin in @($requiredPlugins[$catalog])) {
        $invalidationRootList.Add("CodexData\data\profile\.codex\plugins\cache\$catalog\$plugin")
    }
}
$invalidationDirectoryRoots = @($invalidationRootList)
$requiredPluginDirectoryCount = @($requiredPlugins.Keys | ForEach-Object { @($requiredPlugins[$_]).Count } |
    Measure-Object -Sum).Sum

Assert-ExactStringSet @('CodexData', 'CodexPortable.exe') @($manifest.RootEntries) 'Manifest root entries'
Assert-ExactStringSet $canonicalDirectories @($manifest.Directories) 'Manifest directories'
Assert-ExactStringSet $managedRoots @($manifest.ManagedRoots) 'Manifest managed roots'
if ([int]$manifest.DirectoryCount -ne $canonicalDirectories.Count -or
    [int]$manifest.FileCount -ne $canonicalFiles.Count -or
    [int]$manifest.ManagedSummary.FileCount -ne $canonicalFiles.Count) {
    throw 'Manifest compact file or directory counts do not match the schema 4 contract.'
}
if ([string]$manifest.ArchitectureSupport.Bootstrapper -cne 'x86') { throw 'Manifest bootstrapper architecture is not x86.' }
Assert-ExactStringSet @('x86', 'x64', 'arm64') @($manifest.ArchitectureSupport.LauncherCores) 'Manifest launcher architectures'
Assert-ExactStringSet @('x64', 'arm64') @($manifest.ArchitectureSupport.DesktopPackages) 'Manifest desktop package architectures'

$launcherArtifactContract = [ordered]@{
    Bootstrapper = 'CodexPortable.exe'
    X86 = 'CodexData/tools/launchers/CodexPortable.x86.exe'
    X64 = 'CodexData/tools/launchers/CodexPortable.x64.exe'
    Arm64 = 'CodexData/tools/launchers/CodexPortable.arm64.exe'
}
foreach ($artifactName in @($launcherArtifactContract.Keys)) {
    $property = $manifest.LauncherArtifacts.PSObject.Properties[[string]$artifactName]
    if ($null -eq $property -or [string]$property.Value -cne [string]$launcherArtifactContract[$artifactName]) {
        throw "Manifest launcher artifact mismatch: $artifactName"
    }
}

$expected = @{}
foreach ($entry in @($manifest.Files)) {
    $path = [string]$entry.Path
    $sha256 = [string]$entry.Sha256
    $length = [long]$entry.Length
    if (-not ($canonicalFiles -ccontains $path)) { throw "Manifest contains an unexpected compact file: $path" }
    if ($expected.ContainsKey($path)) { throw "Duplicate manifest path: $path" }
    if ($sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $length -le 0) { throw "Manifest has invalid file metadata: $path" }
    $expected[$path] = [pscustomobject]@{ Length = $length; Sha256 = $sha256.ToUpperInvariant() }
}
Assert-ExactStringSet $canonicalFiles @($expected.Keys) 'Manifest files'
if (-not ([string]$manifest.LauncherSha256).Equals([string]$expected['CodexPortable.exe'].Sha256,
    [StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest launcher hash does not match its file entry.' }

$packageContract = [ordered]@{
    Common = [pscustomobject]@{ Path = 'CodexData/packages/LFPortable-common.zip'; Format = 'zip'; Architecture = $null }
    X64 = [pscustomobject]@{ Path = 'CodexData/packages/LFPortable-x64.msix'; Format = 'msix'; Architecture = 'x64' }
    Arm64 = [pscustomobject]@{ Path = 'CodexData/packages/LFPortable-arm64.msix'; Format = 'msix'; Architecture = 'arm64' }
}
foreach ($packageName in @($packageContract.Keys)) {
    $property = $manifest.PackageArtifacts.PSObject.Properties[[string]$packageName]
    if ($null -eq $property) { throw "Manifest package artifact is missing: $packageName" }
    $artifact = $property.Value
    $contract = $packageContract[$packageName]
    if ([string]$artifact.Path -cne [string]$contract.Path -or [string]$artifact.Format -cne [string]$contract.Format) {
        throw "Manifest package artifact contract mismatch: $packageName"
    }
    $metadata = $expected[[string]$contract.Path]
    if ([long]$artifact.Length -ne [long]$metadata.Length -or
        -not ([string]$artifact.Sha256).Equals([string]$metadata.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest package artifact metadata mismatch: $packageName"
    }
    if ($null -ne $contract.Architecture -and
        [string]$artifact.Identity.ProcessorArchitecture -cne [string]$contract.Architecture) {
        throw "Manifest package architecture mismatch: $packageName"
    }
}

Assert-CompactTree $source $canonicalDirectories $canonicalFiles $expected 'Source release'
$launcherVersion = [string]$manifest.LauncherVersion
if ([string]::IsNullOrWhiteSpace($launcherVersion)) { throw 'Manifest launcher version is empty.' }
$releaseVersion = [string]$manifest.ReleaseVersion
if ($releaseVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' -or
    -not $releaseVersion.Equals($launcherVersion, [StringComparison]::Ordinal)) {
    throw 'Manifest ReleaseVersion must be the exact four-part launcher version.'
}
$sandboxValidation = $null
if ($Execute) {
    $sandboxValidation = Assert-SandboxFirstRunValidation $SandboxValidationResultPath $manifestHash `
        $releaseVersion $manifestFull $source $usb
}
if ($null -eq $manifest.PortableReleaseDescriptor -or
    [string]$manifest.PortableReleaseDescriptor.Path -cne 'CodexData/portable-release.json' -or
    [int]$manifest.PortableReleaseDescriptor.SchemaVersion -ne 1 -or
    [int]$manifest.PortableReleaseDescriptor.FileCount -ne 9 -or
    -not ([string]$manifest.PortableReleaseDescriptor.ReleaseVersion).Equals($releaseVersion, [StringComparison]::Ordinal) -or
    -not ([string]$manifest.PortableReleaseDescriptor.LauncherVersion).Equals($launcherVersion, [StringComparison]::Ordinal) -or
    [long]$manifest.PortableReleaseDescriptor.Length -ne [long]$expected['CodexData/portable-release.json'].Length -or
    -not ([string]$manifest.PortableReleaseDescriptor.Sha256).Equals([string]$expected['CodexData/portable-release.json'].Sha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Manifest portable-release.json metadata does not match the compact release contract.'
}
Assert-ExactPropertySet $manifest.PortableReleaseDescriptor @(
    'Path', 'SchemaVersion', 'ReleaseVersion', 'LauncherVersion', 'FileCount', 'Length', 'Sha256'
) 'Manifest PortableReleaseDescriptor'
Assert-PortableReleaseDescriptor $source $expected $releaseVersion 'Source release'
Assert-LauncherSet $source $launcherVersion 'Source release'
$sourceHashes = Get-VerifiedManagedHashes $source $canonicalFiles $expected 'Source release'

if (-not $Execute) {
    [pscustomobject]@{
        Status = 'PlanOnly'
        SchemaVersion = 4
        Packaging = 'CompressedFirstRun'
        SourceRoot = $source
        UsbRoot = $usb
        ManifestSha256 = $manifestHash
        LauncherVersion = $launcherVersion
        ReleaseVersion = $releaseVersion
        LauncherSha256 = $sourceHashes['CodexPortable.exe']
        ManagedFileCount = $expected.Count
        PackageFileCount = $packageContract.Count
        InvalidatedDerivedRootCount = $invalidationDirectoryRoots.Count
        VolumeLabel = 'CODEX_USB'
        SandboxValidationRequiredForExecute = $true
        SandboxValidationResultPath = if ($null -eq $sandboxValidation) { $null } else { $sandboxValidation.ResultPath }
    }
    return
}

function Confirm-PortableUsbMutation([string]$Target, [string]$Action) {
    # The explicit -Execute switch is the write authorization. In Windows
    # PowerShell 5.1 a nested -File invocation can expose a non-null but
    # unusable PSCmdlet whose ShouldProcess dereferences an internal null.
    # Avoid that host-specific path entirely; -WhatIf remains non-mutating.
    if ($WhatIfPreference) {
        Write-Host ("What if: Performing '{0}' on '{1}'" -f $Action, $Target)
        return $false
    }
    return $true
}

if (-not (Confirm-PortableUsbMutation $usb 'Synchronize the verified compact portable release and invalidate derived payloads')) {
    return
}

$launcherMutex = $null
$mutationMutex = $null
$unknownPluginDirectories = @()
$token = [Guid]::NewGuid().ToString('N')
$transactionRoot = Join-Path $usb ('.portable-sync-' + $token)
if (-not (Test-PathWithin $transactionRoot $usb) -or
    $transactionRoot.Equals($usb, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe USB transaction root: $transactionRoot"
}
$stageRoot = Join-Path $transactionRoot 'stage'
$backupRoot = Join-Path $transactionRoot 'backup'
$failedRoot = Join-Path $transactionRoot 'failed'
$activated = New-Object 'System.Collections.Generic.List[object]'
$retainTransaction = $false
try {
    $mutexTimeoutMilliseconds = [Math]::Min([int64][int]::MaxValue,
        [int64]$WaitForPortableExitSeconds * 1000)
    $portableMutexName = Get-PortableMutexName $usb
    $launcherMutex = Acquire-PortableMutex $portableMutexName ([int]$mutexTimeoutMilliseconds) `
        'LF launcher mutex'
    $mutationMutex = Acquire-PortableMutex ($portableMutexName + '-mutation') `
        ([int]$mutexTimeoutMilliseconds) 'LF mutation mutex'
    Wait-ForPortableExit $usb $WaitForPortableExitSeconds
    $unknownPluginDirectories = @(Get-UnknownPluginCacheDirectories $usb $requiredPlugins)

    foreach ($relative in @($replacementDirectoryRoots + $invalidationDirectoryRoots)) {
        $destination = Join-Path $usb $relative
        Assert-NoReparseAncestry $destination "USB directory destination $relative"
        if ((Test-Path -LiteralPath $destination) -and
            -not (Test-Path -LiteralPath $destination -PathType Container)) {
            throw "USB directory destination is not a directory: $relative"
        }
    }
    foreach ($relative in $fileRoots) {
        $destination = Join-Path $usb $relative
        Assert-NoReparseAncestry $destination "USB file destination $relative"
        if ((Test-Path -LiteralPath $destination) -and
            -not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            throw "USB file destination is not a file: $relative"
        }
    }

    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    foreach ($relative in $canonicalDirectories) {
        New-Item -ItemType Directory -Path (Join-Path $stageRoot ($relative -replace '/', '\')) -Force | Out-Null
    }
    foreach ($relative in $canonicalFiles) {
        $src = Join-Path $source ($relative -replace '/', '\')
        $dst = Join-Path $stageRoot ($relative -replace '/', '\')
        [IO.File]::Copy((Convert-ToExtendedPath $src), (Convert-ToExtendedPath $dst), $false)
    }
    Assert-CompactTree $stageRoot $canonicalDirectories $canonicalFiles $expected 'Staged release'
    Assert-PortableReleaseDescriptor $stageRoot $expected $releaseVersion 'Staged release'
    Assert-LauncherSet $stageRoot $launcherVersion 'Staged release'
    $currentManifestHash = Get-Sha256 $manifestFull
    if (-not $currentManifestHash.Equals($manifestHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release manifest changed while the USB synchronization was being staged.'
    }
    # The mutexes block launcher-managed starts and writes. Check once more
    # immediately before activation for tools launched directly from the USB
    # tree while the multi-gigabyte staging copy was in progress.
    Wait-ForPortableExit $usb 0

    foreach ($relative in $replacementDirectoryRoots) {
        $dest = Join-Path $usb $relative
        $stage = Join-Path $stageRoot $relative
        $backup = Join-Path $backupRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        $record = [pscustomobject]@{ Relative = $relative; Destination = $dest; Backup = $backup; ExistingMoved = $false; NewMoved = $false; IsDirectory = $true }
        $activated.Add($record)
        if (Test-Path -LiteralPath $dest) { Move-Directory $dest $backup; $record.ExistingMoved = $true }
        Move-Directory $stage $dest; $record.NewMoved = $true
    }
    foreach ($relative in $fileRoots) {
        $dest = Join-Path $usb $relative
        $stage = Join-Path $stageRoot $relative
        $backup = Join-Path $backupRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        $record = [pscustomobject]@{ Relative = $relative; Destination = $dest; Backup = $backup; ExistingMoved = $false; NewMoved = $false; IsDirectory = $false }
        $activated.Add($record)
        if (Test-Path -LiteralPath $dest) { Move-File $dest $backup; $record.ExistingMoved = $true }
        Move-File $stage $dest; $record.NewMoved = $true
    }
    foreach ($relative in $invalidationDirectoryRoots) {
        $dest = Join-Path $usb $relative
        if (-not (Test-Path -LiteralPath $dest -PathType Container)) { continue }
        $backup = Join-Path $backupRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        $record = [pscustomobject]@{ Relative = $relative; Destination = $dest; Backup = $backup; ExistingMoved = $false; NewMoved = $false; IsDirectory = $true }
        $activated.Add($record)
        Move-Directory $dest $backup
        $record.ExistingMoved = $true
    }

    $usbHashes = Get-VerifiedManagedHashes $usb $canonicalFiles $expected 'USB release'
    Assert-PortableReleaseDescriptor $usb $expected $releaseVersion 'USB release'
    Assert-LauncherSet $usb $launcherVersion 'USB release'
    foreach ($relative in $invalidationDirectoryRoots) {
        if (Test-Path -LiteralPath (Join-Path $usb $relative)) {
            throw "Derived USB root was not invalidated: $relative"
        }
    }
    foreach ($relative in $unknownPluginDirectories) {
        if (-not (Test-Path -LiteralPath (Join-Path $usb ($relative -replace '/', '\')) -PathType Container)) {
            throw "Unknown plugin cache directory was not preserved: $relative"
        }
    }
    $finalManifestHash = Get-Sha256 $manifestFull
    if (-not $finalManifestHash.Equals($manifestHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release manifest changed before USB synchronization completed.'
    }
    $result = [pscustomobject]@{
        Status = 'Synced'
        SchemaVersion = 4
        Packaging = 'CompressedFirstRun'
        SourceRoot = $source
        UsbRoot = $usb
        ManifestSha256 = $manifestHash
        LauncherVersion = $launcherVersion
        ReleaseVersion = $releaseVersion
        LauncherSha256 = $sourceHashes['CodexPortable.exe']
        BootstrapperSha256 = $sourceHashes['CodexPortable.exe']
        UsbBootstrapperSha256 = $usbHashes['CodexPortable.exe']
        ManagedFileCount = $expected.Count
        PackageFileCount = $packageContract.Count
        PackageSha256 = [ordered]@{
            Common = $usbHashes['CodexData/packages/LFPortable-common.zip']
            X64 = $usbHashes['CodexData/packages/LFPortable-x64.msix']
            Arm64 = $usbHashes['CodexData/packages/LFPortable-arm64.msix']
        }
        InvalidatedDerivedRoots = @($invalidationDirectoryRoots | ForEach-Object { $_.Replace('\', '/') })
        RequiredPluginCacheDirectoriesInvalidated = [int]$requiredPluginDirectoryCount
        UnknownPluginCacheDirectoriesPreserved = @($unknownPluginDirectories)
        SandboxValidation = $sandboxValidation
        PreservedRoots = @(
            'CodexData/data except the declared derived runtime, marketplace, and required plugin-cache roots',
            'CodexData/logs',
            'CodexData/updates',
            'CodexData/app/rollback',
            'unknown USB files and directories'
        )
    }
    $result
}
catch {
    $failure = $_
    $rollbackFailures = New-Object 'System.Collections.Generic.List[string]'
    for ($index = $activated.Count - 1; $index -ge 0; $index--) {
        $record = $activated[$index]
        try {
            $failed = Join-Path $failedRoot $record.Relative
            if ($record.NewMoved -and (Test-Path -LiteralPath $record.Destination)) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $failed) -Force | Out-Null
                if ($record.IsDirectory) { Move-Directory $record.Destination $failed } else { Move-File $record.Destination $failed }
            }
            if ($record.ExistingMoved -and (Test-Path -LiteralPath $record.Backup)) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $record.Destination) -Force | Out-Null
                if ($record.IsDirectory) { Move-Directory $record.Backup $record.Destination } else { Move-File $record.Backup $record.Destination }
            }
        }
        catch { $rollbackFailures.Add("$($record.Relative): $($_.Exception.Message)") }
    }
    if ($rollbackFailures.Count -ne 0) {
        # Keep the same-volume backup available for manual recovery.  Deleting
        # it in finally would turn a recoverable rollback failure into data
        # loss, especially if the USB volume was disconnected mid-transaction.
        $retainTransaction = $true
        throw "USB synchronization failed and rollback failed: $($rollbackFailures -join '; '); original: $($failure.Exception.Message); transaction retained at $transactionRoot"
    }
    throw $failure
}
finally {
    if (-not $retainTransaction -and $null -ne $transactionRoot -and (Test-Path -LiteralPath $transactionRoot)) {
        try { Remove-Item -LiteralPath (Convert-ToExtendedPath $transactionRoot) -Recurse -Force -ErrorAction Stop }
        catch { Write-Warning "USB synchronization completed or rolled back, but transaction cleanup failed: $transactionRoot ($($_.Exception.Message))" }
    }
    elseif ($retainTransaction) {
        Write-Warning "USB synchronization transaction retained for recovery: $transactionRoot"
    }
    Release-PortableMutex $mutationMutex
    Release-PortableMutex $launcherMutex
}
