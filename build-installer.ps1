#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CompilerPath,
    [string]$OutputDir = (Join-Path $PSScriptRoot 'dist'),
    [switch]$SkipPackage,
    [ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$CertificateThumbprint,
    [string]$TimestampUrl = 'https://timestamp.digicert.com',
    [string]$SignToolPath
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
$compilerArgs = @("/DAppVersion=$version", "/DPayloadDir=$payload", "/DInstallerOutputDir=$OutputDir")
$savedEnvironment = @{}
try {
    if ($CertificateThumbprint) {
        if (-not $SignToolPath) {
            $sdk = Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Windows Kits\10\bin\*\x64\signtool.exe'
            $SignToolPath = Get-ChildItem $sdk | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $SignToolPath) { throw 'Install Windows SDK SignTool or supply -SignToolPath.' }
        foreach ($name in @('REPLAY_SIGNING_THUMBPRINT','REPLAY_SIGNING_TIMESTAMP_URL','REPLAY_SIGNTOOL_PATH')) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $env:REPLAY_SIGNING_THUMBPRINT = $CertificateThumbprint
        $env:REPLAY_SIGNING_TIMESTAMP_URL = $TimestampUrl
        $env:REPLAY_SIGNTOOL_PATH = (Resolve-Path -LiteralPath $SignToolPath).Path
        # $f is Inno's quoted filename placeholder. Escape literal dollars in
        # paths before using $q for quotes; no secret is passed to ISCC.
        $powershell = (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe').Replace('$','$$')
        $signer = (Join-Path $PSScriptRoot 'signing\sign-file.ps1').Replace('$','$$')
        $compilerArgs += '/DEnableSigning'
        $compilerArgs += ('/SReplaySign=$q' + $powershell + '$q -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $q' + $signer + '$q -Path $f')
    }
    & $CompilerPath @compilerArgs (Join-Path $PSScriptRoot 'installer\obs-game-replay.iss')
    if ($LASTEXITCODE -ne 0) { throw "Setup compilation failed: $LASTEXITCODE" }
} finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
}
$exe = Join-Path $OutputDir "obs-game-replay-automation-$version-setup.exe"
$hash = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$exe.sha256.txt", "$hash  $([IO.Path]::GetFileName($exe))" + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
if ($CertificateThumbprint) {
    & (Join-Path $PSScriptRoot 'verify-release.ps1') -Path $exe -RequireSignature -ExpectedThumbprint $CertificateThumbprint
} else {
    & (Join-Path $PSScriptRoot 'verify-release.ps1') -Path $exe
    Write-Host 'Unsigned build: no publisher identity was requested.'
}
Write-Host "Built Windows installer: $exe"
