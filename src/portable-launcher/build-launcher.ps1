[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$MatrixOutputRoot,
    [string]$DotNetPath,
    [string]$FrameworkDirectory,
    [ValidateSet('x86', 'x64', 'arm', 'arm64', 'anycpu', 'anycpu32bitpreferred')]
    [string]$Platform = 'x86',
    [switch]$Bootstrapper
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [string]::IsNullOrWhiteSpace($MatrixOutputRoot) -and
    ($Bootstrapper -or $PSBoundParameters.ContainsKey('OutputPath') -or
        $PSBoundParameters.ContainsKey('Platform'))) {
    throw 'Matrix builds select all launcher targets and cannot be combined with OutputPath, Platform, or Bootstrapper.'
}

if ([string]::IsNullOrWhiteSpace($MatrixOutputRoot) -and [string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot 'CodexPortable.new.exe'
}

$coreSourcePath = Join-Path $PSScriptRoot 'CodexPortable.cs'
$bootstrapSourcePath = Join-Path $PSScriptRoot 'CodexPortableBootstrap.cs'
$sourcePath = if ($Bootstrapper) { $bootstrapSourcePath } else { $coreSourcePath }
$iconPath = Join-Path $PSScriptRoot 'codex.ico'
$trayDarkPath = Join-Path $PSScriptRoot 'codex-tray-dark.ico'
$trayLightPath = Join-Path $PSScriptRoot 'codex-tray-light.ico'
$manifestPath = Join-Path $PSScriptRoot 'CodexPortable.manifest'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Launcher source is missing: $sourcePath"
}
if (-not (Test-Path -LiteralPath $coreSourcePath -PathType Leaf)) {
    throw "Core launcher source is missing: $coreSourcePath"
}
if (-not [string]::IsNullOrWhiteSpace($MatrixOutputRoot) -and
    -not (Test-Path -LiteralPath $bootstrapSourcePath -PathType Leaf)) {
    throw "Bootstrapper source is missing: $bootstrapSourcePath"
}

function Assert-CanonicalUtf8LfBuildInput {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    try {
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and
            $bytes[2] -eq 0xBF) {
            throw "Launcher text build input must be UTF-8 without a BOM: $Path"
        }
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        try { [void]$strictUtf8.GetString($bytes) }
        catch { throw "Launcher text build input is not strict UTF-8: $Path" }
        if ([Array]::IndexOf($bytes, [byte]0x0D) -ge 0) {
            throw "Launcher text build input must use canonical LF line endings: $Path"
        }
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Assert-CoreProgressUiContract {
    param([Parameter(Mandatory = $true)][string]$CoreSourcePath)

    $source = [IO.File]::ReadAllText($CoreSourcePath, [Text.Encoding]::UTF8)
    $ambiguousChineseLabel = -join @(
        [char]0x6B63
        [char]0x5728
        [char]0x5904
        [char]0x7406
    )
    $ambiguousEnglishLabel = 'Work' + 'ing'
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
    $rules = @(
        [pscustomobject]@{
            Name = 'indeterminate native progress style'
            Pattern = [regex]::Escape(('ProgressBarStyle.' + 'Marquee'))
        }
        [pscustomobject]@{
            Name = 'ambiguous Chinese progress label'
            Pattern = [regex]::Escape($ambiguousChineseLabel)
        }
        [pscustomobject]@{
            Name = 'ambiguous English progress label'
            Pattern = '(?<![A-Za-z])' + [regex]::Escape($ambiguousEnglishLabel) + '(?:\u2026)?(?![A-Za-z])'
        }
    )
    $standaloneStatusRules = @(
        [pscustomobject]@{ Name = 'generic Chinese initialization status'; Text = $genericInitializationChinese }
        [pscustomobject]@{ Name = 'generic English preparation status'; Text = $genericPreparationEnglish }
        [pscustomobject]@{ Name = 'generic Chinese start-preparation status'; Text = $genericStartPreparationChinese }
        [pscustomobject]@{ Name = 'generic English start-preparation status'; Text = $genericPreparationEnglish + ' to start' }
        [pscustomobject]@{ Name = 'generic Chinese first-launch status'; Text = $genericFirstLaunchPreparationChinese }
        [pscustomobject]@{ Name = 'generic English first-launch status'; Text = $genericPreparationEnglish + ' first launch' }
    )
    foreach ($statusRule in $standaloneStatusRules) {
        $rules += [pscustomobject]@{
            Name = $statusRule.Name
            Pattern = '(?<=")' + [regex]::Escape($statusRule.Text) + '(?:\u2026|\.{3})?(?=")'
        }
    }

    foreach ($rule in $rules) {
        $match = [regex]::Match($source, $rule.Pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant -bor
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $line = 1 + ([regex]::Matches($source.Substring(0, $match.Index), "`n")).Count
            throw "Core launcher progress UI violates the determinate-progress contract: $($rule.Name) at line $line."
        }
    }
}

Assert-CoreProgressUiContract -CoreSourcePath $coreSourcePath

function Assert-CoreExecutionImageContract {
    param([Parameter(Mandatory = $true)][string]$CoreSourcePath)

    $source = [IO.File]::ReadAllText($CoreSourcePath, [Text.Encoding]::UTF8)
    $required = @(
        'HostExecutionImage.EnsureReady(layout, false,'
        'A verified local execution image is required.'
        'execution=local-image'
        'CODEX_PORTABLE_ROOT'
        'OfficialPortableUserDataResolverText'
        'VerifyExecutionImagePackages(layout, progress)'
        'string family = GetFamilyRoot(layout);'
        'execution.FamilyRoot'
        'GetPreparationMutexNameForFamily(family)'
        'HasPendingInvalidation(family, root)'
    )
    foreach ($text in $required) {
        if ($source.IndexOf($text, [StringComparison]::Ordinal) -lt 0) {
            throw "Core launcher is missing the mandatory local execution-image contract: $text"
        }
    }
    $forbidden = @(
        'execution == null ? layout.AppExe'
        'execution == null ? layout.CurrentApp'
        'execution == null ? "usb" : "local-image"'
        'GetExecutionImageDesktopVersion(layout)'
    )
    foreach ($text in $forbidden) {
        if ($source.IndexOf($text, [StringComparison]::Ordinal) -ge 0) {
            throw "Core launcher still permits direct USB desktop execution: $text"
        }
    }
}

Assert-CoreExecutionImageContract -CoreSourcePath $coreSourcePath

function Assert-CoreRecoveryContract {
    param([Parameter(Mandatory = $true)][string]$CoreSourcePath)

    $source = [IO.File]::ReadAllText($CoreSourcePath, [Text.Encoding]::UTF8)
    $required = @(
        'TerminateProcessTreeAndWait'
        'QueryInformationJobObject'
        'RevalidatePluginCacheAfterDesktopImageFailure'
        'ProcessTreeTerminationTimeoutMilliseconds'
        'SelfTestRecoveryContract'
        'SelfTestRecoveryContractExitCode'
        'if (recoverySelfTest != 0) return recoverySelfTest;'
        'imageRecoveryAttempted'
        'DesktopImageFailureWatch'
        'PrepareHelper(layout)'
        'TryInvalidateExecutionImage'
        '--desktop-image-failure-watch'
        'TryNormalizeRecoveryTarget'
        'TryNormalizeRecoveryInvalidationEntry'
        'IsAnyExecutableRunningUnderRoot'
        'DesktopHandoffWasCancelled'
        'lateFailureWatch.IsTargetAlive()'
        'ScratchProductDirectory = "LFPortable"'
        'ScratchDirectory = "scratch"'
        'EnsureFixedDirectoryChain'
        'EnsureRegularFixedDirectory'
        'ValidateRecoveryHelperPath'
        'WaitHandle.WaitAny(new WaitHandle[] { armed, failed },'
        'armedEvent.Set();'
        'committingWatch.Commit()'
    )
    foreach ($text in $required) {
        if ($source.IndexOf($text, [StringComparison]::Ordinal) -lt 0) {
            throw "Core launcher is missing the mandatory desktop self-repair contract: $text"
        }
    }

    $retryDeclaration = [regex]::Matches($source,
        'bool\s+imageRecoveryAttempted\s*=\s*false\s*;',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($retryDeclaration.Count -ne 1 -or
        $source -notmatch 'imageRecoveryAttempted\s*=\s*true' -or
        $source -notmatch 'imageRecoveryAttempted\s*\)') {
        throw 'Core launcher must guard desktop image recovery with one per-launch retry flag.'
    }

    $singleLine = [Text.RegularExpressions.RegexOptions]::CultureInvariant -bor
        [Text.RegularExpressions.RegexOptions]::Singleline
    $scratchLayout = [regex]::Matches($source,
        'p\.HostScratchRoot\s*=\s*Path\.Combine\(\s*hostLocalAppData,\s*"LFPortable",\s*"scratch",\s*"session-"\s*\+',
        $singleLine)
    if ($scratchLayout.Count -ne 1) {
        throw 'Core launcher must place each scratch session below LOCALAPPDATA\LFPortable\scratch.'
    }

    $baseRootMatch = [regex]::Match($source,
        'private\s+static\s+string\s+GetValidatedBaseRoot\s*\([^)]*\)\s*\{(?<body>.*?)(?=\s*private\s+static\s+string\s+ValidateSessionRoot\s*\()',
        $singleLine)
    if (-not $baseRootMatch.Success) {
        throw 'Core launcher is missing the fixed local scratch-base validator.'
    }
    foreach ($pattern in @(
            'Path\.Combine\(hostLocalAppData,\s*ScratchProductDirectory,\s*ScratchDirectory\)',
            'string\.Equals\(expectedBase,\s*configuredBase,\s*StringComparison\.OrdinalIgnoreCase\)',
            'IsSameOrDescendant\(scratch,\s*portableRoot\)',
            'EnsureFixedDirectoryChain\(expectedBase,\s*create\)'
        )) {
        if (-not [regex]::IsMatch($baseRootMatch.Groups['body'].Value, $pattern, $singleLine)) {
            throw 'Core launcher fixed local scratch-base validator is incomplete.'
        }
    }

    $fixedChainMatch = [regex]::Match($source,
        'private\s+static\s+void\s+EnsureFixedDirectoryChain\s*\([^)]*\)\s*\{(?<body>.*?)(?=\s*private\s+static\s+void\s+EnsureRegularFixedDirectory\s*\()',
        $singleLine)
    if (-not $fixedChainMatch.Success) {
        throw 'Core launcher is missing the fixed-volume scratch-chain validator.'
    }
    foreach ($pattern in @(
            'DriveInfo\s+drive\s*=\s*new\s+DriveInfo\(volumeRoot\)',
            'drive\.DriveType\s*!=\s*DriveType\.Fixed',
            'EnsureRegularFixedDirectory\(root,\s*false\)',
            'for\s*\(\s*int\s+i\s*=\s*0;\s*i\s*<\s*segments\.Length;',
            'EnsureRegularFixedDirectory\(current,\s*create\)',
            'if\s*\(create\)\s*EnsureFixedDirectoryChain\(target,\s*false\)'
        )) {
        if (-not [regex]::IsMatch($fixedChainMatch.Groups['body'].Value, $pattern, $singleLine)) {
            throw 'Core launcher must verify every local scratch ancestor on a fixed, non-reparse chain.'
        }
    }
    $fixedDirectoryMatch = [regex]::Match($source,
        'private\s+static\s+void\s+EnsureRegularFixedDirectory\s*\([^)]*\)\s*\{(?<body>.*?)(?=\s*private\s+static\s+string\s+NormalizeDirectoryPath\s*\()',
        $singleLine)
    if (-not $fixedDirectoryMatch.Success -or
        -not [regex]::IsMatch($fixedDirectoryMatch.Groups['body'].Value,
            'NativeMethods\.GetFileAttributes\(path\)', $singleLine) -or
        -not [regex]::IsMatch($fixedDirectoryMatch.Groups['body'].Value,
            'Directory\.CreateDirectory\(path\)', $singleLine) -or
        -not [regex]::IsMatch($fixedDirectoryMatch.Groups['body'].Value,
            '\(directoryAttributes\s*&\s*FileAttributes\.Directory\)\s*==\s*0', $singleLine) -or
        -not [regex]::IsMatch($fixedDirectoryMatch.Groups['body'].Value,
            '\(directoryAttributes\s*&\s*FileAttributes\.ReparsePoint\)\s*!=\s*0', $singleLine)) {
        throw 'Core launcher scratch-directory validator must reject non-directories and reparse points.'
    }

    $helperPathMatch = [regex]::Match($source,
        'internal\s+static\s+string\s+ValidateRecoveryHelperPath\s*\([^)]*\)\s*\{(?<body>.*?)(?=\s*private\s+static\s+string\s+GetVerifiedSessionRoot\s*\()',
        $singleLine)
    if (-not $helperPathMatch.Success) {
        throw 'Core launcher is missing the recovery-helper path validator.'
    }
    foreach ($pattern in @(
            'GetVerifiedSessionRoot\(layout\)',
            'NormalizeDirectoryPath\(helperParent\)',
            'RecoveryHelperPrefix',
            'NativeMethods\.GetFileAttributes\(helperFull\)',
            'FileAttributes\.Directory',
            'FileAttributes\.ReparsePoint'
        )) {
        if (-not [regex]::IsMatch($helperPathMatch.Groups['body'].Value, $pattern, $singleLine)) {
            throw 'Core launcher recovery-helper path validator is incomplete.'
        }
    }
    $prepareHelperMatch = [regex]::Match($source,
        'internal\s+static\s+string\s+PrepareHelper\s*\([^)]*\)\s*\{(?<body>.*?)(?=\s*internal\s+static\s+DesktopImageFailureWatch\s+Start\s*\()',
        $singleLine)
    if (-not $prepareHelperMatch.Success) {
        throw 'Core launcher is missing recovery-helper preparation.'
    }
    $prepareHelperBody = $prepareHelperMatch.Groups['body'].Value
    $validateBeforeCopy = $prepareHelperBody.IndexOf(
        'helper = PortableScratch.ValidateRecoveryHelperPath(layout, helper, false);',
        [StringComparison]::Ordinal)
    $copyHelper = $prepareHelperBody.IndexOf('CopyHelperVerified(source, helper);',
        [StringComparison]::Ordinal)
    $validateAfterCopy = $prepareHelperBody.IndexOf(
        'return PortableScratch.ValidateRecoveryHelperPath(layout, helper, true);',
        [StringComparison]::Ordinal)
    if ($validateBeforeCopy -lt 0 -or $copyHelper -lt 0 -or $validateAfterCopy -lt 0 -or
        $validateBeforeCopy -ge $copyHelper -or $copyHelper -ge $validateAfterCopy) {
        throw 'Core launcher must validate the fixed local recovery-helper path before and after its verified copy.'
    }

    $commitMatch = [regex]::Match($source,
        'internal\s+void\s+Commit\s*\(\s*\)\s*\{(?<body>.*?)(?=\s*internal\s+void\s+WaitForCompletionAfterTargetExit\s*\()',
        $singleLine)
    if (-not $commitMatch.Success) {
        throw 'Core launcher is missing the recovery-helper armed-acknowledgement contract.'
    }
    $commitBody = $commitMatch.Groups['body'].Value
    $setCommit = $commitBody.IndexOf('commit.Set();', [StringComparison]::Ordinal)
    $waitArmed = $commitBody.IndexOf('WaitHandle.WaitAny(new WaitHandle[] { armed, failed },',
        [StringComparison]::Ordinal)
    $markCommitted = $commitBody.IndexOf('committed = true;', [StringComparison]::Ordinal)
    if ($setCommit -lt 0 -or $waitArmed -lt 0 -or $markCommitted -lt 0 -or
        $setCommit -ge $waitArmed -or $waitArmed -ge $markCommitted) {
        throw 'Core launcher must wait for the recovery-helper armed acknowledgement before committing handoff.'
    }
    $watchRunMatch = [regex]::Match($source,
        'internal\s+static\s+int\s+Run\s*\(\s*string\[\]\s+args\s*\)\s*\{(?<body>.*?)(?=\s*public\s+void\s+Dispose\s*\()',
        $singleLine)
    if (-not $watchRunMatch.Success) {
        throw 'Core launcher is missing the recovery-helper watcher loop.'
    }
    $watchRunBody = $watchRunMatch.Groups['body'].Value
    $armedSignal = $watchRunBody.IndexOf('armedEvent.Set();', [StringComparison]::Ordinal)
    $waitForTargetExit = $watchRunBody.IndexOf('target.WaitForExit();', [StringComparison]::Ordinal)
    if ($armedSignal -lt 0 -or $waitForTargetExit -lt 0 -or $armedSignal -ge $waitForTargetExit) {
        throw 'Core launcher recovery helper must signal armed before it releases startup ownership.'
    }
    $commitAt = $source.IndexOf('await Task.Run(delegate { committingWatch.Commit(); });',
        [StringComparison]::Ordinal)
    $detachAt = $source.IndexOf('exitedDuringStartup = !run.TryDetachAfterStartup(out earlyExitCode);',
        [StringComparison]::Ordinal)
    if ($commitAt -lt 0 -or $detachAt -lt 0 -or $commitAt -ge $detachAt) {
        throw 'Core launcher must receive the recovery-helper armed acknowledgement before detaching Codex.'
    }

    $createFailureMatch = [regex]::Match($source,
        'if\s*\(\s*processCreateFailure\s*!=\s*null\s*\)\s*\{(?<body>.*?)(?=\s*SafeLog\.TryWriteEvent\(layout,\s*"start-attempt")',
        $singleLine)
    if (-not $createFailureMatch.Success) {
        throw 'Core launcher is missing the desktop process-creation recovery path.'
    }
    $createFailureBody = $createFailureMatch.Groups['body'].Value
    $createFailureRevalidate = $createFailureBody.IndexOf(
        'await RevalidatePluginCacheAfterDesktopImageFailure();', [StringComparison]::Ordinal)
    $createFailurePlan = $createFailureBody.IndexOf('BeginDesktopImageRecoveryProgressPlan();',
        [StringComparison]::Ordinal)
    $createFailureRebuild = $createFailureBody.IndexOf(
        'HostExecutionImage.EnsureReady(layout, true,', [StringComparison]::Ordinal)
    if ($createFailureRevalidate -lt 0 -or $createFailurePlan -lt 0 -or $createFailureRebuild -lt 0 -or
        $createFailureRevalidate -ge $createFailurePlan -or $createFailurePlan -ge $createFailureRebuild) {
        throw 'Core launcher must revalidate the plugin cache before rebuilding after a CreateProcess failure.'
    }
}

Assert-CoreRecoveryContract -CoreSourcePath $coreSourcePath

function Assert-CoreModelContract {
    param([Parameter(Mandatory = $true)][string]$CoreSourcePath)

    $source = [IO.File]::ReadAllText($CoreSourcePath, [Text.Encoding]::UTF8)
    $matches = @([regex]::Matches($source,
        'internal\s+const\s+string\s+DefaultModel\s*=\s*"(?<model>[^"]+)"\s*;'))
    if ($matches.Count -ne 1 -or $matches[0].Groups['model'].Value -cne 'gpt-5.6-terra') {
        throw 'Core launcher must declare gpt-5.6-terra as its default model.'
    }
    if ($source -match '"gpt-5\.6-sol"' -or
        $source -notmatch 'CurrentModelUpgrade\s*=\s*ProviderConfiguration\.DefaultModel\s*;') {
        throw 'Core launcher model onboarding state must use the declared default model.'
    }
}

Assert-CoreModelContract -CoreSourcePath $coreSourcePath

if ($Bootstrapper -and $Platform -ne 'x86') {
    throw 'The architecture bootstrapper must be built as x86 so it can run on x86, x64, and Windows ARM emulation.'
}
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    throw "Launcher icon is missing: $iconPath"
}
foreach ($brandingIcon in @($trayDarkPath, $trayLightPath)) {
    if (-not (Test-Path -LiteralPath $brandingIcon -PathType Leaf)) {
        throw "Portable branding icon is missing: $brandingIcon"
    }
    $header = [IO.File]::ReadAllBytes($brandingIcon)
    if ($header.Length -lt 1024 -or $header[0] -ne 0 -or $header[1] -ne 0 -or $header[2] -ne 1 -or $header[3] -ne 0) {
        throw "Portable branding icon is not a valid ICO: $brandingIcon"
    }
}
if ((Get-FileHash -LiteralPath $trayDarkPath -Algorithm SHA256).Hash -eq
    (Get-FileHash -LiteralPath $trayLightPath -Algorithm SHA256).Hash) {
    throw 'Dark and light portable tray icons must be distinct.'
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Launcher manifest is missing: $manifestPath"
}

$manifestXml = New-Object System.Xml.XmlDocument
$manifestXml.PreserveWhitespace = $true
$manifestXml.Load($manifestPath)
$requestedLevels = $manifestXml.SelectNodes("//*[local-name()='requestedExecutionLevel']")
if ($null -eq $requestedLevels -or $requestedLevels.Count -ne 1 -or
    $requestedLevels[0].GetAttribute('level') -ne 'asInvoker' -or
    $requestedLevels[0].GetAttribute('uiAccess') -ne 'false') {
    throw 'Launcher manifest must contain exactly one asInvoker requestedExecutionLevel with uiAccess=false.'
}
foreach ($textInput in @($coreSourcePath, $bootstrapSourcePath, $manifestPath)) {
    Assert-CanonicalUtf8LfBuildInput -Path $textInput
}

function Find-RoslynCompiler {
    param([string]$RequestedDotNet)

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($RequestedDotNet)) {
        $candidates.Add($RequestedDotNet)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_PORTABLE_BUILD_DOTNET)) {
        $candidates.Add($env:CODEX_PORTABLE_BUILD_DOTNET)
    }

    $pathDotNet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($null -ne $pathDotNet) {
        $candidates.Add($pathDotNet.Source)
    }

    $candidates.Add((Join-Path $PSScriptRoot '..\package\CodexData\tools\dotnet\dotnet.exe'))

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $resolvedDotNet = (Resolve-Path -LiteralPath $candidate).Path
        $sdkRoot = Join-Path (Split-Path -Parent $resolvedDotNet) 'sdk'
        if (-not (Test-Path -LiteralPath $sdkRoot -PathType Container)) {
            continue
        }

        $compiler = Get-ChildItem -LiteralPath $sdkRoot -Directory |
            ForEach-Object {
                $version = $null
                if ([Version]::TryParse($_.Name, [ref]$version)) {
                    [pscustomobject]@{
                        Version = $version
                        Path = Join-Path $_.FullName 'Roslyn\bincore\csc.dll'
                    }
                }
            } |
            Where-Object { Test-Path -LiteralPath $_.Path -PathType Leaf } |
            Sort-Object Version -Descending |
            Select-Object -First 1

        if ($null -ne $compiler) {
            return [pscustomobject]@{
                DotNet = $resolvedDotNet
                Csc = $compiler.Path
                SdkVersion = $compiler.Version.ToString()
            }
        }
    }

    throw 'A .NET SDK with Roslyn csc.dll was not found. Pass -DotNetPath or set CODEX_PORTABLE_BUILD_DOTNET.'
}

if ([string]::IsNullOrWhiteSpace($FrameworkDirectory)) {
    $frameworkCandidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $frameworkCandidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8'))
    }
    $frameworkCandidates.Add((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'))
    $frameworkCandidates.Add((Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'))
    $FrameworkDirectory = $frameworkCandidates |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'mscorlib.dll') -PathType Leaf } |
        Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($FrameworkDirectory)) {
    throw '.NET Framework 4.x reference assemblies were not found.'
}
$FrameworkDirectory = (Resolve-Path -LiteralPath $FrameworkDirectory).Path

$referenceNames = @(
    'mscorlib.dll',
    'System.dll',
    'System.Core.dll',
    'System.Drawing.dll',
    'System.IO.Compression.dll',
    'System.Web.Extensions.dll',
    'System.Windows.Forms.dll',
    'System.Xml.dll'
)
$references = foreach ($name in $referenceNames) {
    $path = Join-Path $FrameworkDirectory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required .NET Framework assembly is missing: $path"
    }
    $path
}

$compatibilityGate = Join-Path $PSScriptRoot 'Assert-OfficialCodexCompatibility.ps1'
if (-not (Test-Path -LiteralPath $compatibilityGate -PathType Leaf)) {
    throw "Official Codex compatibility gate is missing: $compatibilityGate"
}

$buildInputPaths = @(
    $coreSourcePath,
    $iconPath,
    $trayDarkPath,
    $trayLightPath,
    $manifestPath
)
if ($Bootstrapper -or -not [string]::IsNullOrWhiteSpace($MatrixOutputRoot)) {
    $buildInputPaths += $bootstrapSourcePath
}
$buildInputHashes = [ordered]@{}
foreach ($inputPath in $buildInputPaths) {
    $inputItem = Get-Item -LiteralPath $inputPath -Force -ErrorAction Stop
    if (($inputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $inputItem.PSIsContainer) {
        throw "Launcher build input must be a regular file: $inputPath"
    }
    $buildInputHashes[$inputItem.FullName] = (Get-FileHash -LiteralPath $inputItem.FullName -Algorithm SHA256).Hash
}

function Assert-BuildInputsUnchanged {
    foreach ($entry in $buildInputHashes.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Key -PathType Leaf)) {
            throw "Launcher build input changed or disappeared during this transaction: $($entry.Key)"
        }
        $inputItem = Get-Item -LiteralPath $entry.Key -Force -ErrorAction Stop
        $currentHash = [string](Get-FileHash -LiteralPath $entry.Key -Algorithm SHA256).Hash
        if (($inputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $inputItem.PSIsContainer -or
            -not $currentHash.Equals([string]$entry.Value, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Launcher build input changed during this transaction: $($entry.Key)"
        }
    }
}

# This live check runs before the first Roslyn invocation. A freshly compiled
# x64 probe is then tested against both packages before any requested output is
# promoted from the transaction directory.
$officialPreflight = @(& $compatibilityGate)
if ($officialPreflight.Count -ne 1 -or
    [string]::IsNullOrWhiteSpace([string]$officialPreflight[0].Version)) {
    throw 'Official Codex compatibility preflight returned an invalid result.'
}

$compilerInfo = Find-RoslynCompiler -RequestedDotNet $DotNetPath
$targets = New-Object System.Collections.Generic.List[object]
$resolvedMatrixOutput = $null
if (-not [string]::IsNullOrWhiteSpace($MatrixOutputRoot)) {
    $resolvedMatrixOutput = [IO.Path]::GetFullPath($MatrixOutputRoot).TrimEnd('\')
    $matrixRoot = [IO.Path]::GetPathRoot($resolvedMatrixOutput).TrimEnd('\')
    if ($resolvedMatrixOutput.Equals($matrixRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Matrix output cannot be a filesystem root.'
    }
    $variantDirectory = Join-Path $resolvedMatrixOutput 'CodexData\tools\launchers'
    $targets.Add([pscustomobject]@{
        Name = 'x64 launcher core'
        Platform = 'x64'
        Source = $coreSourcePath
        Output = Join-Path $variantDirectory 'CodexPortable.x64.exe'
    })
    $targets.Add([pscustomobject]@{
        Name = 'x86 launcher core'
        Platform = 'x86'
        Source = $coreSourcePath
        Output = Join-Path $variantDirectory 'CodexPortable.x86.exe'
    })
    $targets.Add([pscustomobject]@{
        Name = 'ARM64 launcher core'
        Platform = 'arm64'
        Source = $coreSourcePath
        Output = Join-Path $variantDirectory 'CodexPortable.arm64.exe'
    })
    $targets.Add([pscustomobject]@{
        Name = 'x86 architecture bootstrapper'
        Platform = 'x86'
        Source = $bootstrapSourcePath
        Output = Join-Path $resolvedMatrixOutput 'CodexPortable.exe'
    })
    $stagingParent = Split-Path -Parent $resolvedMatrixOutput
}
else {
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    $targets.Add([pscustomobject]@{
        Name = if ($Bootstrapper) { 'x86 architecture bootstrapper' } else { "$Platform launcher core" }
        Platform = $Platform
        Source = $sourcePath
        Output = $resolvedOutput
    })
    $stagingParent = Split-Path -Parent $resolvedOutput
}

if (-not (Test-Path -LiteralPath $stagingParent -PathType Container)) {
    New-Item -ItemType Directory -Path $stagingParent -Force | Out-Null
}
$stagingParent = [IO.Path]::GetFullPath($stagingParent).TrimEnd('\')
$stagingDirectory = Join-Path $stagingParent ('.launcher-build-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDirectory | Out-Null

for ([int]$targetIndex = 0; $targetIndex -lt $targets.Count; $targetIndex++) {
    $target = $targets[$targetIndex]
    $stageName = if ($null -ne $resolvedMatrixOutput) {
        if ($target.Name -eq 'x86 architecture bootstrapper') {
            'CodexPortable.exe'
        }
        else {
            "CodexData\tools\launchers\CodexPortable.$($target.Platform).exe"
        }
    }
    else {
        if ($target.Name -eq 'x86 architecture bootstrapper') {
            'CodexPortable.exe'
        }
        else {
            "CodexPortable.$($target.Platform).exe"
        }
    }
    $target | Add-Member -NotePropertyName StagedOutput -NotePropertyValue (
        Join-Path $stagingDirectory $stageName)
}

function Invoke-LauncherCompile([object]$Target) {
    Assert-BuildInputsUnchanged
    $stageOutputDirectory = Split-Path -Parent ([string]$Target.StagedOutput)
    if (-not (Test-Path -LiteralPath $stageOutputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $stageOutputDirectory -Force | Out-Null
    }
    $sourceDirectory = (Resolve-Path -LiteralPath $PSScriptRoot).Path
    $arguments = @(
        $compilerInfo.Csc,
        '/nologo',
        '/noconfig',
        '/nostdlib+',
        '/langversion:5',
        '/codepage:65001',
        '/target:winexe',
        "/platform:$($Target.Platform)",
        '/optimize+',
        '/debug-',
        '/warn:4',
        '/warnaserror+',
        '/deterministic+',
        "/pathmap:$sourceDirectory=/_/src",
        "/out:$($Target.StagedOutput)",
        "/win32icon:$iconPath",
        "/win32manifest:$manifestPath",
        "/resource:$trayDarkPath,CodexPortable.Branding.TrayDark.ico",
        "/resource:$trayLightPath,CodexPortable.Branding.TrayLight.ico"
    )
    $arguments += $references | ForEach-Object { "/reference:$_" }
    $arguments += [string]$Target.Source

    $compilerOutput = @(& $compilerInfo.DotNet @arguments 2>&1)
    $compilerExitCode = $LASTEXITCODE
    if ($compilerExitCode -ne 0 -or
        -not (Test-Path -LiteralPath $Target.StagedOutput -PathType Leaf)) {
        $compilerDiagnostic = ($compilerOutput | ForEach-Object { [string]$_ }) -join
            [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($compilerDiagnostic)) {
            throw "$($Target.Name) compilation failed with exit code $compilerExitCode."
        }
        throw "$($Target.Name) compilation failed with exit code $compilerExitCode.$([Environment]::NewLine)$compilerDiagnostic"
    }
    $version = [string](Get-Item -LiteralPath $Target.StagedOutput).VersionInfo.FileVersion
    if ($version -ne '1.4.19.0') {
        throw "Unexpected $($Target.Name) file version: $version"
    }
    $expectedMachines = @{
        x86 = 0x014c
        x64 = 0x8664
        arm = 0x01c4
        arm64 = 0xAA64
        anycpu = 0x014c
        anycpu32bitpreferred = 0x014c
    }
    $stream = [IO.File]::Open($Target.StagedOutput, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 256 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw "Compiled $($Target.Name) has no valid MZ header."
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 6)) {
            throw "Compiled $($Target.Name) has an invalid PE offset."
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Compiled $($Target.Name) has no PE signature."
        }
        $machine = $reader.ReadUInt16()
        $expectedMachine = [uint16]$expectedMachines[[string]$Target.Platform]
        if ($machine -ne $expectedMachine) {
            throw ("Compiled {0} has PE machine 0x{1:X4}; expected 0x{2:X4}." -f
                $Target.Name, $machine, $expectedMachine)
        }
    }
    finally { $reader.Dispose() }
    Assert-BuildInputsUnchanged
    return $version
}

function Assert-ReplaceableMatrixOutput([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Matrix output exists but is not a directory: $Root"
    }
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Matrix output cannot be a reparse point: $Root"
    }
    $rootEntries = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)
    if ($rootEntries.Count -eq 0) { return }
    $expectedRootEntries = @('CodexData', 'CodexPortable.exe')
    if (Compare-Object -ReferenceObject $expectedRootEntries `
            -DifferenceObject @($rootEntries.Name | Sort-Object)) {
        throw "Matrix output has unexpected root entries: $($rootEntries.Name -join ', ')"
    }

    $expectedDirectories = @(
        [pscustomobject]@{ Path = Join-Path $Root 'CodexData'; Entries = @('tools') },
        [pscustomobject]@{ Path = Join-Path $Root 'CodexData\tools'; Entries = @('launchers') },
        [pscustomobject]@{
            Path = Join-Path $Root 'CodexData\tools\launchers'
            Entries = @('CodexPortable.arm64.exe', 'CodexPortable.x64.exe', 'CodexPortable.x86.exe')
        }
    )
    foreach ($directory in $expectedDirectories) {
        if (-not (Test-Path -LiteralPath $directory.Path -PathType Container)) {
            throw "Matrix output directory is missing: $($directory.Path)"
        }
        $directoryItem = Get-Item -LiteralPath $directory.Path -Force -ErrorAction Stop
        if (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Matrix output directory cannot be a reparse point: $($directory.Path)"
        }
        $entries = @(Get-ChildItem -LiteralPath $directory.Path -Force -ErrorAction Stop)
        if (Compare-Object -ReferenceObject @($directory.Entries | Sort-Object) `
                -DifferenceObject @($entries.Name | Sort-Object)) {
            throw "Matrix output has unexpected entries under $($directory.Path): $($entries.Name -join ', ')"
        }
    }
    foreach ($launcher in @(
            (Join-Path $Root 'CodexPortable.exe'),
            (Join-Path $Root 'CodexData\tools\launchers\CodexPortable.x86.exe'),
            (Join-Path $Root 'CodexData\tools\launchers\CodexPortable.x64.exe'),
            (Join-Path $Root 'CodexData\tools\launchers\CodexPortable.arm64.exe'))) {
        if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
            throw "Matrix output launcher is missing: $launcher"
        }
        $launcherItem = Get-Item -LiteralPath $launcher -Force -ErrorAction Stop
        if (($launcherItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Matrix output launcher cannot be a reparse point: $launcher"
        }
    }
}

function Publish-LauncherMatrix([string]$CandidateRoot, [string]$DestinationRoot) {
    Assert-ReplaceableMatrixOutput $DestinationRoot
    $parent = [IO.Path]::GetDirectoryName($DestinationRoot)
    $backup = Join-Path $parent ('.launcher-previous-' + [Guid]::NewGuid().ToString('N'))
    $oldMoved = $false
    $newMoved = $false
    try {
        if (Test-Path -LiteralPath $DestinationRoot -PathType Container) {
            Move-Item -LiteralPath $DestinationRoot -Destination $backup
            $oldMoved = $true
        }
        Move-Item -LiteralPath $CandidateRoot -Destination $DestinationRoot
        $newMoved = $true
        if ($oldMoved) {
            Remove-Item -LiteralPath $backup -Recurse -Force
            $oldMoved = $false
        }
    }
    catch {
        $publicationError = $_
        try {
            if ($newMoved -and (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
                Move-Item -LiteralPath $DestinationRoot -Destination $CandidateRoot
                $newMoved = $false
            }
            if ($oldMoved -and (Test-Path -LiteralPath $backup -PathType Container)) {
                Move-Item -LiteralPath $backup -Destination $DestinationRoot
                $oldMoved = $false
            }
        }
        catch {
            throw "Launcher matrix publication failed and rollback also failed. Previous matrix backup: $backup. Publication error: $($publicationError.Exception.Message). Rollback error: $($_.Exception.Message)"
        }
        throw $publicationError
    }
}

try {
    # The first live official check must complete before any compiler process
    # starts. It establishes the exact x64/ARM64 package snapshot that the
    # single compatibility probe is allowed to test.
    $officialPreflight = @(& $compatibilityGate)
    if ($officialPreflight.Count -ne 1 -or
        [string]$officialPreflight[0].LauncherSelfTest -ne 'NotRequested') {
        throw 'Official Codex compatibility preflight did not complete before compilation.'
    }

    $compatibilityTarget = @($targets | Where-Object {
        $_.Platform -eq 'x64' -and $_.Source -eq $coreSourcePath
    } | Select-Object -First 1)
    if ($compatibilityTarget.Count -eq 1) {
        $probe = $compatibilityTarget[0]
    }
    else {
        $probe = [pscustomobject]@{
            Name = 'x64 compatibility probe'
            Platform = 'x64'
            Source = $coreSourcePath
            Output = $null
            StagedOutput = Join-Path $stagingDirectory 'CodexPortable.compatibility.x64.exe'
        }
    }

    [void](Invoke-LauncherCompile $probe)
    $officialCompatibility = @(& $compatibilityGate `
        -ReferenceLauncherPath $probe.StagedOutput `
        -RunLauncherSelfTest)
    if ($officialCompatibility.Count -ne 1 -or
        [string]$officialCompatibility[0].LauncherSelfTest -ne 'Passed') {
        throw 'Official Codex x64/ARM64 launcher compatibility self-test did not pass.'
    }
    foreach ($property in @('Version', 'X64Path', 'X64SHA256', 'X64Length', 'X64ETag',
            'Arm64Path', 'Arm64SHA256', 'Arm64Length', 'Arm64ETag')) {
        $before = [string]$officialPreflight[0].PSObject.Properties[$property].Value
        $after = [string]$officialCompatibility[0].PSObject.Properties[$property].Value
        $comparison = if ($property.EndsWith('Path', [StringComparison]::Ordinal) -or
            $property.EndsWith('SHA256', [StringComparison]::Ordinal)) {
            [StringComparison]::OrdinalIgnoreCase
        }
        else { [StringComparison]::Ordinal }
        if (-not $before.Equals($after, $comparison)) {
            throw "Official Codex package snapshot changed between preflight and compatibility self-test: $property"
        }
    }

    foreach ($target in $targets) {
        if (-not [string]::Equals([string]$target.StagedOutput,
                [string]$probe.StagedOutput, [StringComparison]::OrdinalIgnoreCase)) {
            [void](Invoke-LauncherCompile $target)
        }
    }

    $officialBeforePromotion = @(& $compatibilityGate)
    if ($officialBeforePromotion.Count -ne 1 -or
        -not ([string]$officialBeforePromotion[0].Version).Equals(
            [string]$officialCompatibility[0].Version, [StringComparison]::Ordinal) -or
        -not ([string]$officialBeforePromotion[0].X64SHA256).Equals(
            [string]$officialCompatibility[0].X64SHA256, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$officialBeforePromotion[0].Arm64SHA256).Equals(
            [string]$officialCompatibility[0].Arm64SHA256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Official Codex packages changed after the compatibility self-test; restart the build against the new packages.'
    }
    Assert-BuildInputsUnchanged

    if ($null -ne $resolvedMatrixOutput) {
        Publish-LauncherMatrix $stagingDirectory $resolvedMatrixOutput
    }
    else {
        foreach ($target in $targets) {
            $outputDirectory = Split-Path -Parent ([string]$target.Output)
            if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
            }
            Move-Item -LiteralPath $target.StagedOutput -Destination $target.Output -Force
        }
    }

    if ($null -ne $resolvedMatrixOutput) {
        [pscustomobject]@{
            OutputRoot = $resolvedMatrixOutput
            Bootstrap = Join-Path $resolvedMatrixOutput 'CodexPortable.exe'
            VariantDirectory = Join-Path $resolvedMatrixOutput 'CodexData\tools\launchers'
            BuildCount = $targets.Count
            Architectures = 'x86,x64,arm64'
            FileVersion = '1.4.19.0'
            DotNetSdk = $compilerInfo.SdkVersion
            DotNetPath = $compilerInfo.DotNet
            Compiler = $compilerInfo.Csc
            FrameworkDirectory = $FrameworkDirectory
            ProgressUiContract = 'Passed'
            OfficialCodexVersion = [string]$officialCompatibility[0].Version
            OfficialPackageSelfTest = 'x64-msix+arm64-msix:passed'
        }
    }
    else {
        $builtTarget = $targets[0]
        [pscustomobject]@{
            Output = [string]$builtTarget.Output
            FileVersion = [string](Get-Item -LiteralPath $builtTarget.Output).VersionInfo.FileVersion
            SHA256 = (Get-FileHash -LiteralPath $builtTarget.Output -Algorithm SHA256).Hash
            DotNetSdk = $compilerInfo.SdkVersion
            DotNetPath = $compilerInfo.DotNet
            Compiler = $compilerInfo.Csc
            FrameworkDirectory = $FrameworkDirectory
            ProgressUiContract = 'Passed'
            OfficialCodexVersion = [string]$officialCompatibility[0].Version
            OfficialPackageSelfTest = 'x64-msix+arm64-msix:passed'
        }
    }
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory -PathType Container) {
        $resolvedStage = (Resolve-Path -LiteralPath $stagingDirectory).Path
        if ([IO.Path]::GetDirectoryName($resolvedStage) -ne $stagingParent) {
            throw "Refusing to remove an unexpected staging directory: $resolvedStage"
        }
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
}
