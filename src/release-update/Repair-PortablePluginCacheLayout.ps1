[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$PortableRoot,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path does not exist: $Path"
    }
    return [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path).TrimEnd('\')
}

function Read-PluginManifest([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing .codex-plugin/plugin.json: $Path"
    }
    try {
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $json = [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$Label has an invalid plugin manifest: $Path ($($_.Exception.Message))"
    }
    $version = [string]$json.version
    if ([string]::IsNullOrWhiteSpace($version) -or
        $version.Equals('latest', [StringComparison]::OrdinalIgnoreCase) -or
        $version -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') {
        throw "$Label has no safe plugin version: $Path"
    }
    [pscustomobject]@{
        Name = [string]$json.name
        Version = $version
        Manifest = $Path
    }
}

function Assert-NoReparsePoint([string]$Path, [string]$Label) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label is a reparse point: $Path"
    }
}

function Initialize-ExecutionVolumeInterop {
    if ($null -ne ('LFPortable.ExecutionVolumeNative' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace LFPortable
{
    public static class ExecutionVolumeNative
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetVolumeInformation(
            string rootPathName,
            string volumeNameBuffer,
            uint volumeNameSize,
            out uint volumeSerialNumber,
            out uint maximumComponentLength,
            out uint fileSystemFlags,
            string fileSystemNameBuffer,
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
    catch {
        # A path token remains stable enough to isolate execution images when a
        # volume serial is unavailable (for example, a redirected test root).
    }

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

        # Execution-image identity is defined by the launcher version and the
        # immutable common/MSIX release hashes. No legacy naming is accepted.
        $match = [regex]::Match($segments[1],
            '^desktop-lf-(?<launcher>[^-]+)-pkg-c-(?<common>[0-9a-f]{16})-d-(?<desktop>[0-9a-f]{16})$',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) { return $false }
        $launcherVersion = $null
        if (-not [Version]::TryParse($match.Groups['launcher'].Value, [ref]$launcherVersion) -or
            -not [string]::Equals($match.Groups['launcher'].Value, $launcherVersion.ToString(),
                [StringComparison]::Ordinal)) {
            return $false
        }
        return $true
    }
    catch { return $false }
}

function Assert-NoPortableProcesses([string]$Root) {
    $executionFamilyRoot = Get-ExecutionFamilyRoot $Root
    $managedRoots = @(
        (Join-Path $Root 'CodexData\app\current'),
        (Join-Path $Root 'CodexData\tools\desktop-payloads'),
        (Join-Path $Root 'CodexData\tools\dotnet'),
        (Join-Path $Root 'CodexData\tools\gh'),
        (Join-Path $Root 'CodexData\data\profile\.cache\codex-runtimes'),
        (Join-Path $Root 'CodexData\data\profile\.codex\offline-marketplaces'),
        (Join-Path $Root 'CodexData\data\profile\.codex\plugins\cache')
    ) | ForEach-Object { $_.TrimEnd('\') + '\' }
    $isManagedPath = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        $full = [IO.Path]::GetFullPath($Path)
        foreach ($managedRoot in $managedRoots) {
            if ($full.StartsWith($managedRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        if (Test-ExecutionDesktopProcessPath $full $executionFamilyRoot) { return $true }
        return $false
    }
    try {
        $running = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            & $isManagedPath ([string]$_.ExecutablePath)
        })
    }
    catch {
        # Some locked-down hosts deny Win32_Process queries. Get-Process still
        # exposes the executable path for ordinary user-owned processes; use it
        # as a conservative fallback and fail only if a matching process is
        # actually visible.
        $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try {
                $path = $_.Path
                & $isManagedPath $path
            }
            catch { $false }
        })
    }
    if ($running.Count -ne 0) {
        throw "Portable processes are still running from ${Root}: $($running.Name -join ', ')"
    }
}

function Invoke-RobocopyChecked([string]$Source, [string]$Destination) {
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /MT:8 /XJ /NFL /NDL /NP /NJH /NJS | Out-Null
    $code = $LASTEXITCODE
    if ($code -gt 7) {
        throw "Plugin staging copy failed ($code): $Source -> $Destination"
    }
    return $code
}

function Assert-VersionedPlugin([string]$PluginRoot, [string]$Catalog, [string]$Plugin) {
    Assert-NoReparsePoint $PluginRoot "$Catalog/$Plugin"
    $directFiles = @(Get-ChildItem -LiteralPath $PluginRoot -File -Force -ErrorAction Stop)
    if ($directFiles.Count -ne 0) {
        throw "Flattened plugin cache entry: $PluginRoot"
    }
    $versions = @(Get-ChildItem -LiteralPath $PluginRoot -Directory -Force -ErrorAction Stop)
    if ($versions.Count -ne 1) {
        throw "Expected exactly one staged version for $Catalog/$Plugin; found $($versions.Count)."
    }
    if ($versions[0].Name -eq '.codex-plugin') {
        throw "Flattened plugin cache entry: $PluginRoot"
    }
    $versionRoot = $versions[0]
    $manifest = Read-PluginManifest (Join-Path $versionRoot.FullName '.codex-plugin\plugin.json') "$Catalog/$Plugin/$($versionRoot.Name)"
    # Keep the cache contract identical to the launcher: it opens
    # <plugin>/<manifest.version>, never a floating `latest` alias.
    if (-not $versionRoot.Name.Equals($manifest.Version, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Version directory '$($versionRoot.Name)' does not match manifest '$($manifest.Version)' for $Catalog/$Plugin."
    }
    if (-not $manifest.Name.Equals($Plugin, [StringComparison]::Ordinal)) {
        throw "Plugin manifest name '$($manifest.Name)' does not match plugin id '$Plugin' for $Catalog."
    }
    return $manifest
}

function Get-RelativeTreePath([string]$Root, [string]$Path) {
    return $Path.Substring($Root.Length).TrimStart('\')
}

function Get-RelativeParentPath([string]$Path) {
    $separator = $Path.LastIndexOf('\')
    if ($separator -lt 0) { return '' }
    return $Path.Substring(0, $separator)
}

function Get-RelativeLeafName([string]$Path) {
    $separator = $Path.LastIndexOf('\')
    if ($separator -lt 0) { return $Path }
    return $Path.Substring($separator + 1)
}

function Test-AllowedRuntimeGeneratedDirectory([string]$Relative, [hashtable]$SourceDirectories) {
    $parent = Get-RelativeParentPath $Relative
    return (Get-RelativeLeafName $Relative).Equals('__pycache__', [StringComparison]::OrdinalIgnoreCase) -and
        ($parent.Length -eq 0 -or $SourceDirectories.ContainsKey($parent))
}

function Test-AllowedRuntimeGeneratedFile([string]$Relative, [hashtable]$GeneratedDirectories) {
    $parent = Get-RelativeParentPath $Relative
    return $GeneratedDirectories.ContainsKey($parent) -and
        (Get-RelativeLeafName $Relative).EndsWith('.pyc', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-PluginTreeMatchesSource([string]$SourcePlugin, [string]$CacheVersionRoot,
    [string]$Catalog, [string]$Plugin) {
    $sourceFiles = @(Get-ChildItem -LiteralPath $SourcePlugin -Recurse -Force -File -ErrorAction Stop |
        ForEach-Object { Get-RelativeTreePath $SourcePlugin $_.FullName } | Sort-Object)
    $cacheFiles = @(Get-ChildItem -LiteralPath $CacheVersionRoot -Recurse -Force -File -ErrorAction Stop |
        ForEach-Object { Get-RelativeTreePath $CacheVersionRoot $_.FullName } | Sort-Object)
    $sourceDirectories = @(Get-ChildItem -LiteralPath $SourcePlugin -Recurse -Force -Directory -ErrorAction Stop |
        ForEach-Object { Get-RelativeTreePath $SourcePlugin $_.FullName } | Sort-Object)
    $cacheDirectories = @(Get-ChildItem -LiteralPath $CacheVersionRoot -Recurse -Force -Directory -ErrorAction Stop |
        ForEach-Object { Get-RelativeTreePath $CacheVersionRoot $_.FullName } | Sort-Object)
    $sourceFileMap = @{}
    $cacheFileMap = @{}
    $sourceDirectoryMap = @{}
    $cacheDirectoryMap = @{}
    $generatedDirectoryMap = @{}
    foreach ($relative in $sourceFiles) {
        if ($sourceFileMap.ContainsKey($relative)) { throw "Trusted plugin source has an ambiguous file: $relative" }
        $sourceFileMap[$relative] = $true
    }
    foreach ($relative in $cacheFiles) {
        if ($cacheFileMap.ContainsKey($relative)) { throw "Plugin cache has an ambiguous file: $relative" }
        $cacheFileMap[$relative] = $true
    }
    foreach ($relative in $sourceDirectories) {
        if ($sourceDirectoryMap.ContainsKey($relative)) { throw "Trusted plugin source has an ambiguous directory: $relative" }
        $sourceDirectoryMap[$relative] = $true
    }
    foreach ($relative in $cacheDirectories) {
        if ($cacheDirectoryMap.ContainsKey($relative)) { throw "Plugin cache has an ambiguous directory: $relative" }
        $cacheDirectoryMap[$relative] = $true
    }
    foreach ($relative in $sourceDirectories) {
        if (-not $cacheDirectoryMap.ContainsKey($relative)) {
            throw "Plugin cache is missing trusted directory for $Catalog/${Plugin}: $relative"
        }
    }
    foreach ($relative in $cacheDirectories) {
        if ($sourceDirectoryMap.ContainsKey($relative)) { continue }
        if (-not (Test-AllowedRuntimeGeneratedDirectory $relative $sourceDirectoryMap)) {
            throw "Plugin cache has an unexpected directory for $Catalog/${Plugin}: $relative"
        }
        $generatedDirectoryMap[$relative] = $true
    }
    foreach ($relative in $sourceFiles) {
        if (-not $cacheFileMap.ContainsKey($relative)) {
            throw "Plugin cache is missing trusted file for $Catalog/${Plugin}: $relative"
        }
        $sourceFile = Join-Path $SourcePlugin $relative
        $cacheFile = Join-Path $CacheVersionRoot $relative
        $sourceItem = Get-Item -LiteralPath $sourceFile -Force -ErrorAction Stop
        $cacheItem = Get-Item -LiteralPath $cacheFile -Force -ErrorAction Stop
        if ($sourceItem.Length -ne $cacheItem.Length -or
            (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $cacheFile -Algorithm SHA256).Hash) {
            throw "Plugin file differs from the trusted source for $Catalog/${Plugin}: $relative"
        }
    }
    foreach ($relative in $cacheFiles) {
        if ($sourceFileMap.ContainsKey($relative)) { continue }
        if (-not (Test-AllowedRuntimeGeneratedFile $relative $generatedDirectoryMap)) {
            throw "Plugin cache has an unexpected file for $Catalog/${Plugin}: $relative"
        }
    }
}

function Move-DirectoryAtomically([string]$Source, [string]$Destination) {
    $sourceFull = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $destinationFull = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if (-not [IO.Path]::GetPathRoot($sourceFull).Equals([IO.Path]::GetPathRoot($destinationFull), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Plugin cache replacement must stay on one volume: $sourceFull -> $destinationFull"
    }
    if (-not [IO.Directory]::Exists($sourceFull)) { throw "Staged plugin directory is missing: $sourceFull" }
    if ([IO.Directory]::Exists($destinationFull) -or [IO.File]::Exists($destinationFull)) {
        throw "Plugin cache replacement destination already exists: $destinationFull"
    }
    [IO.Directory]::Move($sourceFull, $destinationFull)
}

function Assert-PortablePathBudget([string]$Path, [string]$Label) {
    # The bundled launcher still calls a few legacy Win32/.NET path APIs. Keep
    # the deepest known native-module path below MAX_PATH so a repair cannot
    # silently create directories while dropping the files at the end.
    if ($Path.Length -ge 240) {
        throw "$Label is too deep for the portable launcher ($($Path.Length) characters): $Path. Place the USB package near the drive root."
    }
}

function Get-InstalledPayloadContract([string]$Root) {
    $candidates = @(
        [pscustomobject]@{
            Architecture = 'x64'
            PayloadRoot = Join-Path $Root 'CodexData\app\current'
            BundledPlugins = @('sites', 'browser', 'chrome', 'computer-use', 'latex', 'deep-research', 'visualize')
        },
        [pscustomobject]@{
            Architecture = 'arm64'
            PayloadRoot = Join-Path $Root 'CodexData\tools\desktop-payloads\arm64\current'
            BundledPlugins = @('sites', 'browser', 'chrome', 'computer-use', 'deep-research', 'visualize')
        }
    )
    $installed = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate.PayloadRoot)) { continue }
        if (-not (Test-Path -LiteralPath $candidate.PayloadRoot -PathType Container)) {
            throw "Installed $($candidate.Architecture) payload root is not a directory: $($candidate.PayloadRoot)"
        }
        Assert-NoReparsePoint $candidate.PayloadRoot "Installed $($candidate.Architecture) payload root"
        $markerPath = Join-Path $candidate.PayloadRoot '.portable-package.txt'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            throw "Installed $($candidate.Architecture) payload has no package marker: $markerPath"
        }
        Assert-NoReparsePoint $markerPath "Installed $($candidate.Architecture) payload marker"
        try {
            $marker = [IO.File]::ReadAllLines($markerPath, (New-Object Text.UTF8Encoding($false, $true)))
        }
        catch {
            throw "Installed $($candidate.Architecture) payload marker is unreadable: $markerPath ($($_.Exception.Message))"
        }
        if ($marker.Length -ne 4 -or $marker[0].Trim() -cne 'OpenAI.Codex' -or
            $marker[1].Trim() -cne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B' -or
            $marker[2].Trim() -notmatch '^\d+\.\d+\.\d+\.\d+$' -or
            $marker[3].Trim() -cne $candidate.Architecture) {
            throw "Installed $($candidate.Architecture) payload marker does not match the LF package contract: $markerPath"
        }
        $bundledSource = Join-Path $candidate.PayloadRoot 'resources\plugins\openai-bundled\plugins'
        if (-not (Test-Path -LiteralPath $bundledSource -PathType Container)) {
            throw "Installed $($candidate.Architecture) bundled plugin source is missing: $bundledSource"
        }
        Assert-NoReparsePoint $bundledSource "Installed $($candidate.Architecture) bundled plugin source"
        $candidate | Add-Member -NotePropertyName BundledSource -NotePropertyValue $bundledSource
        $installed.Add($candidate)
    }
    if ($installed.Count -eq 0) {
        throw 'No supported installed x64 or ARM64 payload was found. Start Codex once before repairing its plugin cache.'
    }
    if ($installed.Count -ne 1) {
        throw 'More than one installed payload architecture was found. Plugin-cache repair requires one unambiguous current payload.'
    }
    return $installed[0]
}

$root = Get-FullPath $PortableRoot
$payload = Get-InstalledPayloadContract $root
$sourceByCatalog = [ordered]@{
    'openai-bundled' = $payload.BundledSource
    'openai-primary-runtime' = Join-Path $root 'CodexData\data\profile\.codex\offline-marketplaces\openai-primary-runtime\plugins'
}
$requiredByCatalog = [ordered]@{
    'openai-bundled' = @($payload.BundledPlugins)
    'openai-primary-runtime' = @('documents', 'pdf', 'presentations', 'spreadsheets', 'template-creator')
}
$cacheRoot = Join-Path $root 'CodexData\data\profile\.codex\plugins\cache'
$pluginRoot = Join-Path $root 'CodexData\data\profile\.codex\plugins'
foreach ($path in @($cacheRoot, $pluginRoot)) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Portable plugin directory is missing: $path" }
}
Assert-NoPortableProcesses $root

$id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 10)
$stageRoot = Join-Path $pluginRoot ('.portable-plugin-cache-stage-' + $id)
$backupRoot = Join-Path (Join-Path $pluginRoot 'repair-backups') $id
$changes = New-Object 'System.Collections.Generic.List[object]'

foreach ($catalog in $sourceByCatalog.Keys) {
    $sourceCatalog = $sourceByCatalog[$catalog]
    $targetCatalog = Join-Path $cacheRoot $catalog
    if (-not (Test-Path -LiteralPath $sourceCatalog -PathType Container)) { throw "Trusted plugin source is missing: $sourceCatalog" }
    if (-not (Test-Path -LiteralPath $targetCatalog -PathType Container)) { throw "Plugin cache catalog is missing: $targetCatalog" }
    Assert-NoReparsePoint $sourceCatalog "$catalog source"
    Assert-NoReparsePoint $targetCatalog "$catalog cache"

    foreach ($plugin in $requiredByCatalog[$catalog]) {
        $sourcePlugin = Join-Path $sourceCatalog $plugin
        if (-not (Test-Path -LiteralPath $sourcePlugin -PathType Container)) { throw "Trusted plugin source is missing: $sourcePlugin" }
        $sourceManifest = Read-PluginManifest (Join-Path $sourcePlugin '.codex-plugin\plugin.json') "$catalog/$plugin source"
        $targetPlugin = Join-Path $targetCatalog $plugin
        $pathProbe = Join-Path $targetPlugin ($sourceManifest.Version + '\scripts\node_modules\classic-level\deps\leveldb\leveldb-1.20\helpers\memenv\memenv.cc')
        if (Test-Path -LiteralPath (Join-Path $sourcePlugin 'scripts\node_modules\classic-level') -PathType Container) {
            Assert-PortablePathBudget $pathProbe "$catalog/$plugin cache path"
        }
        $targetValid = $false
        if (Test-Path -LiteralPath $targetPlugin -PathType Container) {
            try {
                $targetManifest = Assert-VersionedPlugin $targetPlugin $catalog $plugin
                if ($targetManifest.Version.Equals($sourceManifest.Version, [StringComparison]::OrdinalIgnoreCase)) {
                    $targetVersionRoot = Join-Path $targetPlugin $sourceManifest.Version
                    Assert-PluginTreeMatchesSource $sourcePlugin $targetVersionRoot $catalog $plugin
                    $targetValid = $true
                }
            }
            catch { $targetValid = $false }
        }
        if ($targetValid) {
            $changes.Add([pscustomobject]@{ Catalog = $catalog; Plugin = $plugin; Action = 'AlreadyVersioned'; Version = $sourceManifest.Version })
            continue
        }

        $stagePlugin = Join-Path (Join-Path $stageRoot $catalog) $plugin
        $stageVersion = Join-Path $stagePlugin $sourceManifest.Version
        Invoke-RobocopyChecked $sourcePlugin $stageVersion | Out-Null
        $stagedManifest = Assert-VersionedPlugin $stagePlugin $catalog $plugin
        if (-not $stagedManifest.Version.Equals($sourceManifest.Version, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Staged plugin version changed while copying: $catalog/$plugin"
        }
        Assert-PluginTreeMatchesSource $sourcePlugin $stageVersion $catalog $plugin
        $changes.Add([pscustomobject]@{ Catalog = $catalog; Plugin = $plugin; Action = 'Replace'; Version = $sourceManifest.Version; Target = $targetPlugin })
    }
}

if (-not $Execute) {
    [pscustomobject]@{
        Status = 'PlanOnly'
        PortableRoot = $root
        Architecture = $payload.Architecture
        Changes = $changes.ToArray()
        StageRoot = $stageRoot
    } | ConvertTo-Json -Depth 6
    if (Test-Path -LiteralPath $stageRoot) { [IO.Directory]::Delete($stageRoot, $true) }
    $global:LASTEXITCODE = 0
    return
}

if (-not $PSCmdlet.ShouldProcess($cacheRoot, 'Atomically replace flattened or stale plugin cache entries')) {
    if (Test-Path -LiteralPath $stageRoot) { [IO.Directory]::Delete($stageRoot, $true) }
    return
}

$activated = New-Object 'System.Collections.Generic.List[object]'
try {
    [IO.Directory]::CreateDirectory($backupRoot) | Out-Null
    foreach ($change in $changes | Where-Object { $_.Action -eq 'Replace' }) {
        $target = [string]$change.Target
        $stagePlugin = Join-Path (Join-Path $stageRoot $change.Catalog) $change.Plugin
        $backupPlugin = Join-Path (Join-Path $backupRoot $change.Catalog) $change.Plugin
        [IO.Directory]::CreateDirectory((Split-Path -Parent $backupPlugin)) | Out-Null
        if (Test-Path -LiteralPath $target -PathType Container) {
            Move-DirectoryAtomically $target $backupPlugin
        }
        Move-DirectoryAtomically $stagePlugin $target
        Assert-VersionedPlugin $target $change.Catalog $change.Plugin | Out-Null
        Assert-PluginTreeMatchesSource (Join-Path $sourceByCatalog[$change.Catalog] $change.Plugin) `
            (Join-Path $target $change.Version) $change.Catalog $change.Plugin
        $activated.Add($change)
    }
    if (Test-Path -LiteralPath $stageRoot) { [IO.Directory]::Delete($stageRoot, $true) }
    [pscustomobject]@{
        Status = 'Verified'
        PortableRoot = $root
        Architecture = $payload.Architecture
        BackupRoot = $backupRoot
        Changes = $activated.ToArray()
    } | ConvertTo-Json -Depth 6
    $global:LASTEXITCODE = 0
}
catch {
    $failure = $_
    foreach ($change in @($activated | Sort-Object -Property Catalog, Plugin -Descending)) {
        $target = [string]$change.Target
        $backupPlugin = Join-Path (Join-Path $backupRoot $change.Catalog) $change.Plugin
        $failedPlugin = $target + '.failed-' + $id
        try {
            if (Test-Path -LiteralPath $target -PathType Container) { Move-DirectoryAtomically $target $failedPlugin }
            if (Test-Path -LiteralPath $backupPlugin -PathType Container) { Move-DirectoryAtomically $backupPlugin $target }
        }
        catch { throw "Plugin cache repair failed and rollback failed for ${target}: $($_.Exception.Message)" }
    }
    throw $failure
}
