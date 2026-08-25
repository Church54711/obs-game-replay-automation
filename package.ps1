#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutputDir = (Join-Path $PSScriptRoot "..\dist")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$versionFile = Join-Path $PSScriptRoot "VERSION"
$manifestFile = Join-Path $PSScriptRoot "manifest.json"
$configFile = Join-Path $PSScriptRoot "game-replay-auto-config.txt"
$luaFile = Join-Path $PSScriptRoot "game-replay-auto.lua"
$releaseFiles = @(
    "game-replay-auto.lua",
    "game-replay-auto-config.txt",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    "install.ps1",
    "Install OBS Game Replay Automation.cmd",
    "update.ps1",
    "Update OBS Game Replay Automation.cmd",
    "manifest.json",
    "VERSION"
)

foreach ($file in $releaseFiles) {
    $path = Join-Path $PSScriptRoot $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing release file: $path"
    }
}

$sourceVersion = [System.IO.File]::ReadAllText($versionFile).Trim()
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $sourceVersion
}
if ($Version -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw "Version must be a safe semantic version such as 0.3.0: $Version"
}
if ($Version -ne $sourceVersion) {
    throw "Requested version $Version does not match VERSION $sourceVersion."
}

$manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
if ([string]$manifest.version -ne $Version) {
    throw "manifest.json version $($manifest.version) does not match VERSION $Version."
}
if ([string]$manifest.license -ne '0BSD') {
    throw "manifest.json must identify the release license as 0BSD."
}
if ([string]$manifest.entry -ne "game-replay-auto.lua" -or [string]$manifest.config -ne "game-replay-auto-config.txt") {
    throw "manifest.json entry/config metadata is invalid."
}

foreach ($powerShellFile in @("install.ps1", "package.ps1", "update.ps1")) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot $powerShellFile),
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    if ($parseErrors.Count -gt 0) {
        $messages = ($parseErrors | ForEach-Object { $_.Message }) -join [Environment]::NewLine
        throw "$powerShellFile contains PowerShell parse errors:$([Environment]::NewLine)$messages"
    }
}

$hookPolicyTests = Join-Path $PSScriptRoot "tests\hook-policy-tests.ps1"
if (-not (Test-Path -LiteralPath $hookPolicyTests -PathType Leaf)) {
    throw "Missing hook-policy tests: $hookPolicyTests"
}
& $hookPolicyTests -ProjectRoot $PSScriptRoot

$replayRoutingTests = Join-Path $PSScriptRoot "tests\replay-routing-tests.ps1"
if (-not (Test-Path -LiteralPath $replayRoutingTests -PathType Leaf)) {
    throw "Missing replay-routing tests: $replayRoutingTests"
}
& $replayRoutingTests -ProjectRoot $PSScriptRoot

$releaseSystemTests = Join-Path $PSScriptRoot "tests\release-system-tests.ps1"
if (-not (Test-Path -LiteralPath $releaseSystemTests -PathType Leaf)) {
    throw "Missing release-system tests: $releaseSystemTests"
}
& $releaseSystemTests -ProjectRoot $PSScriptRoot
& (Join-Path $PSScriptRoot 'update.ps1') -SelfTest

$configContent = [System.IO.File]::ReadAllText($configFile)
$rootFolderLines = [regex]::Matches($configContent, '(?im)^\s*root_folder\s*=')
if ($rootFolderLines.Count -ne 1) {
    throw "Config must contain exactly one root_folder setting."
}

$personalPathPattern = '(?i)(V:\\OBS Output Church|Users\\Church|New OBS script project|OBS-Studio-32\.1\.1-Windows-x64)'
foreach ($contentFile in @(
    $configFile,
    $luaFile,
    (Join-Path $PSScriptRoot "README.md"),
    (Join-Path $PSScriptRoot "install.ps1"),
    (Join-Path $PSScriptRoot "update.ps1")
)) {
    $content = [System.IO.File]::ReadAllText($contentFile)
    if ($content -match $personalPathPattern) {
        throw "Personal or portable-test path found in release file: $contentFile"
    }
}

$outputFullPath = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $outputFullPath -Force | Out-Null

$packageName = "obs-game-replay-automation-$Version"
$stagingRoot = Join-Path $outputFullPath $packageName
$zipPath = Join-Path $outputFullPath "$packageName.zip"
$checksumPath = "$zipPath.sha256.txt"

if (-not [string]::Equals(
    [System.IO.Directory]::GetParent($stagingRoot).FullName.TrimEnd('\'),
    $outputFullPath.TrimEnd('\'),
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Refusing to use a staging folder outside the output directory: $stagingRoot"
}

if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

foreach ($file in $releaseFiles) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $stagingRoot $file) -Force
}

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
if (Test-Path -LiteralPath $checksumPath) {
    Remove-Item -LiteralPath $checksumPath -Force
}
Compress-Archive -Path (Join-Path $stagingRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $archiveFiles = @($archive.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { $_.FullName })
} finally {
    $archive.Dispose()
}
$missingArchiveFiles = @($releaseFiles | Where-Object { $_ -notin $archiveFiles })
if ($missingArchiveFiles.Count -gt 0) {
    throw "Release zip is missing: $($missingArchiveFiles -join ', ')"
}
if ($archiveFiles.Count -ne $releaseFiles.Count) {
    throw "Release zip contains an unexpected number of files: $($archiveFiles.Count)"
}

$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumText = "$zipHash  $([System.IO.Path]::GetFileName($zipPath))" + [Environment]::NewLine
[System.IO.File]::WriteAllText($checksumPath, $checksumText, [System.Text.UTF8Encoding]::new($false))

Write-Host "Validated source version $Version."
Write-Host "Built release folder: $stagingRoot"
Write-Host "Built release zip:    $zipPath"
Write-Host "Built SHA-256 file:    $checksumPath"
