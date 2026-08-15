[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseParentRoot,

    [string]$Repository = 'riveryang6/codex-desktop-portable'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$assetName = 'LFPortable-release.zip'
$maximumAssetBytes = 2GB - 1
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$releaseParent = [IO.Path]::GetFullPath($ReleaseParentRoot).TrimEnd('\')
$releaseRoot = Join-Path $releaseParent 'release'
$manifestPath = Join-Path $releaseParent 'portable-package-manifest.json'
$archivePath = Join-Path $releaseParent $assetName

function Invoke-Native([string]$FilePath, [string[]]$ArgumentList) {
    $output = @(& $FilePath @ArgumentList 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$FilePath failed with exit code $exitCode.`r`n$($output -join [Environment]::NewLine)"
    }
    return ($output -join "`n")
}

function Get-Json([string]$Text, [string]$Label) {
    try { return $Text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "$Label is not valid JSON: $($_.Exception.Message)" }
}

function Assert-RemoteAsset($Release, [long]$ExpectedLength, [string]$ExpectedSha256) {
    $assets = @($Release.assets | Where-Object { [string]$_.name -ceq $assetName })
    if ($assets.Count -ne 1 -or @($Release.assets).Count -ne 1) {
        throw "GitHub Release must contain exactly one asset named $assetName."
    }
    $asset = $assets[0]
    if ([string]$asset.state -cne 'uploaded') {
        throw "GitHub Release asset is not in the uploaded state: $($asset.state)"
    }
    if ([long]$asset.size -ne $ExpectedLength) {
        throw "GitHub Release asset length differs (expected $ExpectedLength, actual $($asset.size))."
    }
    $digest = [string]$asset.digest
    if ($digest -notmatch '^sha256:[A-Fa-f0-9]{64}$') {
        throw 'GitHub Release asset has no valid SHA-256 digest.'
    }
    if (-not $digest.Substring(7).Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'GitHub Release asset SHA-256 differs from the verified local archive.'
    }
    $downloadUrl = [string]$asset.browser_download_url
    if ($downloadUrl -notmatch '^https://github\.com/riveryang6/codex-desktop-portable/releases/download/') {
        throw 'GitHub Release asset public download URL is invalid.'
    }
    return $asset
}

foreach ($required in @($releaseRoot, $manifestPath, $archivePath)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required release input is missing: $required" }
}
if (-not (Test-Path -LiteralPath $releaseRoot -PathType Container) -or
    -not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw 'Release inputs have invalid file types.'
}

$gh = (Get-Command gh.exe -ErrorAction Stop).Source
$git = (Get-Command git.exe -ErrorAction Stop).Source
$curl = (Get-Command curl.exe -ErrorAction Stop).Source
$manifest = Get-Json ([IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)) 'Portable manifest'
$version = [string]$manifest.ReleaseVersion
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' -or
    -not $version.Equals([string]$manifest.LauncherVersion, [StringComparison]::Ordinal)) {
    throw 'Portable manifest has inconsistent four-part LF versions.'
}
$tag = 'v' + $version
$archive = Get-Item -LiteralPath $archivePath -Force
if ($archive.Length -le 0 -or $archive.Length -gt $maximumAssetBytes) {
    throw "$assetName cannot be uploaded to GitHub Releases at $($archive.Length) bytes."
}

Push-Location -LiteralPath $repoRoot
try {
    $status = Invoke-Native $git @('status', '--porcelain=v1')
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw 'Git working tree must be clean before publishing a stable release.'
    }
    $head = (Invoke-Native $git @('rev-parse', 'HEAD')).Trim()
    $originMain = (Invoke-Native $git @('rev-parse', 'origin/main')).Trim()
    if (-not $head.Equals($originMain, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'HEAD must exactly match origin/main before publishing.'
    }
    $headTags = @((Invoke-Native $git @('tag', '--points-at', 'HEAD')) -split "`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($headTags -notcontains $tag) { throw "HEAD is not tagged $tag." }
    Invoke-Native $git @('ls-remote', '--exit-code', '--tags', 'origin', "refs/tags/$tag") | Out-Null
    $archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()

    Invoke-Native $gh @('auth', 'status', '--hostname', 'github.com') | Out-Null
    $repo = Get-Json (Invoke-Native $gh @('repo', 'view', $Repository, '--json',
        'nameWithOwner,visibility')) 'GitHub repository metadata'
    if ([string]$repo.nameWithOwner -cne $Repository -or [string]$repo.visibility -cne 'PUBLIC') {
        throw 'The configured GitHub repository is not the expected public repository.'
    }
    & $gh release view $tag --repo $Repository *> $null
    if ($LASTEXITCODE -eq 0) { throw "GitHub Release already exists for $tag." }

    $notes = "LF Portable $version`n`nComplete verified portable release for launcher-managed updates."
    Invoke-Native $gh @('release', 'create', $tag, '--repo', $Repository, '--draft',
        '--verify-tag', '--title', "LF Portable $version", '--notes', $notes) | Out-Null
    Invoke-Native $gh @('release', 'upload', $tag, $archivePath, '--repo', $Repository) | Out-Null

    $draft = Get-Json (Invoke-Native $gh @('api', "repos/$Repository/releases/tags/$tag")) 'Draft release metadata'
    if (-not [bool]$draft.draft -or [bool]$draft.prerelease -or [string]$draft.tag_name -cne $tag) {
        throw 'GitHub draft release metadata is inconsistent.'
    }
    $draftAsset = Assert-RemoteAsset $draft $archive.Length $archiveSha256

    Invoke-Native $gh @('release', 'edit', $tag, '--repo', $Repository, '--draft=false', '--latest') | Out-Null
    $latest = Get-Json (Invoke-Native $gh @('api', "repos/$Repository/releases/latest")) 'Latest release metadata'
    if ([bool]$latest.draft -or [bool]$latest.prerelease -or [string]$latest.tag_name -cne $tag) {
        throw 'Published GitHub Release is not the expected latest stable release.'
    }
    $latestAsset = Assert-RemoteAsset $latest $archive.Length $archiveSha256

    $verificationRoot = Join-Path $releaseParent ('.github-release-verify-' + [Guid]::NewGuid().ToString('N'))
    $downloadPath = Join-Path $verificationRoot $assetName
    New-Item -ItemType Directory -Path $verificationRoot -ErrorAction Stop | Out-Null
    try {
        Invoke-Native $curl @('--fail', '--location', '--silent', '--show-error',
            '--output', $downloadPath, [string]$latestAsset.browser_download_url) | Out-Null
        $download = Get-Item -LiteralPath $downloadPath -Force
        if ($download.Length -ne $archive.Length) { throw 'Public round-trip download length differs.' }
        $downloadSha256 = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
        if (-not $downloadSha256.Equals($archiveSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Public round-trip download SHA-256 differs.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $verificationRoot -PathType Container) {
            Remove-Item -LiteralPath $verificationRoot -Recurse -Force
        }
    }

    [pscustomobject]@{
        Status = 'PublishedAndRoundTripVerified'
        Repository = $Repository
        Tag = $tag
        ReleaseId = [long]$latest.id
        AssetName = $assetName
        AssetBytes = [long]$archive.Length
        AssetSha256 = $archiveSha256
        PublicDownloadUrl = [string]$latestAsset.browser_download_url
        SourceCommit = $head
    }
}
finally {
    Pop-Location
}
