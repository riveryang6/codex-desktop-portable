[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    # Must not already exist. The generated result is retained outside both
    # the canonical release and the USB installation.
    [Parameter(Mandatory = $true)]
    [string]$EvidenceRoot,

    # This is a per-launcher-operation budget inside the guest. The outer
    # evidence wait deliberately allows several such bounded operations.
    [ValidateRange(60, 600)]
    [int]$TimeoutSeconds = 600,

    # A launch owns the full lifecycle: isolated snapshot, Sandbox execution,
    # guest shutdown, source-map release, and snapshot cleanup.
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
    while ($full.Length -gt $root.Length -and ($full.EndsWith('\') -or $full.EndsWith('/'))) {
        $full = $full.Substring(0, $full.Length - 1)
    }
    return $full
}

function Test-PathWithin([string]$Candidate, [string]$Root) {
    $candidateFull = Get-NormalizedFullPath $Candidate
    $rootFull = Get-NormalizedFullPath $Root
    return $candidateFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        $candidateFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-XmlText([string]$Value) {
    return [Security.SecurityElement]::Escape($Value)
}

function Assert-FixedNonUsbVolume([string]$Path, [string]$Label) {
    $full = Get-NormalizedFullPath $Path
    if ($full -notmatch '^[A-Za-z]:') {
        throw "$Label must be on a fixed local Windows volume: $full"
    }
    try {
        $drive = New-Object IO.DriveInfo($full.Substring(0, 2))
        if (-not $drive.IsReady) { throw 'drive is not ready' }
    }
    catch {
        throw "Unable to determine the volume for ${Label}: $full"
    }
    if ($drive.DriveType -ne [IO.DriveType]::Fixed -or
        [string]::Equals([string]$drive.VolumeLabel, 'CODEX_USB', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must not be on a removable or CODEX_USB volume: $full"
    }
}

function Assert-NoReparseAncestry([string]$Path, [string]$Label) {
    $current = Get-NormalizedFullPath $Path
    $root = [IO.Path]::GetPathRoot($current)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label is or is beneath a reparse point: $current"
            }
        }
        if ($current.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = Get-NormalizedFullPath $parent
    }
}

function Assert-NoReparsePointsUnder([string]$Path, [string]$Label) {
    $points = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop)
    if ($points.Count -ne 0) {
        throw "$Label contains a reparse point: $($points[0].FullName)"
    }
}

function Get-StrictJson([string]$Path) {
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    return [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json -ErrorAction Stop
}

function Get-ObjectProperty([object]$Value, [string]$Name) {
    if ($null -eq $Value) { return $null }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Test-TransientFileSystemContention([Exception]$Exception) {
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [IO.IOException]) {
            $win32Error = ([int]$current.HResult) -band 0xFFFF
            if ($win32Error -eq 32 -or $win32Error -eq 33) { return $true }
        }
        $current = $current.InnerException
    }
    return $false
}

function Get-RelativeFiles([string]$Root) {
    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction Stop |
            ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/') } |
            Sort-Object
    )
}

function Assert-ExactStringSet([string[]]$Expected, [string[]]$Actual, [string]$Label) {
    $difference = @(Compare-Object -ReferenceObject @($Expected | Sort-Object) -DifferenceObject @($Actual | Sort-Object))
    if ($difference.Count -ne 0) {
        $values = @($difference | Select-Object -First 12 | ForEach-Object { [string]$_.InputObject })
        throw "$Label differs from the compact release contract: $($values -join ', ')"
    }
}

function Assert-CompactReleaseState([string]$ReleaseRoot, [string]$ReleaseManifest,
    [string]$ExpectedManifestSha256, [string]$Label) {
    if (-not (Get-Sha256 $ReleaseManifest).Equals($ExpectedManifestSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label manifest differs from the canonical release manifest captured before Sandbox validation."
    }
    Assert-NoReparsePointsUnder $ReleaseRoot $Label
    $manifest = Get-StrictJson $ReleaseManifest
    if ([int](Get-ObjectProperty $manifest 'SchemaVersion') -ne 4 -or
        [string](Get-ObjectProperty $manifest 'Package') -cne 'Codex Portable USB' -or
        [string](Get-ObjectProperty $manifest 'Packaging') -cne 'CompressedFirstRun') {
        throw "$Label manifest is not the schema 4 CompressedFirstRun contract."
    }
    $entries = @{}
    foreach ($entry in @($manifest.Files)) {
        $relative = [string](Get-ObjectProperty $entry 'Path')
        if (-not ($expectedFiles -ccontains $relative) -or $entries.ContainsKey($relative)) {
            throw "$Label manifest contains an unexpected or duplicate file: $relative"
        }
        $entries[$relative] = $entry
    }
    Assert-ExactStringSet $expectedFiles @($entries.Keys) "$Label manifest files"
    Assert-ExactStringSet $expectedFiles (Get-RelativeFiles $ReleaseRoot) "$Label files"
    foreach ($relative in $expectedFiles) {
        $path = Join-Path $ReleaseRoot ($relative.Replace('/', '\'))
        $entry = $entries[$relative]
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ([long]$item.Length -ne [long](Get-ObjectProperty $entry 'Length') -or
            -not (Get-Sha256 $path).Equals([string](Get-ObjectProperty $entry 'Sha256'), [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label does not match its manifest: $relative"
        }
    }
}

function Get-WindowsSandboxSessionProcesses {
    return @(Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient',
        'WindowsSandboxServer', 'WindowsSandboxRemoteSession' -ErrorAction SilentlyContinue)
}

function Assert-NoExistingSandboxSession {
    $sessions = @(Get-WindowsSandboxSessionProcesses)
    if ($sessions.Count -ne 0) {
        $ids = @($sessions | Select-Object -ExpandProperty Id | Sort-Object -Unique) -join ', '
        throw "A Windows Sandbox session is still active (process IDs: $ids). Close it before creating a new LF validation run."
    }
}

function Wait-ForSandboxSessionExit([int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $sessions = @(Get-WindowsSandboxSessionProcesses)
        if ($sessions.Count -eq 0) { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    $ids = @($sessions | Select-Object -ExpandProperty Id | Sort-Object -Unique)
    foreach ($session in $sessions) {
        try {
            Stop-Process -Id $session.Id -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not terminate the completed LF Sandbox session process $($session.Id): $($_.Exception.Message)"
        }
    }
    Start-Sleep -Seconds 2
    $remaining = @(Get-WindowsSandboxSessionProcesses)
    if ($remaining.Count -ne 0) {
        $remainingIds = @($remaining | Select-Object -ExpandProperty Id | Sort-Object -Unique) -join ', '
        throw "Windows Sandbox session processes did not exit after the guest shutdown (process IDs: $($ids -join ', '); remaining: $remainingIds)."
    }
}

function Copy-CompactInputSnapshot([string]$ReleaseRoot, [string]$CanonicalManifest,
    [string]$SnapshotRoot, [string]$ExpectedManifestSha256) {
    $snapshotRelease = Join-Path $SnapshotRoot 'release'
    $snapshotTools = Join-Path $SnapshotRoot 'tools'
    New-Item -ItemType Directory -Path $snapshotRelease, $snapshotTools -Force -ErrorAction Stop | Out-Null
    & robocopy.exe $ReleaseRoot $snapshotRelease /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /MT:16 /XJ /NFL /NDL /NP /NJH /NJS | Out-Null
    $copyExitCode = [int]$LASTEXITCODE
    if ($copyExitCode -ge 8) {
        throw "Sandbox input snapshot copy failed with robocopy exit code $copyExitCode."
    }
    $snapshotManifest = Join-Path $SnapshotRoot 'portable-package-manifest.json'
    [IO.File]::Copy($CanonicalManifest, $snapshotManifest, $false)
    foreach ($name in @('Run-CompactFirstRunSandbox.ps1', 'Validate-CompactFirstRun.ps1')) {
        [IO.File]::Copy((Join-Path $PSScriptRoot $name), (Join-Path $snapshotTools $name), $false)
    }
    Assert-CompactReleaseState $snapshotRelease $snapshotManifest $ExpectedManifestSha256 `
        'Sandbox input release'
    return [pscustomobject]@{
        Root = $SnapshotRoot
        ReleaseRoot = $snapshotRelease
        ManifestPath = $snapshotManifest
        ToolsRoot = $snapshotTools
        RobocopyExitCode = $copyExitCode
    }
}

function Write-SandboxRunner([string]$ToolsRoot, [int]$RunnerTimeoutSeconds) {
    $path = Join-Path $ToolsRoot 'Run-CompactFirstRunSandbox.cmd'
    $text = @"
@echo off
setlocal EnableExtensions DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Input\tools\Run-CompactFirstRunSandbox.ps1" -SourceRoot "C:\Input\release" -ManifestPath "C:\Input\portable-package-manifest.json" -EvidenceRoot "C:\Evidence" -TimeoutSeconds $RunnerTimeoutSeconds
set "LF_RUN_EXIT=%ERRORLEVEL%"
"%SystemRoot%\System32\shutdown.exe" /s /t 0 /f
exit /b %LF_RUN_EXIT%
"@
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
    return $path
}

function Wait-ForSandboxResultOrExit([string]$Path, [Diagnostics.Process]$Process, [int]$Seconds) {
    if ($null -eq $Process) { throw 'Windows Sandbox launch process is missing.' }
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $frontEndEvidenceGraceSeconds = [Math]::Min(60, $Seconds)
    $frontEndExitedWithoutSessionDeadline = $null
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                $result = Get-StrictJson $Path
                $status = [string](Get-ObjectProperty $result 'Status')
                $completed = [string](Get-ObjectProperty $result 'CompletedUtc')
                if (($status -ceq 'Passed' -or $status -ceq 'Failed') -and -not [string]::IsNullOrWhiteSpace($completed)) {
                    return $result
                }
            }
            catch {
                # The guest replaces the result atomically. Keep polling if a
                # filesystem handoff is observed between replacement and read.
            }
        }

        $Process.Refresh()
        if ($Process.HasExited) {
            $sessions = @(Get-WindowsSandboxSessionProcesses)
            if ($sessions.Count -ne 0) {
                # WindowsSandbox.exe can exit while the guest and mapped-folder
                # handoff are still owned by the Sandbox session processes.
                $frontEndExitedWithoutSessionDeadline = $null
            }
            else {
                if ($null -eq $frontEndExitedWithoutSessionDeadline) {
                    $frontEndExitedWithoutSessionDeadline = [DateTime]::UtcNow.AddSeconds($frontEndEvidenceGraceSeconds)
                }
                if ([DateTime]::UtcNow -ge $frontEndExitedWithoutSessionDeadline) {
                    throw "Windows Sandbox exited before producing terminal evidence after the $frontEndEvidenceGraceSeconds second handoff grace (process ID $($Process.Id), exit code $($Process.ExitCode))."
                }
            }
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    $Process.Refresh()
    if ($Process.HasExited) {
        $sessions = @(Get-WindowsSandboxSessionProcesses)
        if ($sessions.Count -ne 0) {
            $sessionIds = @($sessions | Select-Object -ExpandProperty Id | Sort-Object -Unique) -join ', '
            $sessionState = "active Sandbox session process IDs: $sessionIds"
        }
        else {
            $sessionState = 'no Sandbox session processes were present'
        }
        throw "Timed out waiting for Windows Sandbox evidence: $Path (front-end process ID $($Process.Id) exited with code $($Process.ExitCode); $sessionState)."
    }
    throw "Timed out waiting for Windows Sandbox evidence: $Path (front-end process ID $($Process.Id) is still running)."
}

function Wait-ForSandboxExit([Diagnostics.Process]$Process, [int]$Seconds) {
    if ($null -eq $Process) { throw 'Windows Sandbox launch process is missing.' }
    $launchFailure = $null
    try {
        if (-not $Process.WaitForExit($Seconds * 1000)) {
            throw "Windows Sandbox did not exit after writing its result (process ID $($Process.Id))."
        }
        # WaitForExit can return from a signaled handle before the Process object
        # refreshes its cached exit state. Confirm it before releasing the mapped
        # snapshot, then require every session process to be gone as well.
        $Process.Refresh()
        if (-not $Process.HasExited) {
            throw "Windows Sandbox launch process is still running after its exit wait (process ID $($Process.Id))."
        }
    }
    catch {
        $launchFailure = $_.Exception
        # A guest that has already written terminal evidence can leave the host
        # front-end behind a connection-lost dialog. Close only this exact
        # launch process before collecting the bounded session teardown proof.
        Stop-ExactSandboxLaunch $Process
    }

    $sessionFailure = $null
    try { Wait-ForSandboxSessionExit $Seconds }
    catch { $sessionFailure = $_.Exception }

    if ($null -ne $launchFailure) {
        if ($null -ne $sessionFailure) {
            throw "Windows Sandbox teardown failed after launch failure: $($launchFailure.Message) Cleanup: $($sessionFailure.Message)"
        }
        throw $launchFailure
    }
    if ($null -ne $sessionFailure) { throw $sessionFailure }
}

function Retire-SandboxSnapshot([string]$SnapshotRoot, [string]$RetiredRoot, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        try {
            [IO.Directory]::Move($SnapshotRoot, $RetiredRoot)
            return $RetiredRoot
        }
        catch [IO.IOException] {
            if (-not (Test-TransientFileSystemContention $_.Exception)) { throw }
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Windows Sandbox did not release its isolated input snapshot: $SnapshotRoot"
}

function Stop-ExactSandboxLaunch([Diagnostics.Process]$Process) {
    if ($null -eq $Process) { return }
    try {
        $running = Get-Process -Id $Process.Id -ErrorAction Stop
        if ($running.MainWindowHandle -ne [IntPtr]::Zero) { $null = $running.CloseMainWindow() }
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 500
            $running = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
        } while ($null -ne $running -and [DateTime]::UtcNow -lt $deadline)
        if ($null -ne $running) { Stop-Process -Id $Process.Id -Force -ErrorAction Stop }
    }
    catch {
        Write-Warning "Could not stop the timed-out Sandbox launch process $($Process.Id): $($_.Exception.Message)"
    }
}

if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    throw "Source release is missing: $SourceRoot"
}
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Release manifest is missing: $ManifestPath"
}

$sourceFull = Get-NormalizedFullPath ((Resolve-Path -LiteralPath $SourceRoot).Path)
$manifestFull = Get-NormalizedFullPath ((Resolve-Path -LiteralPath $ManifestPath).Path)
$releaseParent = Get-NormalizedFullPath (Split-Path -Parent $sourceFull)
$manifestParent = Get-NormalizedFullPath (Split-Path -Parent $manifestFull)
$repositoryRoot = Get-NormalizedFullPath (Join-Path $PSScriptRoot '..\..')
Assert-FixedNonUsbVolume $sourceFull 'Source release'
Assert-FixedNonUsbVolume $manifestFull 'Release manifest'
Assert-NoReparseAncestry $sourceFull 'Source release'
Assert-NoReparseAncestry $manifestFull 'Release manifest'
if (-not $releaseParent.Equals($manifestParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ManifestPath must be alongside SourceRoot in the canonical release parent.'
}

$evidenceFull = Get-NormalizedFullPath $EvidenceRoot
$evidenceParent = Get-NormalizedFullPath (Split-Path -Parent $evidenceFull)
Assert-FixedNonUsbVolume $evidenceFull 'Sandbox evidence'
Assert-FixedNonUsbVolume $evidenceParent 'Sandbox evidence parent'
Assert-NoReparseAncestry $evidenceParent 'Sandbox evidence parent'
if (Test-Path -LiteralPath $evidenceFull) {
    throw "EvidenceRoot must not exist so a previous validation cannot be reused: $evidenceFull"
}
if (Test-PathWithin $evidenceFull $releaseParent -or Test-PathWithin $releaseParent $evidenceFull) {
    throw 'EvidenceRoot must be outside the canonical release parent.'
}
if (Test-PathWithin $evidenceFull $repositoryRoot -or Test-PathWithin $repositoryRoot $evidenceFull) {
    throw 'EvidenceRoot must be outside the source repository.'
}

if (-not $Launch) {
    [pscustomobject][ordered]@{
        Status = 'ReadyToLaunch'
        SourceRoot = $sourceFull
        ManifestPath = $manifestFull
        EvidenceRoot = $evidenceFull
        SnapshotPolicy = 'A generated immutable snapshot outside the release parent will be the only read-only Sandbox input.'
        Networking = 'Disabled'
        AutomaticGuestShutdown = $true
    }
    return
}

Assert-NoExistingSandboxSession
$nonce = [Guid]::NewGuid().ToString('N')
$snapshotRoot = Join-Path $evidenceParent ('.lf-sandbox-input-' + $nonce)
$retiredSnapshotRoot = Join-Path $evidenceParent ('.lf-sandbox-retired-' + $nonce)
if ((Test-Path -LiteralPath $snapshotRoot) -or (Test-Path -LiteralPath $retiredSnapshotRoot)) {
    throw 'Generated Sandbox snapshot path already exists.'
}
Assert-NoReparseAncestry $snapshotRoot 'Generated Sandbox snapshot'
if ((Test-PathWithin $snapshotRoot $releaseParent) -or (Test-PathWithin $releaseParent $snapshotRoot) -or
    (Test-PathWithin $snapshotRoot $evidenceFull) -or (Test-PathWithin $evidenceFull $snapshotRoot) -or
    (Test-PathWithin $snapshotRoot $repositoryRoot) -or (Test-PathWithin $repositoryRoot $snapshotRoot)) {
    throw 'Sandbox input snapshot must be separate from the source repository, canonical release, and evidence roots.'
}

$snapshot = $null
$sandboxProcess = $null
$snapshotRetired = $false
$result = $null
$snapshotCreated = $false
$sandboxFrontEndExited = $false
try {
    $canonicalManifestSha256 = Get-Sha256 $manifestFull
    New-Item -ItemType Directory -Path $snapshotRoot -ErrorAction Stop | Out-Null
    $snapshotCreated = $true
    $snapshot = Copy-CompactInputSnapshot $sourceFull $manifestFull $snapshotRoot $canonicalManifestSha256
    $runnerPath = Write-SandboxRunner $snapshot.ToolsRoot $TimeoutSeconds

    New-Item -ItemType Directory -Path $evidenceFull -ErrorAction Stop | Out-Null
    $guestOutputRoot = Join-Path $evidenceFull 'guest-output'
    New-Item -ItemType Directory -Path $guestOutputRoot -ErrorAction Stop | Out-Null
    $sandboxInput = 'C:\Input'
    $sandboxEvidence = 'C:\Evidence'
    $sandboxRunner = $sandboxInput + '\tools\' + (Split-Path -Leaf $runnerPath)
    $logonCommand = 'cmd.exe /d /c "' + $sandboxRunner + '"'
    $wsbText = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$(ConvertTo-XmlText $snapshot.Root)</HostFolder>
      <SandboxFolder>$sandboxInput</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$(ConvertTo-XmlText $guestOutputRoot)</HostFolder>
      <SandboxFolder>$sandboxEvidence</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <Networking>Disable</Networking>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <PrinterRedirection>Disable</PrinterRedirection>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <MemoryInMB>8192</MemoryInMB>
  <LogonCommand>
    <Command>$(ConvertTo-XmlText $logonCommand)</Command>
  </LogonCommand>
</Configuration>
"@
    $wsbPath = Join-Path $evidenceFull 'LF-CompactFirstRun.wsb'
    [IO.File]::WriteAllText($wsbPath, $wsbText, (New-Object Text.UTF8Encoding($false)))
    $resultPath = Join-Path $guestOutputRoot 'sandbox-first-run-result.json'
    $sandboxExecutable = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
    if (-not (Test-Path -LiteralPath $sandboxExecutable -PathType Leaf)) {
        throw "Windows Sandbox executable is unavailable: $sandboxExecutable"
    }
    $sandboxProcess = Start-Process -FilePath $sandboxExecutable -ArgumentList ('"' + $wsbPath + '"') -PassThru
    $outerWaitSeconds = [Math]::Min(14400, [Math]::Max(1800, $TimeoutSeconds * 6))
    $result = Wait-ForSandboxResultOrExit $resultPath $sandboxProcess $outerWaitSeconds
    Wait-ForSandboxExit $sandboxProcess 180
    $sandboxFrontEndExited = $true
    $retired = Retire-SandboxSnapshot $snapshot.Root $retiredSnapshotRoot 180
    $snapshotRetired = $true
    Assert-NoReparsePointsUnder $retired 'Retired Sandbox input snapshot'
    Remove-Item -LiteralPath $retired -Recurse -Force -ErrorAction Stop

    Assert-CompactReleaseState $sourceFull $manifestFull $canonicalManifestSha256 `
        'Canonical release after Sandbox validation'
    $canonicalRevalidatedUtc = [DateTime]::UtcNow.ToString('o')

    $status = [string](Get-ObjectProperty $result 'Status')
    $passed = [bool](Get-ObjectProperty $result 'Passed')
    if ($status -cne 'Passed' -or -not $passed) {
        $failure = [string](Get-ObjectProperty $result 'Error')
        if ([string]::IsNullOrWhiteSpace($failure)) {
            $manualStart = Get-ObjectProperty $result 'ManualStart'
            $failure = [string](Get-ObjectProperty $manualStart 'Error')
        }
        if ([string]::IsNullOrWhiteSpace($failure)) {
            $failure = 'Windows Sandbox guest returned a failed result without diagnostic text.'
        }
        throw "Windows Sandbox first-run validation failed: $failure"
    }
    [pscustomobject][ordered]@{
        Status = 'Passed'
        Passed = $true
        SourceRoot = $sourceFull
        ManifestPath = $manifestFull
        ManifestSha256 = $canonicalManifestSha256
        EvidenceRoot = $evidenceFull
        ResultPath = $resultPath
        WsbPath = $wsbPath
        SandboxProcessId = $sandboxProcess.Id
        SnapshotRobocopyExitCode = $snapshot.RobocopyExitCode
        SnapshotReleasedBeforeCleanup = $snapshotRetired
        CanonicalReleaseRevalidatedAfterSandbox = $true
        CanonicalManagedFileCount = $expectedFiles.Count
        CanonicalRevalidatedUtc = $canonicalRevalidatedUtc
        Networking = 'Disabled'
        AutomaticGuestShutdown = $true
    }
}
catch {
    if (-not $sandboxFrontEndExited) { Stop-ExactSandboxLaunch $sandboxProcess }
    throw
}
finally {
    if ($snapshotRetired -and (Test-Path -LiteralPath $retiredSnapshotRoot -PathType Container)) {
        try {
            Assert-NoReparsePointsUnder $retiredSnapshotRoot 'Retired Sandbox input snapshot'
            Remove-Item -LiteralPath $retiredSnapshotRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Warning "Retaining retired Sandbox snapshot because safe cleanup could not be confirmed: $retiredSnapshotRoot"
        }
    }
    elseif ($snapshotCreated -and $null -eq $sandboxProcess -and
        (Test-Path -LiteralPath $snapshotRoot -PathType Container)) {
        Remove-Item -LiteralPath $snapshotRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif ($snapshotCreated -and -not $snapshotRetired -and
        (Test-Path -LiteralPath $snapshotRoot -PathType Container)) {
        Write-Warning "Retaining the isolated Sandbox snapshot for inspection because its map was not confirmed released: $snapshotRoot"
    }
    if ($null -ne $sandboxProcess) { $sandboxProcess.Dispose() }
}
