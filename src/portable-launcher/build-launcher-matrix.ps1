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
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$launcherDirectory = Join-Path $resolvedOutput 'CodexData\tools\launchers'
New-Item -ItemType Directory -Path $launcherDirectory -Force | Out-Null

$common = @{}
if (-not [string]::IsNullOrWhiteSpace($DotNetPath)) { $common.DotNetPath = $DotNetPath }
if (-not [string]::IsNullOrWhiteSpace($FrameworkDirectory)) { $common.FrameworkDirectory = $FrameworkDirectory }

$results = New-Object System.Collections.Generic.List[object]
foreach ($architecture in @('x86', 'x64', 'arm64')) {
    $output = Join-Path $launcherDirectory ("CodexPortable.$architecture.exe")
    $results.Add((& $builder @common -Platform $architecture -OutputPath $output))
}
$bootstrap = Join-Path $resolvedOutput 'CodexPortable.exe'
$results.Add((& $builder @common -Bootstrapper -Platform x86 -OutputPath $bootstrap))

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
    BuildCount = $results.Count
    Architectures = 'x86,x64,arm64'
}
