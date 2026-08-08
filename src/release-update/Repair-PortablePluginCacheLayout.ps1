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
    if ([string]::IsNullOrWhiteSpace($version) -or $version -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') {
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

function Assert-NoPortableProcesses([string]$Root) {
    $prefix = $Root.TrimEnd('\') + '\'
    try {
        $running = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $null -ne $_.ExecutablePath -and
            ([string]$_.ExecutablePath).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
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
                $null -ne $path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
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
    if ($versionRoot.Name -ne 'latest' -and -not $versionRoot.Name.Equals($manifest.Version, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Version directory '$($versionRoot.Name)' does not match manifest '$($manifest.Version)' for $Catalog/$Plugin."
    }
    return $manifest
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

$root = Get-FullPath $PortableRoot
$sourceByCatalog = [ordered]@{
    'openai-bundled' = Join-Path $root 'CodexData\app\current\resources\plugins\openai-bundled\plugins'
    'openai-primary-runtime' = Join-Path $root 'CodexData\data\profile\.codex\offline-marketplaces\openai-primary-runtime\plugins'
}
$requiredByCatalog = [ordered]@{
    'openai-bundled' = @('browser', 'chrome', 'computer-use', 'latex', 'visualize')
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
                $targetValid = $targetManifest.Version.Equals($sourceManifest.Version, [StringComparison]::OrdinalIgnoreCase)
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
        $changes.Add([pscustomobject]@{ Catalog = $catalog; Plugin = $plugin; Action = 'Replace'; Version = $sourceManifest.Version; Target = $targetPlugin })
    }
}

if (-not $Execute) {
    [pscustomobject]@{
        Status = 'PlanOnly'
        PortableRoot = $root
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
        $activated.Add($change)
    }
    if (Test-Path -LiteralPath $stageRoot) { [IO.Directory]::Delete($stageRoot, $true) }
    [pscustomobject]@{
        Status = 'Verified'
        PortableRoot = $root
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
