[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    # Must not exist. The validator never removes or reuses this directory.
    [Parameter(Mandatory = $true)]
    [string]$TargetRoot,

    # Defaults to a sibling of TargetRoot and is retained as the audit result.
    [string]$ResultPath,

    [ValidateRange(15, 600)]
    [int]$TimeoutSeconds = 180,

    [switch]$LeaveLauncherRunning
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedDirectories = @(
    'CodexData',
    'CodexData/packages',
    'CodexData/tools',
    'CodexData/tools/launchers'
)
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

function Get-NormalizedFullPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    while ($full.Length -gt $root.Length -and
        ($full.EndsWith('\', [StringComparison]::Ordinal) -or
            $full.EndsWith('/', [StringComparison]::Ordinal))) {
        $full = $full.Substring(0, $full.Length - 1)
    }
    return $full
}

function Test-PathWithin([string]$Candidate, [string]$Root) {
    if ($Candidate.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = if ($Root.EndsWith('\', [StringComparison]::Ordinal) -or
        $Root.EndsWith('/', [StringComparison]::Ordinal)) { $Root } else { $Root + '\' }
    return $Candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NotUsbPath([string]$Path, [string]$Label) {
    if ($Path -notmatch '^[A-Za-z]:') { return }
    $drive = New-Object IO.DriveInfo($Path.Substring(0, 2))
    if (-not $drive.IsReady) {
        throw "$Label drive is not ready: $Path"
    }
    if ($drive.DriveType -eq [IO.DriveType]::Removable -or
        [string]::Equals($drive.VolumeLabel, 'CODEX_USB', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must not be a USB installation. Use a fixed-disk release and a new fixed-disk Sandbox target."
    }
}

function Get-RelativePortablePath([string]$Root, [string]$Path) {
    return $Path.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
}

function Assert-ExactStringSet([string[]]$Expected, [string[]]$Actual, [string]$Label) {
    $difference = @(Compare-Object -ReferenceObject @($Expected | Sort-Object) -DifferenceObject @($Actual | Sort-Object))
    if ($difference.Count -ne 0) {
        $values = @($difference | Select-Object -First 12 | ForEach-Object { [string]$_.InputObject })
        throw "$Label differs from the compact release contract: $($values -join ', ')"
    }
}

function Get-CompactReleaseSnapshot([string]$Root, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "$Label is missing: $Root"
    }
    $reparsePoints = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop)
    if ($reparsePoints.Count -ne 0) {
        throw "$Label contains reparse points: $($reparsePoints[0].FullName)"
    }
    $directories = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -Directory -ErrorAction Stop |
        ForEach-Object { Get-RelativePortablePath $Root $_.FullName })
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction Stop |
        ForEach-Object { Get-RelativePortablePath $Root $_.FullName })
    Assert-ExactStringSet $expectedDirectories $directories "$Label directories"
    Assert-ExactStringSet $expectedFiles $files "$Label files"

    $metadata = [ordered]@{}
    foreach ($relative in $expectedFiles) {
        $full = Join-Path $Root ($relative.Replace('/', '\'))
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        $metadata[$relative] = [ordered]@{
            Length = [long]$item.Length
            Sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpperInvariant()
        }
    }
    return [pscustomobject]@{
        Root = $Root
        DirectoryCount = $directories.Count
        FileCount = $files.Count
        Files = $metadata
    }
}

function Get-StrictJson([string]$Path) {
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    return [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json -ErrorAction Stop
}

function Get-ObjectPropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Assert-ExactPropertySet($Object, [string[]]$Expected, [string]$Label) {
    $actual = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actual.Count -ne $Expected.Count -or
        @($Expected | Where-Object { -not ($actual -ccontains $_) }).Count -ne 0 -or
        @($actual | Where-Object { -not ($Expected -ccontains $_) }).Count -ne 0) {
        throw "$Label has an unsupported property set: $($actual -join ', ')"
    }
}

function Assert-PortableReleaseDescriptor([string]$Root, $Snapshot, [string]$ExpectedVersion, [string]$Label) {
    $descriptorPath = Join-Path $Root 'CodexData\portable-release.json'
    $descriptor = Get-StrictJson $descriptorPath
    Assert-ExactPropertySet $descriptor @('SchemaVersion', 'ReleaseVersion', 'LauncherVersion', 'Files') `
        "$Label portable-release.json"
    if ([int](Get-ObjectPropertyValue $descriptor 'SchemaVersion') -ne 1 -or
        -not [string]::Equals([string](Get-ObjectPropertyValue $descriptor 'ReleaseVersion'), $ExpectedVersion, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string](Get-ObjectPropertyValue $descriptor 'LauncherVersion'), $ExpectedVersion, [StringComparison]::Ordinal)) {
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
    $files = @(Get-ObjectPropertyValue $descriptor 'Files')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if ($files.Count -ne $descriptorFiles.Count) {
        throw "$Label portable-release.json must contain exactly $($descriptorFiles.Count) file entries."
    }
    foreach ($entry in $files) {
        Assert-ExactPropertySet $entry @('Path', 'Length', 'Sha256') "$Label portable-release.json file entry"
        $relative = [string](Get-ObjectPropertyValue $entry 'Path')
        if (-not ($descriptorFiles -ccontains $relative) -or -not $seen.Add($relative)) {
            throw "$Label portable-release.json contains an unexpected or duplicate file entry: $relative"
        }
        $expected = $Snapshot.Files[$relative]
        if ($null -eq $expected -or
            [long](Get-ObjectPropertyValue $entry 'Length') -ne [long]$expected.Length -or
            -not [string]::Equals([string](Get-ObjectPropertyValue $entry 'Sha256'), [string]$expected.Sha256,
                [StringComparison]::Ordinal)) {
            throw "$Label portable-release.json hash or length differs for: $relative"
        }
    }
    foreach ($relative in $descriptorFiles) {
        if (-not $seen.Contains($relative)) { throw "$Label portable-release.json is missing: $relative" }
    }
}

function Assert-ManifestMatchesSnapshot([string]$Path, $Snapshot, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Release manifest is missing: $Path"
    }
    $manifest = Get-StrictJson $Path
    if ([int](Get-ObjectPropertyValue $manifest 'SchemaVersion') -ne 4 -or
        [string](Get-ObjectPropertyValue $manifest 'Package') -cne 'Codex Portable USB' -or
        [string](Get-ObjectPropertyValue $manifest 'Packaging') -cne 'CompressedFirstRun') {
        throw 'Release manifest is not the schema 4 CompressedFirstRun contract.'
    }
    $files = @(Get-ObjectPropertyValue $manifest 'Files')
    $manifestPaths = @($files | ForEach-Object { [string](Get-ObjectPropertyValue $_ 'Path') })
    Assert-ExactStringSet $expectedFiles $manifestPaths 'Release manifest files'
    foreach ($file in $files) {
        $relative = [string](Get-ObjectPropertyValue $file 'Path')
        $expected = $Snapshot.Files[$relative]
        if ($null -eq $expected) {
            throw "Release manifest contains an unexpected file: $relative"
        }
        if ([long](Get-ObjectPropertyValue $file 'Length') -ne [long]$expected.Length -or
            -not [string]::Equals([string](Get-ObjectPropertyValue $file 'Sha256'),
                [string]$expected.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Release manifest hash or length differs for: $relative"
        }
    }
    $launcherHash = [string](Get-ObjectPropertyValue $manifest 'LauncherSha256')
    if (-not [string]::Equals($launcherHash, [string]$Snapshot.Files['CodexPortable.exe'].Sha256,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release manifest launcher hash differs from CodexPortable.exe.'
    }
    $launcherVersion = [string](Get-ObjectPropertyValue $manifest 'LauncherVersion')
    $releaseVersion = [string](Get-ObjectPropertyValue $manifest 'ReleaseVersion')
    if ($launcherVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' -or
        -not [string]::Equals($releaseVersion, $launcherVersion, [StringComparison]::Ordinal)) {
        throw 'Release manifest ReleaseVersion must equal the four-part LauncherVersion.'
    }
    $descriptorMetadata = Get-ObjectPropertyValue $manifest 'PortableReleaseDescriptor'
    if ($null -eq $descriptorMetadata -or
        [string](Get-ObjectPropertyValue $descriptorMetadata 'Path') -cne 'CodexData/portable-release.json' -or
        [int](Get-ObjectPropertyValue $descriptorMetadata 'SchemaVersion') -ne 1 -or
        [int](Get-ObjectPropertyValue $descriptorMetadata 'FileCount') -ne 9 -or
        -not [string]::Equals([string](Get-ObjectPropertyValue $descriptorMetadata 'ReleaseVersion'), $releaseVersion,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals([string](Get-ObjectPropertyValue $descriptorMetadata 'LauncherVersion'), $launcherVersion,
            [StringComparison]::Ordinal) -or
        [long](Get-ObjectPropertyValue $descriptorMetadata 'Length') -ne [long]$Snapshot.Files['CodexData/portable-release.json'].Length -or
        -not [string]::Equals([string](Get-ObjectPropertyValue $descriptorMetadata 'Sha256'),
            [string]$Snapshot.Files['CodexData/portable-release.json'].Sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release manifest portable-release.json metadata differs from the compact release.'
    }
    Assert-ExactPropertySet $descriptorMetadata @(
        'Path', 'SchemaVersion', 'ReleaseVersion', 'LauncherVersion', 'FileCount', 'Length', 'Sha256'
    ) 'Release manifest PortableReleaseDescriptor'
    Assert-PortableReleaseDescriptor $Snapshot.Root $Snapshot $releaseVersion $Label
    return [ordered]@{
        Path = $Path
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
        SchemaVersion = 4
        Packaging = 'CompressedFirstRun'
        ReleaseVersion = $releaseVersion
    }
}

function Assert-SnapshotsEqual($Expected, $Actual, [string]$Label) {
    foreach ($relative in $expectedFiles) {
        $expectedFile = $Expected.Files[$relative]
        $actualFile = $Actual.Files[$relative]
        if ($null -eq $actualFile -or [long]$actualFile.Length -ne [long]$expectedFile.Length -or
            -not [string]::Equals([string]$actualFile.Sha256, [string]$expectedFile.Sha256,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label differs from the source compact release: $relative"
        }
    }
}

function Remove-TomlComment([string]$Line) {
    $inString = $false
    $escaped = $false
    for ($index = 0; $index -lt $Line.Length; $index++) {
        $character = $Line[$index]
        if ($character -eq '"' -and -not $escaped) {
            $inString = -not $inString
        }
        if ($character -eq '#' -and -not $inString) {
            return $Line.Substring(0, $index)
        }
        if ($character -eq '\' -and -not $escaped) {
            $escaped = $true
        }
        else {
            $escaped = $false
        }
    }
    return $Line
}

function Convert-SimpleTomlString([string]$Value) {
    $trimmed = $Value.Trim()
    if ($trimmed.Length -lt 2 -or -not $trimmed.StartsWith('"') -or -not $trimmed.EndsWith('"')) {
        return $null
    }
    $inner = $trimmed.Substring(1, $trimmed.Length - 2)
    if ($inner.Contains('\') -or $inner.Contains('"')) {
        return $null
    }
    return $inner
}

function Get-RootPermissionSettings([string]$ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            ApprovalPolicyEntries = @()
            SandboxModeEntries = @()
            ApprovalPolicy = $null
            SandboxMode = $null
            Valid = $false
        }
    }
    $approval = New-Object 'System.Collections.Generic.List[string]'
    $sandbox = New-Object 'System.Collections.Generic.List[string]'
    $isRoot = $true
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath, (New-Object Text.UTF8Encoding($false, $true)))) {
        $trimmed = (Remove-TomlComment $line).Trim()
        if ($trimmed.Length -eq 0) { continue }
        if ($trimmed.StartsWith('[')) {
            $isRoot = $false
            continue
        }
        if (-not $isRoot) { continue }
        $match = [Regex]::Match($trimmed, '^([A-Za-z0-9_-]+)\s*=\s*(.*)$')
        if (-not $match.Success) { continue }
        $key = $match.Groups[1].Value
        $value = Convert-SimpleTomlString $match.Groups[2].Value
        if ($null -eq $value) { continue }
        if ($key -ceq 'approval_policy') {
            $approval.Add($value)
        }
        elseif ($key -ceq 'sandbox_mode') {
            $sandbox.Add($value)
        }
    }
    $approvalValue = if ($approval.Count -eq 1) { $approval[0] } else { $null }
    $sandboxValue = if ($sandbox.Count -eq 1) { $sandbox[0] } else { $null }
    return [pscustomobject]@{
        Exists = $true
        ApprovalPolicyEntries = @($approval)
        SandboxModeEntries = @($sandbox)
        ApprovalPolicy = $approvalValue
        SandboxMode = $sandboxValue
        Valid = $approval.Count -eq 1 -and $sandbox.Count -eq 1 -and
            $approvalValue -ceq 'never' -and $sandboxValue -ceq 'danger-full-access'
    }
}

function Get-GlobalStateMode([string]$StatePath) {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            LocalMode = $null
            Valid = $false
        }
    }
    try {
        $state = Get-StrictJson $StatePath
        $atoms = Get-ObjectPropertyValue $state 'electron-persisted-atom-state'
        $agentModes = Get-ObjectPropertyValue $atoms 'agent-mode-by-host-id'
        $localMode = Get-ObjectPropertyValue $agentModes 'local'
        return [pscustomobject]@{
            Exists = $true
            LocalMode = if ($null -eq $localMode) { $null } else { [string]$localMode }
            Valid = [string]::Equals([string]$localMode, 'custom', [StringComparison]::Ordinal)
        }
    }
    catch {
        return [pscustomobject]@{
            Exists = $true
            LocalMode = $null
            Valid = $false
            ParseError = $_.Exception.Message
        }
    }
}

function Get-TargetLauncherProcesses([string]$Root) {
    $bootstrapper = Join-Path $Root 'CodexPortable.exe'
    $launcherRoot = (Join-Path $Root 'CodexData\tools\launchers').TrimEnd('\') + '\'
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try {
            $path = $_.Path
            -not [string]::IsNullOrWhiteSpace($path) -and
                ($path.Equals($bootstrapper, [StringComparison]::OrdinalIgnoreCase) -or
                    $path.StartsWith($launcherRoot, [StringComparison]::OrdinalIgnoreCase))
        }
        catch {
            $false
        }
    })
}

function Get-RemainingOperationMilliseconds([DateTime]$Deadline, [string]$Label) {
    $remaining = $Deadline - [DateTime]::UtcNow
    if ($remaining.TotalMilliseconds -le 0) {
        throw "Timed out before $Label; the validator operation deadline has elapsed."
    }
    return [int][Math]::Ceiling($remaining.TotalMilliseconds)
}

function Stop-LauncherCommandProcessTree([Diagnostics.Process]$Process, [DateTime]$Deadline) {
    try {
        if ($Process.HasExited) { return }
        $remainingMilliseconds = [int][Math]::Floor(($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $taskKill = Join-Path $env:WINDIR 'System32\taskkill.exe'
        if ($remainingMilliseconds -gt 0 -and (Test-Path -LiteralPath $taskKill -PathType Leaf)) {
            # A self-test launches tar.exe; terminate that child together with
            # the exact launcher command when its shared deadline expires.
            $killInfo = New-Object Diagnostics.ProcessStartInfo
            $killInfo.FileName = $taskKill
            $killInfo.Arguments = '/PID ' + $Process.Id + ' /T /F'
            $killInfo.UseShellExecute = $false
            $killInfo.CreateNoWindow = $true
            $killProcess = [Diagnostics.Process]::Start($killInfo)
            if ($null -ne $killProcess) {
                try {
                    $killWaitMilliseconds = [Math]::Min(1000, $remainingMilliseconds)
                    if (-not $killProcess.WaitForExit($killWaitMilliseconds)) {
                        try { $killProcess.Kill() } catch { }
                    }
                }
                finally {
                    $killProcess.Dispose()
                }
            }
        }
    }
    catch {
    }
    finally {
        try {
            if (-not $Process.HasExited) { $Process.Kill() }
        }
        catch {
        }
    }
}

function Wait-ForProcessExit([Diagnostics.Process]$Process, [DateTime]$Deadline) {
    while (-not $Process.HasExited -and [DateTime]::UtcNow -lt $Deadline) {
        $remainingMilliseconds = [int][Math]::Ceiling(($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remainingMilliseconds -gt 0) {
            $null = $Process.WaitForExit([Math]::Min(100, $remainingMilliseconds))
        }
    }
    return $Process.HasExited
}

function Invoke-LauncherCommand([string]$LauncherPath, [string]$PortableRoot,
    [string[]]$Arguments, [string]$Label, [DateTime]$Deadline) {
    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
        throw "$Label launcher is missing: $LauncherPath"
    }
    $null = Get-RemainingOperationMilliseconds $Deadline $Label
    $quoted = New-Object 'System.Collections.Generic.List[string]'
    $quoted.Add('--portable-root')
    $quoted.Add($PortableRoot)
    foreach ($argument in $Arguments) { $quoted.Add($argument) }
    $escaped = foreach ($argument in $quoted) {
        if ($argument.IndexOfAny([char[]]@(' ', "`t", "`n", '"')) -lt 0) {
            $argument
        }
        else {
            '"' + $argument.Replace('"', '\\"') + '"'
        }
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $LauncherPath
    $info.Arguments = ($escaped -join ' ')
    $info.WorkingDirectory = $PortableRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) {
        throw "Unable to start $Label validation."
    }
    try {
        $remainingMilliseconds = Get-RemainingOperationMilliseconds $Deadline $Label
        # Reserve the tail of the shared deadline for taskkill /T so an MSIX
        # self-test cannot leave its tar.exe child behind after timeout.
        $cleanupReserveMilliseconds = [Math]::Min(1000, $remainingMilliseconds)
        $commandWaitMilliseconds = $remainingMilliseconds - $cleanupReserveMilliseconds
        if ($commandWaitMilliseconds -le 0 -or -not $process.WaitForExit($commandWaitMilliseconds)) {
            Stop-LauncherCommandProcessTree $process $Deadline
            $null = Wait-ForProcessExit $process $Deadline
            throw "$Label validation timed out before the validator operation deadline."
        }
        if (-not $process.HasExited) {
            throw "$Label validation did not exit before the validator operation deadline."
        }
        if ($process.ExitCode -ne 0) {
            throw "$Label validation failed with exit code $($process.ExitCode)."
        }
    }
    catch {
        Stop-LauncherCommandProcessTree $process $Deadline
        $null = Wait-ForProcessExit $process $Deadline
        throw
    }
    finally {
        $process.Dispose()
    }
}

function Wait-Until([scriptblock]$Condition, [DateTime]$Deadline, [string]$Label) {
    while ([DateTime]::UtcNow -lt $Deadline) {
        $value = & $Condition
        if ($null -ne $value -and $value -ne $false) {
            if ([DateTime]::UtcNow -lt $Deadline) {
                return $value
            }
            break
        }
        $remainingMilliseconds = [int][Math]::Ceiling(($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remainingMilliseconds -gt 0) {
            Start-Sleep -Milliseconds ([Math]::Min(250, $remainingMilliseconds))
        }
    }
    throw "Timed out waiting for $Label before the validator operation deadline."
}

function Stop-TargetLauncherProcesses([string]$Root, [DateTime]$Deadline) {
    $initial = @(Get-TargetLauncherProcesses $Root)
    foreach ($process in $initial) {
        try {
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                $null = $process.CloseMainWindow()
            }
        }
        catch {
        }
    }
    $graceDeadline = [DateTime]::UtcNow.AddSeconds(10)
    if ($Deadline -lt $graceDeadline) { $graceDeadline = $Deadline }
    do {
        if ([DateTime]::UtcNow -ge $graceDeadline) { break }
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-TargetLauncherProcesses $Root)
    } while ($remaining.Count -ne 0 -and [DateTime]::UtcNow -lt $graceDeadline)

    $forced = @()
    if ($remaining.Count -ne 0) {
        foreach ($process in $remaining) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                $forced += $process.Id
            }
            catch {
            }
        }
        $remainingMilliseconds = [int][Math]::Floor(($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remainingMilliseconds -gt 0) {
            Start-Sleep -Milliseconds ([Math]::Min(500, $remainingMilliseconds))
        }
    }
    $final = @(Get-TargetLauncherProcesses $Root)
    return [ordered]@{
        Requested = $true
        InitialProcessIds = @($initial | Select-Object -ExpandProperty Id)
        ForceStoppedProcessIds = @($forced)
        RemainingProcessIds = @($final | Select-Object -ExpandProperty Id)
        Succeeded = $final.Count -eq 0
    }
}

function Write-ResultFile([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = $Path + '.tmp-' + [Guid]::NewGuid().ToString('N')
    $json = $Value | ConvertTo-Json -Depth 12
    try {
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
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

$result = [ordered]@{
    Contract = 'LF compact zero-state first-run'
    Status = 'Running'
    Passed = $false
    StartedUtc = [DateTime]::UtcNow.ToString('o')
    SelfTestInvokedBeforeFirstLauncherAction = $false
    FirstLauncherAction = 'Start CodexPortable.exe only'
}
$failure = $null
$targetFull = $null
$resultPathFull = $null
$launcherStarted = $false
$operationDeadline = $null

try {
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "Source release is missing: $SourceRoot"
    }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Release manifest is missing: $ManifestPath"
    }

    $sourceFull = Get-NormalizedFullPath ((Resolve-Path -LiteralPath $SourceRoot).Path)
    $manifestFull = Get-NormalizedFullPath ((Resolve-Path -LiteralPath $ManifestPath).Path)
    $targetFull = Get-NormalizedFullPath $TargetRoot
    $targetParent = Split-Path -Parent $targetFull
    if ([string]::IsNullOrWhiteSpace($targetParent) -or
        -not (Test-Path -LiteralPath $targetParent -PathType Container)) {
        throw "Target parent directory is missing: $targetParent"
    }
    if (Test-Path -LiteralPath $targetFull) {
        throw "TargetRoot must not exist for a zero-state validation: $targetFull"
    }
    if (Test-PathWithin $targetFull $sourceFull -or Test-PathWithin $sourceFull $targetFull) {
        throw 'SourceRoot and TargetRoot must not contain one another.'
    }
    Assert-NotUsbPath $sourceFull 'Source release'
    Assert-NotUsbPath $targetFull 'Validation target'

    if ([string]::IsNullOrWhiteSpace($ResultPath)) {
        $resultPathFull = $targetFull + '.first-run-result.json'
    }
    else {
        $resultPathFull = Get-NormalizedFullPath $ResultPath
    }
    if (Test-PathWithin $resultPathFull $sourceFull -or Test-PathWithin $resultPathFull $targetFull) {
        throw 'ResultPath must be outside SourceRoot and TargetRoot.'
    }

    $result.SourceRoot = $sourceFull
    $result.TargetRoot = $targetFull
    $result.ResultPath = $resultPathFull
    $sourceSnapshot = Get-CompactReleaseSnapshot $sourceFull 'Source compact release'
    $result.Manifest = Assert-ManifestMatchesSnapshot $manifestFull $sourceSnapshot 'Source compact release'
    $result.SourceCompactRelease = [ordered]@{
        DirectoryCount = $sourceSnapshot.DirectoryCount
        FileCount = $sourceSnapshot.FileCount
    }

    New-Item -ItemType Directory -Path $targetFull -ErrorAction Stop | Out-Null
    & robocopy.exe $sourceFull $targetFull /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /MT:16 /XJ /NFL /NDL /NP /NJH /NJS | Out-Null
    $copyExitCode = [int]$LASTEXITCODE
    if ($copyExitCode -ge 8) {
        throw "Compact release copy failed with robocopy exit code $copyExitCode."
    }
    $targetSnapshot = Get-CompactReleaseSnapshot $targetFull 'Copied compact release'
    Assert-SnapshotsEqual $sourceSnapshot $targetSnapshot 'Copied compact release'
    Assert-PortableReleaseDescriptor $targetFull $targetSnapshot $result.Manifest.ReleaseVersion 'Copied compact release'
    $result.Copy = [ordered]@{
        RobocopyExitCode = $copyExitCode
        FileCount = $targetSnapshot.FileCount
        SourceHashesMatch = $true
    }

    $bootstrapper = Join-Path $targetFull 'CodexPortable.exe'
    $configPath = Join-Path $targetFull 'CodexData\data\profile\.codex\config.toml'
    $statePath = Join-Path $targetFull 'CodexData\data\profile\.codex\.codex-global-state.json'
    $stateBackupPath = $statePath + '.bak'
    $payloadPaths = @(
        (Join-Path $targetFull 'CodexData\app\current'),
        (Join-Path $targetFull 'CodexData\tools\desktop-payloads\x86\current'),
        (Join-Path $targetFull 'CodexData\tools\desktop-payloads\x64\current'),
        (Join-Path $targetFull 'CodexData\tools\desktop-payloads\arm64\current')
    )
    $preLaunchPayloads = @($payloadPaths | Where-Object {
        Test-Path -LiteralPath $_ -PathType Container
    })
    $result.ZeroStateBeforeLauncher = [ordered]@{
        ConfigTomlExists = Test-Path -LiteralPath $configPath -PathType Leaf
        GlobalStateExists = Test-Path -LiteralPath $statePath -PathType Leaf
        GlobalStateBackupExists = Test-Path -LiteralPath $stateBackupPath -PathType Leaf
        ExpandedCurrentPaths = @($preLaunchPayloads)
    }
    if ($result.ZeroStateBeforeLauncher.ConfigTomlExists -or
        $result.ZeroStateBeforeLauncher.GlobalStateExists -or
        $result.ZeroStateBeforeLauncher.GlobalStateBackupExists -or
        $preLaunchPayloads.Count -ne 0) {
        throw 'Copied target is not zero-state before the first launcher action.'
    }

    # No self-test, launcher preflight command, or Start Codex click precedes
    # this process. It is the first executable action against TargetRoot.
    $operationDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $bootstrapProcess = Start-Process -FilePath $bootstrapper -WorkingDirectory $targetFull -PassThru
    $launcherStarted = $true
    $result.Launcher = [ordered]@{
        BootstrapperProcessId = $bootstrapProcess.Id
        CoreProcessId = $null
        MainWindowObserved = $false
        OperationDeadlineUtc = $operationDeadline.ToString('o')
    }

    $coreProcess = Wait-Until {
        @(Get-TargetLauncherProcesses $targetFull | Where-Object {
            $_.ProcessName -like 'CodexPortable.*'
        } | Select-Object -First 1)
    } $operationDeadline 'the launcher core process'
    $result.Launcher.CoreProcessId = $coreProcess.Id

    $windowProcess = Wait-Until {
        foreach ($process in @(Get-TargetLauncherProcesses $targetFull)) {
            try {
                $process.Refresh()
                if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                    return $process
                }
            }
            catch {
            }
        }
        return $false
    } $operationDeadline 'the launcher main window'
    $result.Launcher.MainWindowObserved = $true
    $result.Launcher.WindowProcessId = $windowProcess.Id

    $null = Wait-Until {
        (Test-Path -LiteralPath $configPath -PathType Leaf) -and
            (Test-Path -LiteralPath $statePath -PathType Leaf) -and
            (Test-Path -LiteralPath $stateBackupPath -PathType Leaf)
    } $operationDeadline 'config.toml and global state files'

    $permissions = Get-RootPermissionSettings $configPath
    $globalState = Get-GlobalStateMode $statePath
    $globalStateBackup = Get-GlobalStateMode $stateBackupPath
    $result.ConfigToml = [ordered]@{
        Path = $configPath
        Exists = $permissions.Exists
        RootApprovalPolicyEntries = @($permissions.ApprovalPolicyEntries)
        RootSandboxModeEntries = @($permissions.SandboxModeEntries)
        RootApprovalPolicy = $permissions.ApprovalPolicy
        RootSandboxMode = $permissions.SandboxMode
        ExpectedApprovalPolicy = 'never'
        ExpectedSandboxMode = 'danger-full-access'
        RootPermissionsValid = $permissions.Valid
    }
    $result.GlobalState = [ordered]@{
        Path = $statePath
        BackupPath = $stateBackupPath
        LocalAgentMode = $globalState.LocalMode
        BackupLocalAgentMode = $globalStateBackup.LocalMode
        ExpectedLocalAgentMode = 'custom'
        LocalAgentModeCustom = $globalState.Valid -and $globalStateBackup.Valid
    }
    $expandedPayloads = @($payloadPaths | Where-Object {
        Test-Path -LiteralPath $_ -PathType Container
    })
    $result.DesktopPayload = [ordered]@{
        ExpandedCurrentPaths = @($expandedPayloads)
        NotExpanded = $expandedPayloads.Count -eq 0
    }

    if (-not $permissions.Valid) {
        throw 'config.toml does not contain exactly the expected root approval_policy and sandbox_mode values.'
    }
    if (-not $globalState.Valid -or -not $globalStateBackup.Valid) {
        throw 'Global state does not set agent-mode-by-host-id.local to custom.'
    }
    if ($expandedPayloads.Count -ne 0) {
        throw 'Desktop payload expanded before any Start Codex action.'
    }

    # The persisted enum for the config-backed permission choice is `custom`.
    # Validate the copied release's exact launcher against both signed desktop
    # packages so its ASAR patch proves the visible label is `config.toml` and
    # that Codex cannot collapse the matching permissions into Full access.
    # --self-test-msix uses only a temporary staging directory under updates;
    # it never starts the desktop app or expands app/current.
    $presentationLauncher = Join-Path $targetFull 'CodexData\tools\launchers\CodexPortable.x64.exe'
    $presentationPackages = @(
        [ordered]@{
            Architecture = 'x64'
            Path = Join-Path $targetFull 'CodexData\packages\LFPortable-x64.msix'
        },
        [ordered]@{
            Architecture = 'arm64'
            Path = Join-Path $targetFull 'CodexData\packages\LFPortable-arm64.msix'
        }
    )
    $presentationResults = @()
    foreach ($package in $presentationPackages) {
        Invoke-LauncherCommand $presentationLauncher $targetFull @(
            '--self-test-msix', [string]$package.Path, [string]$package.Architecture
        ) ("{0} config.toml permission-presentation ASAR" -f $package.Architecture) $operationDeadline
        $presentationResults += [pscustomobject][ordered]@{
            Architecture = $package.Architecture
            Package = $package.Path
            AsarPermissionPresentationVerified = $true
        }
    }
    $postPresentationPayloads = @($payloadPaths | Where-Object {
        Test-Path -LiteralPath $_ -PathType Container
    })
    if ($postPresentationPayloads.Count -ne 0) {
        throw 'Permission-presentation ASAR validation expanded a desktop payload.'
    }
    $null = Get-RemainingOperationMilliseconds $operationDeadline 'finalizing launcher validation'
    $result['PermissionPresentation'] = [pscustomobject][ordered]@{
        ExpectedInitialUiLabel = 'config.toml'
        ExpectedPersistedAgentMode = 'custom'
        FullAccessEquivalenceDisabled = $true
        NoDesktopPayloadExpanded = $true
        Verification = 'Copied launcher --self-test-msix validates ASAR label, no-equivalence patch, and ASAR integrity.'
        Packages = @($presentationResults)
    }

    $null = Get-RemainingOperationMilliseconds $operationDeadline 'recording launcher validation'
    $result.Passed = $true
    $result.Status = 'Passed'
}
catch {
    $failure = $_
    $result.Passed = $false
    $result.Status = 'Failed'
    $result.Error = $_.Exception.Message
}
finally {
    if ($launcherStarted -and -not $LeaveLauncherRunning -and $null -ne $targetFull) {
        $cleanupDeadline = if ($null -eq $operationDeadline) {
            [DateTime]::UtcNow.AddSeconds(10)
        }
        else {
            $operationDeadline
        }
        $result.Cleanup = Stop-TargetLauncherProcesses $targetFull $cleanupDeadline
        if (-not $result.Cleanup.Succeeded -and $null -eq $failure) {
            $result.Passed = $false
            $result.Status = 'Failed'
            $result.Error = 'The validator could not close every launcher process it started.'
            $failure = New-Object InvalidOperationException($result.Error)
        }
    }
    elseif ($launcherStarted) {
        $result.Cleanup = [ordered]@{
            Requested = $false
            Reason = 'LeaveLauncherRunning'
        }
    }
    $result.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    if ($null -ne $resultPathFull) {
        try {
            Write-ResultFile $resultPathFull $result
        }
        catch {
            if ($null -eq $failure) {
                $failure = $_
                $result.Passed = $false
                $result.Status = 'Failed'
                $result.Error = 'Could not write validation result: ' + $_.Exception.Message
            }
        }
    }
}

[pscustomobject]$result
if ($null -ne $failure) {
    exit 1
}
exit 0
