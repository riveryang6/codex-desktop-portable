[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$DotNetPath,
    [string]$FrameworkDirectory,
    [ValidateSet('x86', 'x64', 'arm', 'arm64', 'anycpu', 'anycpu32bitpreferred')]
    [string]$Platform = 'x86',
    [switch]$Bootstrapper
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot 'CodexPortable.new.exe'
}

$sourcePath = Join-Path $PSScriptRoot $(if ($Bootstrapper) { 'CodexPortableBootstrap.cs' } else { 'CodexPortable.cs' })
$iconPath = Join-Path $PSScriptRoot 'codex.ico'
$trayDarkPath = Join-Path $PSScriptRoot 'codex-tray-dark.ico'
$trayLightPath = Join-Path $PSScriptRoot 'codex-tray-light.ico'
$manifestPath = Join-Path $PSScriptRoot 'CodexPortable.manifest'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Launcher source is missing: $sourcePath"
}
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

$compilerInfo = Find-RoslynCompiler -RequestedDotNet $DotNetPath
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $resolvedOutput
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$stagingDirectory = Join-Path $outputDirectory ('.launcher-build-' + [Guid]::NewGuid().ToString('N'))
$stagedOutput = Join-Path $stagingDirectory ([IO.Path]::GetFileName($resolvedOutput))
New-Item -ItemType Directory -Path $stagingDirectory | Out-Null

try {
    $sourceDirectory = (Resolve-Path -LiteralPath $PSScriptRoot).Path
    $arguments = @(
        $compilerInfo.Csc,
        '/nologo',
        '/noconfig',
        '/nostdlib+',
        '/langversion:5',
        '/codepage:65001',
        '/target:winexe',
        "/platform:$Platform",
        '/optimize+',
        '/debug-',
        '/warn:4',
        '/warnaserror+',
        '/deterministic+',
        "/pathmap:$sourceDirectory=/_/src",
        "/out:$stagedOutput",
        "/win32icon:$iconPath",
        "/win32manifest:$manifestPath",
        "/resource:$trayDarkPath,CodexPortable.Branding.TrayDark.ico",
        "/resource:$trayLightPath,CodexPortable.Branding.TrayLight.ico"
    )
    $arguments += $references | ForEach-Object { "/reference:$_" }
    $arguments += $sourcePath

    & $compilerInfo.DotNet @arguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $stagedOutput -PathType Leaf)) {
        throw "Launcher compilation failed with exit code $LASTEXITCODE."
    }

    $version = (Get-Item -LiteralPath $stagedOutput).VersionInfo.FileVersion
    if ($version -ne '1.3.1.0') {
        throw "Unexpected launcher file version: $version"
    }

    Move-Item -LiteralPath $stagedOutput -Destination $resolvedOutput -Force
    $hash = (Get-FileHash -LiteralPath $resolvedOutput -Algorithm SHA256).Hash
    [pscustomobject]@{
        Output = $resolvedOutput
        FileVersion = $version
        SHA256 = $hash
        DotNetSdk = $compilerInfo.SdkVersion
        Compiler = $compilerInfo.Csc
    }
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory -PathType Container) {
        $resolvedStage = (Resolve-Path -LiteralPath $stagingDirectory).Path
        if ([IO.Path]::GetDirectoryName($resolvedStage) -ne [IO.Path]::GetFullPath($outputDirectory).TrimEnd('\')) {
            throw "Refusing to remove an unexpected staging directory: $resolvedStage"
        }
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
}
