[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,
    [Parameter(Mandatory = $true)]
    [string]$UsbRoot,
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [string]$ExpectedManifestSha256,
    # An existing fixed-disk directory outside the canonical release and USB
    # trees. Each executed synchronization creates a new GUID evidence root
    # beneath it and runs the tracked Sandbox launcher itself.
    [Parameter(Mandatory = $true)]
    [string]$SandboxEvidenceParent,
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

function Assert-FixedNonUsbVolume([string]$Path, [string]$Label) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notmatch '^[A-Za-z]:') {
        throw "$Label must be on a fixed local Windows volume: $full"
    }
    try {
        $driveInfo = New-Object IO.DriveInfo($full.Substring(0, 2))
        if (-not $driveInfo.IsReady) { throw 'Drive is not ready.' }
    }
    catch {
        throw "Unable to determine the volume type for ${Label}: $full"
    }
    if ($driveInfo.DriveType -ne [IO.DriveType]::Fixed -or
        [string]::Equals([string]$driveInfo.VolumeLabel, 'CODEX_USB', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be on a fixed non-CODEX_USB volume: $full"
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

function Assert-ValidationEmptyArray([object]$Value, [string]$Label) {
    if (-not ($Value -is [Array]) -or $Value.Count -ne 0) {
        throw "$Label must be an empty array."
    }
}

function Assert-SandboxTraceEvent([object]$Event, [int]$ProcessId, [int]$ParentProcessId,
    [int]$SessionId, [string]$ProcessName, [string]$Label) {
    if ($null -eq $Event -or
        [int](Get-ValidationProperty $Event 'EventOrdinal' $Label) -le 0 -or
        [int](Get-ValidationProperty $Event 'ProcessId' $Label) -ne $ProcessId -or
        [int](Get-ValidationProperty $Event 'ParentProcessId' $Label) -ne $ParentProcessId -or
        [int](Get-ValidationProperty $Event 'SessionId' $Label) -ne $SessionId -or
        -not [string]::Equals([string](Get-ValidationProperty $Event 'ProcessName' $Label),
            $ProcessName, [StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace([string](Get-ValidationProperty $Event 'ProviderTimeCreated' $Label)) -or
        [string]::IsNullOrWhiteSpace([string](Get-ValidationProperty $Event 'ReceivedUtc' $Label))) {
        throw "$Label is not a complete, trace-bound process-start event."
    }
}

function Assert-SandboxTraceProbe([object]$Probe, [string]$Label) {
    foreach ($name in @('TraceBound')) {
        Assert-ValidationTrue (Get-ValidationProperty $Probe $name $Label) "$Label $name"
    }
    if ([int](Get-ValidationProperty $Probe 'ProcessId' $Label) -le 0 -or
        [int](Get-ValidationProperty $Probe 'ParentProcessId' $Label) -le 0 -or
        [int](Get-ValidationProperty $Probe 'TraceEventOrdinal' $Label) -le 0 -or
        -not [string]::Equals([string](Get-ValidationProperty $Probe 'ProcessName' $Label),
            'cmd.exe', [StringComparison]::OrdinalIgnoreCase) -or
        [int](Get-ValidationProperty $Probe 'ExitCode' $Label) -ne 0) {
        throw "$Label is not a successful trace-bound cmd.exe readiness probe."
    }
}

function Assert-SandboxTraceBoundAttempt([object]$Attempt, [int]$ProcessId,
    [int]$ParentProcessId, [string]$Label) {
    Assert-ValidationTrue (Get-ValidationProperty $Attempt 'TraceBound' $Label) "$Label TraceBound"
    if ([int](Get-ValidationProperty $Attempt 'ProcessId' $Label) -ne $ProcessId -or
        [int](Get-ValidationProperty $Attempt 'ParentProcessId' $Label) -ne $ParentProcessId -or
        [int](Get-ValidationProperty $Attempt 'TraceEventOrdinal' $Label) -le 0 -or
        [string]::IsNullOrWhiteSpace([string](Get-ValidationProperty $Attempt 'TraceReceivedUtc' $Label))) {
        throw "$Label lacks a valid trace binding."
    }
}

function Assert-SandboxTraceRootSequence([object]$Sequence, [int]$SessionId,
    [int]$LauncherProcessId, [int[]]$ExpectedProcessIds, [string]$Label) {
    Assert-ValidationTrue (Get-ValidationProperty $Sequence 'ExactSequence' $Label) "$Label ExactSequence"
    if ([int](Get-ValidationProperty $Sequence 'LauncherProcessId' $Label) -ne $LauncherProcessId) {
        throw "$Label has the wrong launcher PID."
    }
    $declaredProcessIds = @(Get-ValidationProperty $Sequence 'ExpectedProcessIds' $Label)
    $events = @(Get-ValidationProperty $Sequence 'RootEvents' $Label)
    if ($declaredProcessIds.Count -ne $ExpectedProcessIds.Count -or
        $events.Count -ne $ExpectedProcessIds.Count) {
        throw "$Label does not contain the exact expected root count."
    }
    $lastOrdinal = 0
    for ($index = 0; $index -lt $ExpectedProcessIds.Count; $index++) {
        if ([int]$declaredProcessIds[$index] -ne [int]$ExpectedProcessIds[$index]) {
            throw "$Label declares a root PID outside the expected sequence."
        }
        Assert-SandboxTraceEvent $events[$index] ([int]$ExpectedProcessIds[$index]) `
            $LauncherProcessId $SessionId 'CodexDesktop.exe' "$Label root event $index"
        $ordinal = [int](Get-ValidationProperty $events[$index] 'EventOrdinal' "$Label root event $index")
        if ($ordinal -le $lastOrdinal) { throw "$Label root events are not ordered." }
        $lastOrdinal = $ordinal
    }
}

function Assert-SandboxTraceBoundRecoveryHelper([object]$Helper, [int]$ParentProcessId,
    [string]$Label) {
    foreach ($name in @('FixedLocalScratchPath', 'TraceBound')) {
        Assert-ValidationTrue (Get-ValidationProperty $Helper $name $Label) "$Label $name"
    }
    $processName = [string](Get-ValidationProperty $Helper 'ProcessName' $Label)
    $path = [string](Get-ValidationProperty $Helper 'ExecutablePath' $Label)
    if ([int](Get-ValidationProperty $Helper 'ProcessId' $Label) -le 0 -or
        [int](Get-ValidationProperty $Helper 'ParentProcessId' $Label) -ne $ParentProcessId -or
        [int](Get-ValidationProperty $Helper 'TraceEventOrdinal' $Label) -le 0 -or
        $processName -notlike 'LFRecovery-*.exe' -or
        [string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path) -or
        -not [string]::Equals([IO.Path]::GetFileName($path), $processName,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label is not a fixed-local, trace-bound LF recovery helper."
    }
}

function Assert-SandboxManagedReleaseSnapshot([object]$Snapshot,
    [Collections.IDictionary]$ExpectedManagedFiles, [string]$Label) {
    Assert-ValidationTrue (Get-ValidationProperty $Snapshot 'MatchesManifest' $Label) "$Label MatchesManifest"
    if ([int](Get-ValidationProperty $Snapshot 'ExpectedFileCount' $Label) -ne 10 -or
        [int](Get-ValidationProperty $Snapshot 'FileCount' $Label) -ne 10) {
        throw "$Label does not contain exactly ten manifest-bound files."
    }
    Assert-ValidationEmptyArray (Get-ValidationProperty $Snapshot 'MismatchedPaths' $Label) `
        "$Label MismatchedPaths"
    $files = @(Get-ValidationProperty $Snapshot 'Files' $Label)
    if ($files.Count -ne 10) { throw "$Label Files does not contain exactly ten entries." }
    $seen = @{}
    foreach ($entry in $files) {
        $relative = [string](Get-ValidationProperty $entry 'Path' "$Label file")
        if (-not $ExpectedManagedFiles.ContainsKey($relative) -or $seen.ContainsKey($relative)) {
            throw "$Label contains an unexpected or duplicate managed file: $relative"
        }
        $expected = $ExpectedManagedFiles[$relative]
        $actualLength = [long](Get-ValidationProperty $entry 'Length' "$Label file $relative")
        $expectedLength = [long](Get-ValidationProperty $entry 'ExpectedLength' "$Label file $relative")
        $actualSha256 = [string](Get-ValidationProperty $entry 'Sha256' "$Label file $relative")
        $expectedSha256 = [string](Get-ValidationProperty $entry 'ExpectedSha256' "$Label file $relative")
        foreach ($name in @('LengthMatchesManifest', 'Sha256MatchesManifest', 'MatchesManifest')) {
            Assert-ValidationTrue (Get-ValidationProperty $entry $name "$Label file $relative") `
                "$Label file $relative $name"
        }
        if ($actualLength -ne [long]$expected.Length -or $expectedLength -ne [long]$expected.Length -or
            $actualSha256 -cne [string]$expected.Sha256 -or $expectedSha256 -cne [string]$expected.Sha256) {
            throw "$Label does not bind $relative to the current manifest length and SHA-256."
        }
        $seen[$relative] = $true
    }
    if ($seen.Count -ne $ExpectedManagedFiles.Count) {
        throw "$Label omitted a current manifest-managed file."
    }
}

function Assert-SandboxSelfRepairEvidence([object]$ManualStart, [object]$Launcher,
    [Collections.IDictionary]$ExpectedManagedFiles) {
    if ($null -eq $ExpectedManagedFiles -or $ExpectedManagedFiles.Count -ne 10) {
        throw 'The current canonical manifest does not expose the ten-file Sandbox evidence contract.'
    }
    $selfRepair = Get-ValidationProperty $ManualStart 'SelfRepair' 'Windows Sandbox manual start'
    foreach ($name in @('Required', 'InitialExecutionImageAbsent', 'TraceExactlyOneRetry', 'ExactlyOneRetry',
            'FinalDesktopFromExpectedLocalExecutionImage', 'Passed')) {
        Assert-ValidationTrue (Get-ValidationProperty $selfRepair $name 'Windows Sandbox self-repair') `
            "Windows Sandbox self-repair $name"
    }
    if ([string](Get-ValidationProperty $selfRepair 'Architecture' 'Windows Sandbox self-repair') -cne 'x64') {
        throw 'Windows Sandbox self-repair did not exercise the required x64 architecture.'
    }

    $executionImage = Get-ValidationProperty $selfRepair 'ExecutionImage' 'Windows Sandbox self-repair'
    foreach ($name in @('VersionRootExists', 'DirectoryNameMatchesExpected', 'ExecutableExists',
            'NoTransactionResidues', 'Valid')) {
        Assert-ValidationTrue (Get-ValidationProperty $executionImage $name `
                'Windows Sandbox self-repair execution image') `
            "Windows Sandbox self-repair execution image $name"
    }
    foreach ($name in @('RequiredFilesMissing', 'TransactionResidues')) {
        $property = $executionImage.PSObject.Properties[$name]
        if ($null -eq $property -or -not ($property.Value -is [Array]) -or
            $property.Value.Count -ne 0) {
            throw "Windows Sandbox self-repair execution image $name must be an empty array."
        }
    }

    $familyRoot = [string](Get-ValidationProperty $executionImage 'FamilyRoot' `
        'Windows Sandbox self-repair execution image')
    $architectureRoot = [string](Get-ValidationProperty $executionImage 'ArchitectureRoot' `
        'Windows Sandbox self-repair execution image')
    $expectedDirectoryName = [string](Get-ValidationProperty $executionImage 'ExpectedDirectoryName' `
        'Windows Sandbox self-repair execution image')
    $versionRoot = [string](Get-ValidationProperty $executionImage 'VersionRoot' `
        'Windows Sandbox self-repair execution image')
    $executablePath = [string](Get-ValidationProperty $executionImage 'ExecutablePath' `
        'Windows Sandbox self-repair execution image')
    foreach ($entry in @(
            [pscustomobject]@{ Value = $familyRoot; Label = 'family root' },
            [pscustomobject]@{ Value = $architectureRoot; Label = 'architecture root' },
            [pscustomobject]@{ Value = $versionRoot; Label = 'version root' },
            [pscustomobject]@{ Value = $executablePath; Label = 'executable path' }
        )) {
        if ([string]::IsNullOrWhiteSpace($entry.Value) -or -not [IO.Path]::IsPathRooted($entry.Value)) {
            throw "Windows Sandbox self-repair $($entry.Label) is not an absolute path."
        }
    }
    if ([string]::IsNullOrWhiteSpace($expectedDirectoryName) -or
        -not [string]::Equals([IO.Path]::GetFileName($versionRoot.TrimEnd('\\')),
            $expectedDirectoryName, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-PathWithin $architectureRoot $familyRoot) -or
        $architectureRoot.Equals($familyRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-PathWithin $versionRoot $architectureRoot) -or
        $versionRoot.Equals($architectureRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $executablePath.Equals((Join-Path $versionRoot 'app\current\CodexDesktop.exe'),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Windows Sandbox self-repair execution-image paths are inconsistent.'
    }

    $initialAttempt = Get-ValidationProperty $selfRepair 'InitialAttempt' 'Windows Sandbox self-repair'
    $retryAttempt = Get-ValidationProperty $selfRepair 'RetryAttempt' 'Windows Sandbox self-repair'
    $launcherProcessId = [int](Get-ValidationProperty $Launcher 'CoreProcessId' `
        'Windows Sandbox manual start launcher')
    if ($launcherProcessId -le 0) {
        throw 'Windows Sandbox self-repair launcher process evidence is invalid.'
    }
    $attempts = @($initialAttempt, $retryAttempt)
    for ($index = 0; $index -lt $attempts.Count; $index++) {
        $attempt = $attempts[$index]
        foreach ($name in @('IsExecutionImagePath', 'MatchesExpectedExecutionPath')) {
            Assert-ValidationTrue (Get-ValidationProperty $attempt $name `
                    'Windows Sandbox self-repair root attempt') `
                "Windows Sandbox self-repair root attempt $name"
        }
        if ([int](Get-ValidationProperty $attempt 'ProcessId' 'Windows Sandbox self-repair root attempt') -le 0 -or
            [int](Get-ValidationProperty $attempt 'ParentProcessId' 'Windows Sandbox self-repair root attempt') -ne
                $launcherProcessId -or
            [string]::IsNullOrWhiteSpace([string](Get-ValidationProperty $attempt 'FirstObservedUtc' `
                'Windows Sandbox self-repair root attempt')) -or
            -not ([string](Get-ValidationProperty $attempt 'ExecutablePath' `
                    'Windows Sandbox self-repair root attempt')).Equals(
                $executablePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Windows Sandbox self-repair root attempt evidence is invalid.'
        }
    }
    $initialProcessId = [int](Get-ValidationProperty $initialAttempt 'ProcessId' `
        'Windows Sandbox self-repair initial attempt')
    $retryProcessId = [int](Get-ValidationProperty $retryAttempt 'ProcessId' `
        'Windows Sandbox self-repair retry attempt')
    if ($initialProcessId -eq $retryProcessId) {
        throw 'Windows Sandbox self-repair did not prove two distinct attempts from one launcher.'
    }

    $injection = Get-ValidationProperty $selfRepair 'Injection' 'Windows Sandbox self-repair'
    foreach ($name in @('Attempted', 'TerminateProcessSucceeded', 'ProcessExited',
            'ObservedExitCodeMatches')) {
        Assert-ValidationTrue (Get-ValidationProperty $injection $name `
                'Windows Sandbox self-repair injection') `
            "Windows Sandbox self-repair injection $name"
    }
    if ([int](Get-ValidationProperty $injection 'TargetProcessId' `
            'Windows Sandbox self-repair injection') -ne $initialProcessId -or
        [string](Get-ValidationProperty $injection 'Method' `
            'Windows Sandbox self-repair injection') -cne 'TerminateProcess' -or
        [string](Get-ValidationProperty $injection 'RequestedExitCode' `
            'Windows Sandbox self-repair injection') -cne '0xC0000006' -or
        [string](Get-ValidationProperty $injection 'ObservedExitCode' `
            'Windows Sandbox self-repair injection') -cne '0xC0000006') {
        throw 'Windows Sandbox self-repair did not prove the requested in-page-error exit.'
    }

    # Polling is diagnostic only: a short-lived root can disappear between
    # samples. The mandatory Win32_ProcessStartTrace proof below is the
    # authoritative exactly-one-retry evidence.
    $observedAttempts = @(Get-ValidationProperty $selfRepair 'ObservedRootAttempts' `
        'Windows Sandbox self-repair')
    if ([int](Get-ValidationProperty $selfRepair 'ObservedRootAttemptCount' `
            'Windows Sandbox self-repair') -ne $observedAttempts.Count -or
        [int](Get-ValidationProperty $selfRepair 'RetryCount' `
            'Windows Sandbox self-repair') -ne [Math]::Max(0, $observedAttempts.Count - 1)) {
        throw 'Windows Sandbox self-repair polling diagnostics are internally inconsistent.'
    }

    $recoveryProgress = Get-ValidationProperty $selfRepair 'RecoveryProgress' `
        'Windows Sandbox self-repair'
    $expectedStages = @(
        'ValidatingLocalExecutionImage'
        'RebuildingLocalExecutionImage'
        'LocalExecutionImageReady'
        'ConfirmingRetriedDesktopStart'
    )
    $requiredStages = @(Get-ValidationProperty $recoveryProgress 'RecoveryRequiredStages' `
        'Windows Sandbox self-repair progress'
    )
    $observedStages = @(Get-ValidationProperty $recoveryProgress 'RecoveryObservedStages' `
        'Windows Sandbox self-repair progress')
    $stepNumbers = @(Get-ValidationProperty $recoveryProgress 'RecoveryStepNumbers' `
        'Windows Sandbox self-repair progress')
    $transitionSteps = @(Get-ValidationProperty $recoveryProgress 'RecoveryTransitionSteps' `
        'Windows Sandbox self-repair progress')
    $transitionStages = @(Get-ValidationProperty $recoveryProgress 'RecoveryTransitionStages' `
        'Windows Sandbox self-repair progress')
    if (@(Compare-Object -ReferenceObject $expectedStages -DifferenceObject $requiredStages -SyncWindow 0).Count -ne 0 -or
        @(Compare-Object -ReferenceObject $expectedStages -DifferenceObject $observedStages -SyncWindow 0).Count -ne 0 -or
        @(Compare-Object -ReferenceObject @(1, 2, 3, 4) -DifferenceObject $stepNumbers -SyncWindow 0).Count -ne 0 -or
        $transitionSteps.Count -ne 4 -or $transitionStages.Count -ne 4) {
        throw 'Windows Sandbox self-repair progress did not prove the fixed four-stage recovery plan.'
    }
    for ($index = 0; $index -lt 4; $index++) {
        if ([int]$transitionSteps[$index] -ne ($index + 1) -or
            -not [string]::Equals([string]$transitionStages[$index], $expectedStages[$index],
                [StringComparison]::Ordinal)) {
            throw 'Windows Sandbox self-repair progress transitions are out of order or repeated.'
        }
    }
    foreach ($name in @('RecoveryRequiredStagesObserved', 'RecoverySequenceValid',
            'RecoverySequenceOrdered', 'RecoveryFourStepPlanObserved', 'Passed')) {
        Assert-ValidationTrue (Get-ValidationProperty $recoveryProgress $name `
                'Windows Sandbox self-repair progress') `
            "Windows Sandbox self-repair progress $name"
    }

    Assert-ValidationTrue (Get-ValidationProperty $selfRepair 'EarlyStartupPassed' `
            'Windows Sandbox self-repair') 'Windows Sandbox early-startup self-repair'
    $postHandoff = Get-ValidationProperty $selfRepair 'PostHandoffRecovery' `
        'Windows Sandbox self-repair'
    foreach ($name in @('Required', 'RetryAliveBeforeInjection', 'Passed')) {
        Assert-ValidationTrue (Get-ValidationProperty $postHandoff $name `
                'Windows Sandbox post-handoff recovery') `
            "Windows Sandbox post-handoff recovery $name"
    }
    $confirmationMilliseconds = [int](Get-ValidationProperty $postHandoff `
        'StartupConfirmationWindowMilliseconds' 'Windows Sandbox post-handoff recovery')
    $minimumDelayMilliseconds = [int](Get-ValidationProperty $postHandoff `
        'MinimumDelayMilliseconds' 'Windows Sandbox post-handoff recovery')
    $actualDelayMilliseconds = [int](Get-ValidationProperty $postHandoff `
        'ActualDelayMilliseconds' 'Windows Sandbox post-handoff recovery')
    if ($confirmationMilliseconds -ne 9000 -or $minimumDelayMilliseconds -le 9000 -or
        $actualDelayMilliseconds -lt $minimumDelayMilliseconds -or $actualDelayMilliseconds -le 9000) {
        throw 'Windows Sandbox post-handoff recovery did not wait beyond the 9-second startup confirmation window.'
    }

    $knownProcessIds = @(Get-ValidationProperty $postHandoff 'KnownExecutionDesktopProcessIds' `
        'Windows Sandbox post-handoff recovery')
    if ($knownProcessIds.Count -eq 0 -or
        @($knownProcessIds | Where-Object { [int]$_ -eq $retryProcessId }).Count -ne 1) {
        throw 'Windows Sandbox post-handoff recovery did not bind the watchdog to the retried Codex process family.'
    }

    $postInjection = Get-ValidationProperty $postHandoff 'Injection' `
        'Windows Sandbox post-handoff recovery'
    foreach ($name in @('Attempted', 'TerminateProcessSucceeded', 'ProcessExited',
            'ObservedExitCodeMatches')) {
        Assert-ValidationTrue (Get-ValidationProperty $postInjection $name `
                'Windows Sandbox post-handoff injection') `
            "Windows Sandbox post-handoff injection $name"
    }
    if ([int](Get-ValidationProperty $postInjection 'TargetProcessId' `
            'Windows Sandbox post-handoff injection') -ne $retryProcessId -or
        [string](Get-ValidationProperty $postInjection 'Method' `
            'Windows Sandbox post-handoff injection') -cne 'TerminateProcess' -or
        [string](Get-ValidationProperty $postInjection 'RequestedExitCode' `
            'Windows Sandbox post-handoff injection') -cne '0xC0000006' -or
        [string](Get-ValidationProperty $postInjection 'ObservedExitCode' `
            'Windows Sandbox post-handoff injection') -cne '0xC0000006') {
        throw 'Windows Sandbox post-handoff recovery did not prove the required 0xC0000006 injection against the retry root.'
    }

    $probe = Get-ValidationProperty $postHandoff 'Probe' 'Windows Sandbox post-handoff recovery'
    foreach ($name in @('Created', 'RemovedByWatchdog', 'AbsentAfterManualRestart')) {
        Assert-ValidationTrue (Get-ValidationProperty $probe $name `
                'Windows Sandbox post-handoff recovery probe') `
            "Windows Sandbox post-handoff recovery probe $name"
    }
    $probeRelativePath = [string](Get-ValidationProperty $probe 'RelativePath' `
        'Windows Sandbox post-handoff recovery probe')
    $probePath = [string](Get-ValidationProperty $probe 'Path' `
        'Windows Sandbox post-handoff recovery probe')
    $expectedProbePath = [IO.Path]::GetFullPath((Join-Path $versionRoot `
        '.lf-sandbox-post-handoff-recovery-probe'))
    if ($probeRelativePath -cne '.lf-sandbox-post-handoff-recovery-probe' -or
        [string]::IsNullOrWhiteSpace($probePath) -or -not [IO.Path]::IsPathRooted($probePath) -or
        -not ([IO.Path]::GetFullPath($probePath)).Equals($expectedProbePath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Windows Sandbox post-handoff recovery probe is not bound to the expected local execution-image root.'
    }

    $watchdog = Get-ValidationProperty $postHandoff 'Watchdog' `
        'Windows Sandbox post-handoff recovery'
    foreach ($name in @('VersionRootDeleted', 'NoExecutionDesktopProcesses')) {
        Assert-ValidationTrue (Get-ValidationProperty $watchdog $name `
                'Windows Sandbox post-handoff watchdog') `
            "Windows Sandbox post-handoff watchdog $name"
    }
    foreach ($name in @('AutomaticRestartObserved', 'ExecutionImageReappearedBeforeManualAction')) {
        $value = Get-ValidationProperty $watchdog $name 'Windows Sandbox post-handoff watchdog'
        if (-not ($value -is [bool]) -or [bool]$value) {
            throw "Windows Sandbox post-handoff watchdog $name must be the Boolean value false."
        }
    }
    $automaticIdsProperty = $watchdog.PSObject.Properties['AutomaticRestartProcessIds']
    if ($null -eq $automaticIdsProperty -or -not ($automaticIdsProperty.Value -is [Array]) -or
        $automaticIdsProperty.Value.Count -ne 0) {
        throw 'Windows Sandbox post-handoff watchdog recorded an automatic third Codex instance.'
    }
    $observedWatchdogProcessIds = @(Get-ValidationProperty $watchdog 'ObservedDesktopProcessIds' `
        'Windows Sandbox post-handoff watchdog')
    if ($observedWatchdogProcessIds.Count -eq 0 -or
        @($observedWatchdogProcessIds | Where-Object { [int]$_ -eq $retryProcessId }).Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string](Get-ValidationProperty $watchdog 'CompletedUtc' `
                'Windows Sandbox post-handoff watchdog'))) {
        throw 'Windows Sandbox post-handoff watchdog evidence is incomplete or not bound to the retry root.'
    }

    $expectedManagedFiles = @(
        'CodexPortable.exe'
        'CodexData/README.txt'
        'CodexData/THIRD_PARTY.txt'
        'CodexData/portable-release.json'
        'CodexData/tools/launchers/CodexPortable.x86.exe'
        'CodexData/tools/launchers/CodexPortable.x64.exe'
        'CodexData/tools/launchers/CodexPortable.arm64.exe'
        'CodexData/packages/LFPortable-common.zip'
        'CodexData/packages/LFPortable-x64.msix'
        'CodexData/packages/LFPortable-arm64.msix'
    )
    $managedFiles = Get-ValidationProperty $postHandoff 'ManagedFiles' `
        'Windows Sandbox post-handoff recovery'
    $beforeFault = @(Get-ValidationProperty $managedFiles 'BeforeFault' `
        'Windows Sandbox post-handoff managed files')
    $afterWatchdog = @(Get-ValidationProperty $managedFiles 'AfterWatchdog' `
        'Windows Sandbox post-handoff managed files')
    if ($beforeFault.Count -ne 10 -or $afterWatchdog.Count -ne 10) {
        throw 'Windows Sandbox post-handoff recovery did not hash exactly ten managed files before and after watchdog cleanup.'
    }
    $beforeHashes = @{}
    $afterHashes = @{}
    foreach ($set in @(
            [pscustomobject]@{ Entries = $beforeFault; Hashes = $beforeHashes; Label = 'before fault' },
            [pscustomobject]@{ Entries = $afterWatchdog; Hashes = $afterHashes; Label = 'after watchdog' }
        )) {
        foreach ($entry in $set.Entries) {
            $relative = [string](Get-ValidationProperty $entry 'Path' `
                "Windows Sandbox managed-file hash $($set.Label)")
            $sha256 = [string](Get-ValidationProperty $entry 'Sha256' `
                "Windows Sandbox managed-file hash $($set.Label)")
            if (-not ($expectedManagedFiles -ccontains $relative) -or
                $set.Hashes.ContainsKey($relative) -or $sha256 -notmatch '^[0-9A-F]{64}$') {
                throw "Windows Sandbox managed-file hash evidence is invalid or duplicated $($set.Label): $relative"
            }
            $set.Hashes[$relative] = $sha256
        }
    }
    foreach ($relative in $expectedManagedFiles) {
        if (-not $beforeHashes.ContainsKey($relative) -or -not $afterHashes.ContainsKey($relative) -or
            -not [string]::Equals([string]$beforeHashes[$relative], [string]$afterHashes[$relative],
                [StringComparison]::Ordinal)) {
            throw "Windows Sandbox post-handoff watchdog changed or omitted managed file: $relative"
        }
    }
    $managedComparison = Get-ValidationProperty $managedFiles 'Comparison' `
        'Windows Sandbox post-handoff managed files'
    Assert-ValidationTrue (Get-ValidationProperty $managedComparison 'Unchanged' `
            'Windows Sandbox post-handoff managed-file comparison') `
        'Windows Sandbox post-handoff managed files Unchanged'
    if ([int](Get-ValidationProperty $managedComparison 'ExpectedFileCount' `
            'Windows Sandbox post-handoff managed-file comparison') -ne 10 -or
        [int](Get-ValidationProperty $managedComparison 'BeforeFileCount' `
            'Windows Sandbox post-handoff managed-file comparison') -ne 10 -or
        [int](Get-ValidationProperty $managedComparison 'AfterFileCount' `
            'Windows Sandbox post-handoff managed-file comparison') -ne 10) {
        throw 'Windows Sandbox post-handoff managed-file comparison has invalid file counts.'
    }
    $changedFilesProperty = $managedComparison.PSObject.Properties['ChangedOrMissingFiles']
    if ($null -eq $changedFilesProperty -or -not ($changedFilesProperty.Value -is [Array]) -or
        $changedFilesProperty.Value.Count -ne 0) {
        throw 'Windows Sandbox post-handoff managed-file comparison contains changed or missing files.'
    }

    $manualRestart = Get-ValidationProperty $postHandoff 'ManualRestart' `
        'Windows Sandbox post-handoff recovery'
    foreach ($name in @('ActualButtonClicked', 'ExactlyOneRootAttempt', 'MainWindowObserved',
            'LauncherExitedAfterHandoff')) {
        Assert-ValidationTrue (Get-ValidationProperty $manualRestart $name `
                'Windows Sandbox post-handoff manual restart') `
            "Windows Sandbox post-handoff manual restart $name"
    }
    $restartBootstrapperId = [int](Get-ValidationProperty $manualRestart 'BootstrapperProcessId' `
        'Windows Sandbox post-handoff manual restart')
    $restartLauncherId = [int](Get-ValidationProperty $manualRestart 'CoreLauncherProcessId' `
        'Windows Sandbox post-handoff manual restart')
    $startButtonLabel = [string](Get-ValidationProperty $manualRestart 'StartButtonLabel' `
        'Windows Sandbox post-handoff manual restart')
    if ($restartBootstrapperId -le 0 -or $restartLauncherId -le 0 -or
        $restartBootstrapperId -eq $restartLauncherId -or
        $startButtonLabel -cnotin @('Start Codex', '启动 Codex') -or
        [int](Get-ValidationProperty $manualRestart 'PreClickExecutionDesktopProcessCount' `
            'Windows Sandbox post-handoff manual restart') -ne 0) {
        throw 'Windows Sandbox post-handoff manual restart did not prove a clean user-visible Start Codex action.'
    }
    $restartAttempt = Get-ValidationProperty $manualRestart 'RootAttempt' `
        'Windows Sandbox post-handoff manual restart'
    foreach ($name in @('IsExecutionImagePath', 'MatchesExpectedExecutionPath')) {
        Assert-ValidationTrue (Get-ValidationProperty $restartAttempt $name `
                'Windows Sandbox post-handoff manual-restart root') `
            "Windows Sandbox post-handoff manual-restart root $name"
    }
    $restartProcessId = [int](Get-ValidationProperty $restartAttempt 'ProcessId' `
        'Windows Sandbox post-handoff manual-restart root')
    if ($restartProcessId -le 0 -or $restartProcessId -in @($initialProcessId, $retryProcessId) -or
        [int](Get-ValidationProperty $restartAttempt 'ParentProcessId' `
            'Windows Sandbox post-handoff manual-restart root') -ne $restartLauncherId -or
        -not ([string](Get-ValidationProperty $restartAttempt 'ExecutablePath' `
                'Windows Sandbox post-handoff manual-restart root')).Equals(
            $executablePath, [StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace([string](Get-ValidationProperty $restartAttempt `
                'FirstObservedUtc' 'Windows Sandbox post-handoff manual-restart root'))) {
        throw 'Windows Sandbox post-handoff manual-restart root evidence is invalid.'
    }
    # As above, do not use polling as an authority for the single-root claim.
    # TraceRootSequence is mandatory and validated below.
    $restartAttempts = @(Get-ValidationProperty $manualRestart 'ObservedRootAttempts' `
        'Windows Sandbox post-handoff manual restart')
    if ([int](Get-ValidationProperty $manualRestart 'ObservedRootAttemptCount' `
            'Windows Sandbox post-handoff manual restart') -ne $restartAttempts.Count) {
        throw 'Windows Sandbox post-handoff manual-restart polling diagnostics are internally inconsistent.'
    }

    $restartProgress = Get-ValidationProperty $manualRestart 'Progress' `
        'Windows Sandbox post-handoff manual restart'
    foreach ($name in @('ProgressBarObserved', 'ProgressRangeValid', 'ProgressAdvanced',
            'ExplicitStagesObserved', 'Passed')) {
        Assert-ValidationTrue (Get-ValidationProperty $restartProgress $name `
                'Windows Sandbox post-handoff manual-restart progress') `
            "Windows Sandbox post-handoff manual-restart progress $name"
    }
    foreach ($name in @('IndeterminateStyleObserved', 'InvalidProgressRangeObserved')) {
        $value = Get-ValidationProperty $restartProgress $name `
            'Windows Sandbox post-handoff manual-restart progress'
        if (-not ($value -is [bool]) -or [bool]$value) {
            throw "Windows Sandbox post-handoff manual-restart progress $name must be false."
        }
    }
    foreach ($name in @('AmbiguousLabels', 'GenericStatusLabels')) {
        $property = $restartProgress.PSObject.Properties[$name]
        if ($null -eq $property -or -not ($property.Value -is [Array]) -or $property.Value.Count -ne 0) {
            throw "Windows Sandbox post-handoff manual-restart progress $name must be an empty array."
        }
    }
    if ([int](Get-ValidationProperty $restartProgress 'DistinctPositionCount' `
            'Windows Sandbox post-handoff manual-restart progress') -lt 2 -or
        [int](Get-ValidationProperty $restartProgress 'ExplicitStageKindCount' `
            'Windows Sandbox post-handoff manual-restart progress') -lt 3) {
        throw 'Windows Sandbox post-handoff manual restart did not expose advancing determinate stage progress.'
    }

    $restartImage = Get-ValidationProperty $manualRestart 'ExecutionImage' `
        'Windows Sandbox post-handoff manual restart'
    foreach ($name in @('VersionRootExists', 'DirectoryNameMatchesExpected', 'ExecutableExists',
            'NoTransactionResidues', 'Valid')) {
        Assert-ValidationTrue (Get-ValidationProperty $restartImage $name `
                'Windows Sandbox post-handoff rebuilt execution image') `
            "Windows Sandbox post-handoff rebuilt execution image $name"
    }
    if (-not ([string](Get-ValidationProperty $restartImage 'VersionRoot' `
                'Windows Sandbox post-handoff rebuilt execution image')).Equals(
            $versionRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string](Get-ValidationProperty $restartImage 'ExecutablePath' `
                'Windows Sandbox post-handoff rebuilt execution image')).Equals(
            $executablePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Windows Sandbox post-handoff rebuilt execution-image identity is inconsistent.'
    }
    foreach ($name in @('RequiredFilesMissing', 'TransactionResidues')) {
        $property = $restartImage.PSObject.Properties[$name]
        if ($null -eq $property -or -not ($property.Value -is [Array]) -or $property.Value.Count -ne 0) {
            throw "Windows Sandbox post-handoff rebuilt execution image $name must be an empty array."
        }
    }

    foreach ($name in @('TraceNoAutomaticRestart', 'ArmedAndAvailableAfterHandoff',
            'RecoveryHelperExited', 'RecoveryHelperExitCodeMatches')) {
        Assert-ValidationTrue (Get-ValidationProperty $watchdog $name `
                'Windows Sandbox post-handoff watchdog') `
            "Windows Sandbox post-handoff watchdog $name"
    }
    Assert-ValidationEmptyArray (Get-ValidationProperty $watchdog 'TraceAutomaticRestartEvents' `
            'Windows Sandbox post-handoff watchdog') `
        'Windows Sandbox post-handoff watchdog TraceAutomaticRestartEvents'
    $lateRecoveryHelper = Get-ValidationProperty $watchdog 'RecoveryHelper' `
        'Windows Sandbox post-handoff watchdog'
    Assert-SandboxTraceBoundRecoveryHelper $lateRecoveryHelper $launcherProcessId `
        'Windows Sandbox post-handoff LF recovery helper'
    if ([string](Get-ValidationProperty $watchdog 'RecoveryHelperExitCode' `
            'Windows Sandbox post-handoff watchdog') -cne '0x00000000') {
        throw 'Windows Sandbox post-handoff LF recovery helper did not exit successfully.'
    }

    foreach ($name in @('TraceExactlyOneRootAttempt')) {
        Assert-ValidationTrue (Get-ValidationProperty $manualRestart $name `
                'Windows Sandbox post-handoff manual restart') `
            "Windows Sandbox post-handoff manual restart $name"
    }
    Assert-SandboxTraceBoundAttempt $initialAttempt $initialProcessId $launcherProcessId `
        'Windows Sandbox self-repair initial attempt'
    Assert-SandboxTraceBoundAttempt $retryAttempt $retryProcessId $launcherProcessId `
        'Windows Sandbox self-repair retry attempt'
    Assert-SandboxTraceBoundAttempt $restartAttempt $restartProcessId $restartLauncherId `
        'Windows Sandbox post-handoff manual-restart attempt'

    $managedRelease = Get-ValidationProperty $selfRepair 'ManagedRelease' `
        'Windows Sandbox self-repair'
    if ([int](Get-ValidationProperty $managedRelease 'ManifestFileCount' `
            'Windows Sandbox managed release') -ne 10) {
        throw 'Windows Sandbox managed-release evidence does not declare exactly ten files.'
    }
    $managedStages = @(
        [pscustomobject]@{ Name = 'AfterCopy'; Label = 'after Sandbox copy' }
        [pscustomobject]@{ Name = 'BeforeLateFault'; Label = 'before late fault' }
        [pscustomobject]@{ Name = 'AfterLateWatchdog'; Label = 'after late watchdog' }
        [pscustomobject]@{ Name = 'BeforeNormalExit'; Label = 'before normal exit' }
        [pscustomobject]@{ Name = 'AfterNormalExit'; Label = 'after normal exit' }
    )
    foreach ($stage in $managedStages) {
        $snapshot = Get-ValidationProperty $managedRelease $stage.Name `
            'Windows Sandbox managed release'
        Assert-SandboxManagedReleaseSnapshot $snapshot $ExpectedManagedFiles `
            "Windows Sandbox managed release $($stage.Label)"
    }
    foreach ($name in @('AllMatchManifest', 'AllIdentical')) {
        Assert-ValidationTrue (Get-ValidationProperty $managedRelease $name `
                'Windows Sandbox managed release') "Windows Sandbox managed release $name"
    }
    $normalManagedComparison = Get-ValidationProperty $managedRelease 'NormalExitComparison' `
        'Windows Sandbox managed release'
    Assert-ValidationTrue (Get-ValidationProperty $normalManagedComparison 'Unchanged' `
            'Windows Sandbox normal-exit managed-file comparison') `
        'Windows Sandbox normal-exit managed-file comparison Unchanged'
    foreach ($name in @('ExpectedFileCount', 'BeforeFileCount', 'AfterFileCount')) {
        if ([int](Get-ValidationProperty $normalManagedComparison $name `
                'Windows Sandbox normal-exit managed-file comparison') -ne 10) {
            throw "Windows Sandbox normal-exit managed-file comparison $name must equal ten."
        }
    }
    Assert-ValidationEmptyArray (Get-ValidationProperty $normalManagedComparison `
            'ChangedOrMissingFiles' 'Windows Sandbox normal-exit managed-file comparison') `
        'Windows Sandbox normal-exit managed-file comparison ChangedOrMissingFiles'

    $processStartTrace = Get-ValidationProperty $selfRepair 'ProcessStartTrace' `
        'Windows Sandbox self-repair'
    foreach ($name in @('Required', 'Available', 'Healthy', 'Passed')) {
        Assert-ValidationTrue (Get-ValidationProperty $processStartTrace $name `
                'Windows Sandbox process-start trace') `
            "Windows Sandbox process-start trace $name"
    }
    $traceSessionId = [int](Get-ValidationProperty $processStartTrace 'SessionId' `
        'Windows Sandbox process-start trace')
    if ([string](Get-ValidationProperty $processStartTrace 'Provider' `
            'Windows Sandbox process-start trace') -cne 'System.Management.ManagementEventWatcher' -or
        [string](Get-ValidationProperty $processStartTrace 'EventClass' `
            'Windows Sandbox process-start trace') -cne 'Win32_ProcessStartTrace' -or
        [string](Get-ValidationProperty $processStartTrace 'Query' `
            'Windows Sandbox process-start trace') -cne 'SELECT * FROM Win32_ProcessStartTrace' -or
        $traceSessionId -le 0 -or
        [string]::IsNullOrWhiteSpace([string](Get-ValidationProperty $processStartTrace `
                'SubscriptionStartedUtc' 'Windows Sandbox process-start trace'))) {
        throw 'Windows Sandbox did not use the mandatory Win32_ProcessStartTrace provider contract.'
    }
    Assert-SandboxTraceProbe (Get-ValidationProperty $processStartTrace 'StartProbe' `
            'Windows Sandbox process-start trace') 'Windows Sandbox start-of-test trace probe'
    Assert-SandboxTraceProbe (Get-ValidationProperty $processStartTrace 'EndProbe' `
            'Windows Sandbox process-start trace') 'Windows Sandbox end-of-test trace probe'
    Assert-SandboxTraceRootSequence (Get-ValidationProperty $processStartTrace 'FirstLaunch' `
            'Windows Sandbox process-start trace') $traceSessionId $launcherProcessId `
        @($initialProcessId, $retryProcessId) 'Windows Sandbox initial self-repair trace sequence'

    $lateFaultWindow = Get-ValidationProperty $processStartTrace 'LateFaultWindow' `
        'Windows Sandbox process-start trace'
    Assert-ValidationTrue (Get-ValidationProperty $lateFaultWindow 'NoAutomaticRestart' `
            'Windows Sandbox late-fault trace window') `
        'Windows Sandbox late-fault trace window NoAutomaticRestart'
    if ([int](Get-ValidationProperty $lateFaultWindow 'Cursor' `
            'Windows Sandbox late-fault trace window') -le 0) {
        throw 'Windows Sandbox late-fault trace cursor is invalid.'
    }
    Assert-ValidationEmptyArray (Get-ValidationProperty $lateFaultWindow 'UnexpectedCodexStarts' `
            'Windows Sandbox late-fault trace window') `
        'Windows Sandbox late-fault trace window UnexpectedCodexStarts'
    Assert-SandboxTraceRootSequence (Get-ValidationProperty $manualRestart 'TraceRootSequence' `
            'Windows Sandbox post-handoff manual restart') $traceSessionId $restartLauncherId `
        @($restartProcessId) 'Windows Sandbox post-handoff manual-start trace sequence'

    $finalTraceAudit = Get-ValidationProperty $processStartTrace 'FinalAudit' `
        'Windows Sandbox process-start trace'
    foreach ($name in @('AllExpectedRootBindingsValid', 'NoUnexpectedProcessStarts', 'Passed')) {
        Assert-ValidationTrue (Get-ValidationProperty $finalTraceAudit $name `
                'Windows Sandbox final process-start trace audit') `
            "Windows Sandbox final process-start trace audit $name"
    }
    if ([string](Get-ValidationProperty $finalTraceAudit 'Provider' `
            'Windows Sandbox final process-start trace audit') -cne
            'System.Management.ManagementEventWatcher' -or
        [string](Get-ValidationProperty $finalTraceAudit 'EventClass' `
            'Windows Sandbox final process-start trace audit') -cne 'Win32_ProcessStartTrace' -or
        [int](Get-ValidationProperty $finalTraceAudit 'SessionId' `
            'Windows Sandbox final process-start trace audit') -ne $traceSessionId -or
        [int](Get-ValidationProperty $finalTraceAudit 'MinimumEventOrdinal' `
            'Windows Sandbox final process-start trace audit') -le 0 -or
        [int](Get-ValidationProperty $finalTraceAudit 'RecordCount' `
            'Windows Sandbox final process-start trace audit') -lt 3) {
        throw 'Windows Sandbox final process-start trace audit metadata is invalid.'
    }
    Assert-ValidationEmptyArray (Get-ValidationProperty $finalTraceAudit 'UnexpectedProcessStarts' `
            'Windows Sandbox final process-start trace audit') `
        'Windows Sandbox final process-start trace audit UnexpectedProcessStarts'
    $expectedBindings = @(
        [pscustomobject]@{ Label = 'InitialAttempt'; ProcessId = $initialProcessId; ParentProcessId = $launcherProcessId }
        [pscustomobject]@{ Label = 'RetryAttempt'; ProcessId = $retryProcessId; ParentProcessId = $launcherProcessId }
        [pscustomobject]@{ Label = 'ManualRestart'; ProcessId = $restartProcessId; ParentProcessId = $restartLauncherId }
    )
    $bindings = @(Get-ValidationProperty $finalTraceAudit 'ExpectedRootBindings' `
        'Windows Sandbox final process-start trace audit')
    if ($bindings.Count -ne $expectedBindings.Count) {
        throw 'Windows Sandbox final process-start trace audit has an invalid binding count.'
    }
    for ($index = 0; $index -lt $expectedBindings.Count; $index++) {
        $binding = $bindings[$index]
        $expectedBinding = $expectedBindings[$index]
        Assert-ValidationTrue (Get-ValidationProperty $binding 'Valid' `
                'Windows Sandbox final process-start trace binding') `
            'Windows Sandbox final process-start trace binding Valid'
        if ([string](Get-ValidationProperty $binding 'Label' `
                'Windows Sandbox final process-start trace binding') -cne $expectedBinding.Label -or
            [int](Get-ValidationProperty $binding 'ProcessId' `
                'Windows Sandbox final process-start trace binding') -ne $expectedBinding.ProcessId -or
            [int](Get-ValidationProperty $binding 'ParentProcessId' `
                'Windows Sandbox final process-start trace binding') -ne $expectedBinding.ParentProcessId -or
            [int](Get-ValidationProperty $binding 'MatchCount' `
                'Windows Sandbox final process-start trace binding') -ne 1) {
            throw 'Windows Sandbox final process-start trace binding is inconsistent.'
        }
        Assert-SandboxTraceEvent (Get-ValidationProperty $binding 'TraceEvent' `
                'Windows Sandbox final process-start trace binding') `
            $expectedBinding.ProcessId $expectedBinding.ParentProcessId $traceSessionId `
            'CodexDesktop.exe' "Windows Sandbox final trace binding $($expectedBinding.Label)"
    }

    $normalExit = Get-ValidationProperty $selfRepair 'NormalExitControl' `
        'Windows Sandbox self-repair'
    foreach ($name in @('Required', 'Attempted', 'TerminateProcessSucceeded', 'ProcessExited',
            'ObservedExitCodeMatches', 'NoAutomaticRestart', 'RecoveryHelperExited',
            'RecoveryHelperExitCodeMatches', 'VersionRootPreserved',
            'NoExecutionDesktopProcesses', 'ManagedFilesUnchanged', 'Passed')) {
        Assert-ValidationTrue (Get-ValidationProperty $normalExit $name `
                'Windows Sandbox normal-exit control') `
            "Windows Sandbox normal-exit control $name"
    }
    if ([string](Get-ValidationProperty $normalExit 'Method' `
            'Windows Sandbox normal-exit control') -cne 'TerminateProcess' -or
        [string](Get-ValidationProperty $normalExit 'RequestedExitCode' `
            'Windows Sandbox normal-exit control') -cne '0x00000000' -or
        [string](Get-ValidationProperty $normalExit 'ObservedExitCode' `
            'Windows Sandbox normal-exit control') -cne '0x00000000' -or
        [int](Get-ValidationProperty $normalExit 'TargetProcessId' `
            'Windows Sandbox normal-exit control') -ne $restartProcessId -or
        [int](Get-ValidationProperty $normalExit 'TraceCursor' `
            'Windows Sandbox normal-exit control') -le 0 -or
        [string](Get-ValidationProperty $normalExit 'RecoveryHelperExitCode' `
            'Windows Sandbox normal-exit control') -cne '0x00000000') {
        throw 'Windows Sandbox normal-exit control did not prove a successful zero exit.'
    }
    Assert-ValidationEmptyArray (Get-ValidationProperty $normalExit 'NewCodexStartEvents' `
            'Windows Sandbox normal-exit control') `
        'Windows Sandbox normal-exit control NewCodexStartEvents'
    $normalRecoveryHelper = Get-ValidationProperty $normalExit 'RecoveryHelper' `
        'Windows Sandbox normal-exit control'
    Assert-SandboxTraceBoundRecoveryHelper $normalRecoveryHelper $restartLauncherId `
        'Windows Sandbox normal-exit LF recovery helper'
    $normalProbe = Get-ValidationProperty $normalExit 'Probe' `
        'Windows Sandbox normal-exit control'
    foreach ($name in @('Created', 'Preserved')) {
        Assert-ValidationTrue (Get-ValidationProperty $normalProbe $name `
                'Windows Sandbox normal-exit probe') "Windows Sandbox normal-exit probe $name"
    }
    $normalProbeRelative = [string](Get-ValidationProperty $normalProbe 'RelativePath' `
        'Windows Sandbox normal-exit probe')
    $normalProbePath = [string](Get-ValidationProperty $normalProbe 'Path' `
        'Windows Sandbox normal-exit probe')
    if ($normalProbeRelative -cne '.lf-sandbox-normal-exit-preservation-probe' -or
        [string]::IsNullOrWhiteSpace($normalProbePath) -or -not [IO.Path]::IsPathRooted($normalProbePath) -or
        -not ([IO.Path]::GetFullPath($normalProbePath)).Equals(
            [IO.Path]::GetFullPath((Join-Path $versionRoot $normalProbeRelative)),
            [StringComparison]::OrdinalIgnoreCase) -or
        [string](Get-ValidationProperty $normalProbe 'Sha256' `
            'Windows Sandbox normal-exit probe') -notmatch '^[0-9A-F]{64}$') {
        throw 'Windows Sandbox normal-exit preservation probe is invalid.'
    }
    $normalExecutionImage = Get-ValidationProperty $normalExit 'ExecutionImage' `
        'Windows Sandbox normal-exit control'
    foreach ($name in @('VersionRootExists', 'DirectoryNameMatchesExpected', 'ExecutableExists',
            'NoTransactionResidues', 'Valid')) {
        Assert-ValidationTrue (Get-ValidationProperty $normalExecutionImage $name `
                'Windows Sandbox normal-exit execution image') `
            "Windows Sandbox normal-exit execution image $name"
    }
    foreach ($name in @('RequiredFilesMissing', 'TransactionResidues')) {
        Assert-ValidationEmptyArray (Get-ValidationProperty $normalExecutionImage $name `
                'Windows Sandbox normal-exit execution image') `
            "Windows Sandbox normal-exit execution image $name"
    }
    if (-not ([string](Get-ValidationProperty $normalExecutionImage 'VersionRoot' `
                'Windows Sandbox normal-exit execution image')).Equals(
            $versionRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string](Get-ValidationProperty $normalExecutionImage 'ExecutablePath' `
                'Windows Sandbox normal-exit execution image')).Equals(
            $executablePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Windows Sandbox normal-exit control did not preserve the same execution image.'
    }

    $traceRelevantEvents = @(Get-ValidationProperty $processStartTrace 'RelevantEvents' `
        'Windows Sandbox process-start trace')
    if ($traceRelevantEvents.Count -lt 5) {
        throw 'Windows Sandbox process-start trace omitted required Codex or LF recovery events.'
    }
    $expectedHelperEvidence = @($lateRecoveryHelper, $normalRecoveryHelper)
    $helperEvents = @($traceRelevantEvents | Where-Object {
            [string](Get-ValidationProperty $_ 'ProcessName' 'Windows Sandbox relevant trace event') `
                -like 'LFRecovery-*.exe'
        })
    if ($helperEvents.Count -ne 2) {
        throw 'Windows Sandbox process-start trace did not record exactly two LF recovery helpers.'
    }
    foreach ($helper in $expectedHelperEvidence) {
        $helperPid = [int](Get-ValidationProperty $helper 'ProcessId' `
            'Windows Sandbox expected LF recovery helper')
        $helperParentPid = [int](Get-ValidationProperty $helper 'ParentProcessId' `
            'Windows Sandbox expected LF recovery helper')
        $helperName = [string](Get-ValidationProperty $helper 'ProcessName' `
            'Windows Sandbox expected LF recovery helper')
        $matches = @($helperEvents | Where-Object {
                [int](Get-ValidationProperty $_ 'ProcessId' 'Windows Sandbox relevant LF helper event') -eq $helperPid
            })
        if ($matches.Count -ne 1) {
            throw 'Windows Sandbox relevant trace events omitted or duplicated an LF recovery helper.'
        }
        Assert-SandboxTraceEvent $matches[0] $helperPid $helperParentPid $traceSessionId $helperName `
            'Windows Sandbox relevant LF recovery helper trace event'
    }

    $derivedState = Get-ValidationProperty $ManualStart 'DerivedState' 'Windows Sandbox manual start'
    $derivedDesktop = Get-ValidationProperty $derivedState 'Desktop' 'Windows Sandbox manual start'
    Assert-ValidationTrue (Get-ValidationProperty $derivedDesktop 'MainWindowObserved' `
            'Windows Sandbox final desktop') 'Windows Sandbox final desktop MainWindowObserved'
    if ([int](Get-ValidationProperty $derivedDesktop 'ProcessId' `
            'Windows Sandbox final desktop') -ne $restartProcessId -or
        -not ([string](Get-ValidationProperty $derivedDesktop 'ExecutablePath' `
                'Windows Sandbox final desktop')).Equals(
            $executablePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Windows Sandbox final desktop is not the manually rebuilt post-handoff Codex root.'
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

function New-FreshSandboxEvidenceRoot([string]$Parent) {
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $candidate = Join-Path $Parent ('.lf-sandbox-evidence-' + [Guid]::NewGuid().ToString('N'))
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "Unable to allocate a fresh Windows Sandbox evidence root beneath: $Parent"
}

function Invoke-FreshSandboxValidation([string]$SourceRoot, [string]$ManifestFullPath,
    [string]$EvidenceRoot, [string]$ExpectedManifestHash) {
    $invoker = Join-Path $PSScriptRoot 'Invoke-CompactFirstRunSandbox.ps1'
    if (-not (Test-Path -LiteralPath $invoker -PathType Leaf)) {
        throw "The tracked Windows Sandbox launcher is missing: $invoker"
    }
    Assert-NoReparseAncestry $invoker 'Windows Sandbox launcher'
    $outputs = @(& $invoker -SourceRoot $SourceRoot -ManifestPath $ManifestFullPath `
        -EvidenceRoot $EvidenceRoot -Launch)
    if ($outputs.Count -ne 1) {
        throw "Windows Sandbox launcher returned an unexpected output count: $($outputs.Count)"
    }
    $launch = $outputs[0]
    Assert-ValidationTrue (Get-ValidationProperty $launch 'Passed' 'Windows Sandbox launcher result') `
        'Windows Sandbox launcher result Passed'
    if ([string](Get-ValidationProperty $launch 'Status' 'Windows Sandbox launcher result') -cne 'Passed') {
        throw 'Windows Sandbox launcher result status is not Passed.'
    }
    $returnedEvidenceRoot = [IO.Path]::GetFullPath([string](Get-ValidationProperty $launch `
            'EvidenceRoot' 'Windows Sandbox launcher result'))
    if (-not $returnedEvidenceRoot.Equals([IO.Path]::GetFullPath($EvidenceRoot),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Windows Sandbox launcher returned a different evidence root.'
    }
    if (-not ([string](Get-ValidationProperty $launch 'ManifestSha256' `
                'Windows Sandbox launcher result')).Equals($ExpectedManifestHash,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Windows Sandbox launcher did not bind its result to the current manifest SHA-256.'
    }
    Assert-ValidationTrue (Get-ValidationProperty $launch 'CanonicalReleaseRevalidatedAfterSandbox' `
            'Windows Sandbox launcher result') `
        'Windows Sandbox launcher result CanonicalReleaseRevalidatedAfterSandbox'
    if ([int](Get-ValidationProperty $launch 'CanonicalManagedFileCount' `
            'Windows Sandbox launcher result') -ne 10 -or
        [string]::IsNullOrWhiteSpace([string](Get-ValidationProperty $launch `
                'CanonicalRevalidatedUtc' 'Windows Sandbox launcher result'))) {
        throw 'Windows Sandbox launcher did not revalidate all ten canonical managed files after Sandbox completion.'
    }
    $resultPath = [string](Get-ValidationProperty $launch 'ResultPath' 'Windows Sandbox launcher result')
    $resultFull = [IO.Path]::GetFullPath($resultPath)
    if (-not (Test-Path -LiteralPath $resultFull -PathType Leaf)) {
        throw "Windows Sandbox launcher result file is missing: $resultPath"
    }
    Assert-NoReparseAncestry $resultFull 'Windows Sandbox validation result'
    if (-not (Test-PathWithin $resultFull $returnedEvidenceRoot)) {
        throw 'Windows Sandbox result is outside the newly generated evidence root.'
    }
    $expectedResultFull = [IO.Path]::GetFullPath((Join-Path $returnedEvidenceRoot `
        'guest-output\sandbox-first-run-result.json'))
    if (-not $resultFull.Equals($expectedResultFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Windows Sandbox launcher returned an unexpected result path.'
    }
    foreach ($binding in @(
            [pscustomobject]@{ Name = 'SourceRoot'; Expected = $SourceRoot },
            [pscustomobject]@{ Name = 'ManifestPath'; Expected = $ManifestFullPath }
        )) {
        $actual = [IO.Path]::GetFullPath([string](Get-ValidationProperty $launch $binding.Name `
                'Windows Sandbox launcher result'))
        if (-not $actual.Equals([IO.Path]::GetFullPath([string]$binding.Expected),
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Windows Sandbox launcher returned a different $($binding.Name)."
        }
    }
    return $launch
}

function Assert-SandboxFirstRunValidation([string]$ResultPath, [string]$ManifestHash,
    [string]$ReleaseVersion, [string]$ManifestFullPath, [string]$SourceRoot, [string]$UsbRoot,
    [Collections.IDictionary]$ExpectedManagedFiles) {
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
    if ([string](Get-ValidationProperty $proof 'ValidationArchitecture' 'Windows Sandbox validation result') -cne 'x64' -or
        [string](Get-ValidationProperty $proof 'FollowUpQueueMode' 'Windows Sandbox validation result') -cne 'steer') {
        throw 'Windows Sandbox validation result does not prove the x64 steer follow-up queue contract.'
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
    $initialConfig = Get-ValidationProperty $manualStart 'InitialConfig' 'Windows Sandbox manual start'
    Assert-ValidationTrue (Get-ValidationProperty $initialConfig 'FollowUpQueueModeValid' 'Windows Sandbox initial config.toml') `
        'Windows Sandbox initial config.toml desktop follow-up queue mode'
    $derived = Get-ValidationProperty $manualStart 'DerivedState' 'Windows Sandbox manual start'
    $config = Get-ValidationProperty $derived 'ConfigToml' 'Windows Sandbox manual start'
    Assert-ValidationTrue (Get-ValidationProperty $config 'RootPermissionsStillValid' 'Windows Sandbox config.toml') `
        'Windows Sandbox config.toml root permissions'
    Assert-ValidationTrue (Get-ValidationProperty $config 'FollowUpQueueModeValid' 'Windows Sandbox config.toml') `
        'Windows Sandbox config.toml desktop follow-up queue mode'
    Assert-SandboxSelfRepairEvidence $manualStart $launcher $ExpectedManagedFiles

    [pscustomobject]@{
        ResultPath = $resultFull
        ManifestSha256 = $ManifestHash
        ReleaseVersion = $ReleaseVersion
        ValidationArchitecture = 'x64'
        FollowUpQueueMode = 'steer'
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

function Test-ManagedProcessPath([string]$Path, [string]$Root, [string]$ExecutionFamilyRoot) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path)
    # A process anywhere below the USB root can retain a file or keep stale
    # state alive while the atomic replacement is activated. Protect the whole
    # installation, including auxiliary tools such as voice-input helpers,
    # rather than maintaining a fragile allow-list of managed subdirectories.
    if ($pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return Test-ExecutionDesktopProcessPath $pathFull $ExecutionFamilyRoot
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
    $executionFamilyRoot = Get-ExecutionFamilyRoot $Root
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            Test-ManagedProcessPath ([string]$_.ExecutablePath) $Root $executionFamilyRoot
        })
    }
    catch {
        return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try {
                $path = $_.Path
                Test-ManagedProcessPath $path $Root $executionFamilyRoot
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

function Assert-CanonicalReleaseUnchanged([string]$Root, [string]$ManifestFullPath,
    [string]$ExpectedManifestHash, [string[]]$ExpectedDirectories, [string[]]$ExpectedFiles,
    [hashtable]$ExpectedMetadata, [hashtable]$BaselineHashes, [string]$Label) {
    $currentManifestHash = Get-Sha256 $ManifestFullPath
    if (-not $currentManifestHash.Equals($ExpectedManifestHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label manifest SHA-256 changed: expected $ExpectedManifestHash, actual $currentManifestHash"
    }
    Assert-CompactTree $Root $ExpectedDirectories $ExpectedFiles $ExpectedMetadata $Label
    $currentHashes = Get-VerifiedManagedHashes $Root $ExpectedFiles $ExpectedMetadata $Label
    foreach ($relative in $ExpectedFiles) {
        if (-not $BaselineHashes.ContainsKey($relative) -or
            -not ([string]$currentHashes[$relative]).Equals([string]$BaselineHashes[$relative],
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label managed file changed after the verified baseline: $relative"
        }
    }
    return $currentHashes
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
$sandboxEvidenceParentFull = Resolve-FullPath $SandboxEvidenceParent 'Sandbox evidence parent'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
Assert-SourceIsNotUsb $source
$manifestFull = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $manifestFull -PathType Leaf)) { throw "Release manifest is missing: $manifestFull" }
if (Test-PathWithin $source $usb -or Test-PathWithin $usb $source) { throw 'Source release and USB root must be separate paths.' }
Assert-NoReparseAncestry $source 'Source release'
Assert-NoReparseAncestry $usb 'USB root'
Assert-NoReparseAncestry $manifestFull 'Release manifest'
Assert-UsbVolume $usb
Assert-FixedNonUsbVolume $sandboxEvidenceParentFull 'Sandbox evidence parent'
Assert-NoReparseAncestry $sandboxEvidenceParentFull 'Sandbox evidence parent'
if ((Test-PathWithin $sandboxEvidenceParentFull $source) -or
    (Test-PathWithin $source $sandboxEvidenceParentFull) -or
    (Test-PathWithin $sandboxEvidenceParentFull $usb) -or
    (Test-PathWithin $usb $sandboxEvidenceParentFull) -or
    (Test-PathWithin $sandboxEvidenceParentFull $repositoryRoot) -or
    (Test-PathWithin $repositoryRoot $sandboxEvidenceParentFull)) {
    throw 'Sandbox evidence parent must be separate from the source repository, canonical release, and USB trees.'
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
$sandboxValidation = $null
$sandboxEvidenceRoot = $null

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
        SandboxEvidenceParent = $sandboxEvidenceParentFull
        SandboxEvidencePolicy = 'Execute always creates a new GUID evidence root and launches Windows Sandbox.'
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

if (-not (Confirm-PortableUsbMutation $usb 'Run a fresh Windows Sandbox validation, synchronize the verified compact portable release, and invalidate derived payloads')) {
    return
}

$sandboxEvidenceRoot = New-FreshSandboxEvidenceRoot $sandboxEvidenceParentFull
$sandboxLaunch = Invoke-FreshSandboxValidation $source $manifestFull $sandboxEvidenceRoot $manifestHash
$sandboxResultPath = [string](Get-ValidationProperty $sandboxLaunch 'ResultPath' `
    'Windows Sandbox launcher result')
$sandboxValidation = Assert-SandboxFirstRunValidation $sandboxResultPath $manifestHash `
    $releaseVersion $manifestFull $source $usb $expected

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

    $null = Assert-CanonicalReleaseUnchanged $source $manifestFull $manifestHash $canonicalDirectories `
        $canonicalFiles $expected $sourceHashes 'Canonical release immediately before USB staging'
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
    $null = Assert-CanonicalReleaseUnchanged $source $manifestFull $manifestHash $canonicalDirectories `
        $canonicalFiles $expected $sourceHashes 'Canonical release before USB activation'
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
    $null = Assert-CanonicalReleaseUnchanged $source $manifestFull $manifestHash $canonicalDirectories `
        $canonicalFiles $expected $sourceHashes 'Canonical release after USB synchronization'
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
        SandboxEvidenceParent = $sandboxEvidenceParentFull
        SandboxEvidenceRoot = $sandboxEvidenceRoot
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
