#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CompilerPath,
    [string]$OutputDir = (Join-Path $PSScriptRoot 'dist'),
    [switch]$SkipPackage
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$version = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION')).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Setup requires a three-part numeric VERSION.' }
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
if (-not $SkipPackage) { & (Join-Path $PSScriptRoot 'package.ps1') -OutputDir $OutputDir }
$payload = Join-Path $OutputDir "obs-game-replay-automation-$version"
if (-not (Test-Path -LiteralPath (Join-Path $payload 'install.ps1'))) { throw 'Build the release package before compiling Setup.' }
if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    $candidates = @(
        (Join-Path $PSScriptRoot '.tools\inno-portable\ISCC.exe'),
        "${env:ProgramFiles}\Inno Setup 7\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
    )
    $CompilerPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($CompilerPath)) { throw 'Install Inno Setup 6.4+ or 7, or provide -CompilerPath pointing to ISCC.exe.' }
& $CompilerPath "/DAppVersion=$version" "/DPayloadDir=$payload" "/DInstallerOutputDir=$OutputDir" (Join-Path $PSScriptRoot 'installer\obs-game-replay.iss')
if ($LASTEXITCODE -ne 0) { throw "Setup compilation failed: $LASTEXITCODE" }
$exe = Join-Path $OutputDir "obs-game-replay-automation-$version-setup.exe"
$hash = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$exe.sha256.txt", "$hash  $([IO.Path]::GetFileName($exe))" + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Write-Host "Built Windows installer: $exe"
