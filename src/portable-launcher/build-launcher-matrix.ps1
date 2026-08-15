[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'matrix-output'),
    [string]$DotNetPath,
    [string]$FrameworkDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$builder = Join-Path $PSScriptRoot 'build-launcher.ps1'
if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) {
    throw "Launcher builder is missing: $builder"
}
$resolvedOutput = [IO.Path]::GetFullPath($OutputRoot)
$launcherDirectory = Join-Path $resolvedOutput 'CodexData\tools\launchers'

$buildArguments = @{ MatrixOutputRoot = $resolvedOutput }
if (-not [string]::IsNullOrWhiteSpace($DotNetPath)) { $buildArguments.DotNetPath = $DotNetPath }
if (-not [string]::IsNullOrWhiteSpace($FrameworkDirectory)) { $buildArguments.FrameworkDirectory = $FrameworkDirectory }

$buildResult = & $builder @buildArguments
$bootstrap = Join-Path $resolvedOutput 'CodexPortable.exe'
if ($null -eq $buildResult -or [int]$buildResult.BuildCount -ne 4 -or
    [string]$buildResult.OfficialPackageSelfTest -ne 'x64-msix+arm64-msix:passed') {
    throw 'Launcher matrix builder did not return a complete compatibility-gated result.'
}

$expectedMachines = @{
    'CodexPortable.exe' = 0x014c
    'CodexPortable.x86.exe' = 0x014c
    'CodexPortable.x64.exe' = 0x8664
    'CodexPortable.arm64.exe' = 0xAA64
}
foreach ($path in @($bootstrap) + @(Get-ChildItem -LiteralPath $launcherDirectory -File | Select-Object -ExpandProperty FullName)) {
    $bytes = [IO.File]::ReadAllBytes($path)
    try {
        if ($bytes.Length -lt 256) { throw "Compiled launcher is too small: $path" }
        $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
        $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
        $expected = [uint16]$expectedMachines[[IO.Path]::GetFileName($path)]
        if ($machine -ne $expected) {
            throw ("Unexpected PE machine for {0}: 0x{1:X4}" -f $path, $machine)
        }
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

[pscustomobject]@{
    OutputRoot = $resolvedOutput
    Bootstrap = $bootstrap
    VariantDirectory = $launcherDirectory
    BuildCount = [int]$buildResult.BuildCount
    Architectures = 'x86,x64,arm64'
    FileVersion = [string]$buildResult.FileVersion
    OfficialCodexVersion = [string]$buildResult.OfficialCodexVersion
    OfficialPackageSelfTest = [string]$buildResult.OfficialPackageSelfTest
}
