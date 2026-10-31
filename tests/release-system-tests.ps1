#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Content -notmatch $Pattern) {
        throw $Message
    }
}

$versionPath = Join-Path $ProjectRoot 'VERSION'
$manifestPath = Join-Path $ProjectRoot 'manifest.json'
$licensePath = Join-Path $ProjectRoot 'LICENSE'
$installerPath = Join-Path $ProjectRoot 'install.ps1'
$updaterPath = Join-Path $ProjectRoot 'update.ps1'
$packagePath = Join-Path $ProjectRoot 'package.ps1'
$releaseWorkflowPath = Join-Path $ProjectRoot '.github\workflows\release.yml'
$pagesWorkflowPath = Join-Path $ProjectRoot '.github\workflows\pages.yml'
$ciWorkflowPath = Join-Path $ProjectRoot '.github\workflows\ci.yml'
$sitePath = Join-Path $ProjectRoot 'docs\index.html'

foreach ($requiredPath in @(
    $versionPath,
    $manifestPath,
    $licensePath,
    $installerPath,
    $updaterPath,
    $packagePath,
    $releaseWorkflowPath,
    $pagesWorkflowPath,
    $ciWorkflowPath,
    $sitePath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Missing release-system file: $requiredPath"
    }
}

$version = [System.IO.File]::ReadAllText($versionPath).Trim()
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.version -ne $version) {
    throw 'manifest.json and VERSION do not agree.'
}
if ([string]$manifest.license -ne '0BSD') {
    throw 'manifest.json does not identify the project as 0BSD licensed.'
}
$license = [System.IO.File]::ReadAllText($licensePath)
Assert-Contains -Content $license -Pattern 'BSD Zero Clause License' -Message 'LICENSE is not the 0BSD license.'
Assert-Contains -Content $license -Pattern 'Permission to use, copy, modify, and/or distribute this software for any\s+purpose' -Message 'LICENSE is missing the 0BSD permission grant.'
Assert-Contains -Content $license -Pattern 'THE SOFTWARE IS PROVIDED "AS IS"' -Message 'LICENSE is missing its warranty disclaimer.'
if ([string]$manifest.updates.provider -ne 'github-releases' -or
    [string]$manifest.updates.repository -ne 'Church54711/obs-game-replay-automation' -or
    [string]$manifest.updates.channel -ne 'stable') {
    throw 'manifest.json GitHub update metadata is invalid.'
}

$installer = [System.IO.File]::ReadAllText($installerPath)
foreach ($fileName in @('manifest.json', 'VERSION', 'LICENSE', 'update.ps1', 'Update OBS Game Replay Automation.cmd')) {
    Assert-Contains `
        -Content $installer `
        -Pattern ([regex]::Escape($fileName)) `
        -Message "Installer does not deploy $fileName."
}
Assert-Contains -Content $installer -Pattern 'New-ScheduledTaskTrigger\s+-Daily' -Message 'Installer does not create a daily update-check trigger.'
Assert-Contains -Content $installer -Pattern 'RunLevel\s+Limited' -Message 'Update-check task must run with limited privileges.'
Assert-Contains -Content $installer -Pattern 'preserveConfigExactly' -Message 'Installer does not enforce exact config preservation for non-interactive upgrades.'

$updater = [System.IO.File]::ReadAllText($updaterPath)
Assert-Contains -Content $updater -Pattern 'releases/latest' -Message 'Updater does not use the stable GitHub latest-release endpoint.'
Assert-Contains -Content $updater -Pattern 'Get-FileHash.+SHA256' -Message 'Updater does not verify the package SHA-256.'
Assert-Contains -Content $updater -Pattern "Get-Process -Name 'obs64'" -Message 'Updater does not refuse installation while OBS is running.'
Assert-Contains -Content $updater -Pattern 'Wait-ForObsToClose' -Message 'One-click updater does not let the user close OBS and retry in place.'
Assert-Contains -Content $updater -Pattern 'Assert-UpdateArchive' -Message 'Updater does not validate downloaded package metadata.'
Assert-Contains -Content $updater -Pattern 'Get-ReplayUpdateCommand.+-ScriptsDir \$PSScriptRoot' -Message 'Updater does not resolve its exact installed scripts directory.'
Assert-Contains -Content $updater -Pattern '-ScriptsDir' -Message 'Updater does not pass its installed scripts directory to setup.'

$package = [System.IO.File]::ReadAllText($packagePath)
foreach ($fileName in @('LICENSE', 'update.ps1', 'Update OBS Game Replay Automation.cmd')) {
    Assert-Contains `
        -Content $package `
        -Pattern ([regex]::Escape($fileName)) `
        -Message "Release package does not include $fileName."
}

$releaseWorkflow = [System.IO.File]::ReadAllText($releaseWorkflowPath)
Assert-Contains -Content $releaseWorkflow -Pattern 'package\.ps1' -Message 'Release workflow does not run the validated package builder.'
Assert-Contains -Content $releaseWorkflow -Pattern 'gh release create' -Message 'Release workflow does not publish a GitHub Release.'
Assert-Contains -Content $releaseWorkflow -Pattern 'obs-game-replay-automation-latest\.zip' -Message 'Release workflow does not create the stable latest-download alias.'

$pagesWorkflow = [System.IO.File]::ReadAllText($pagesWorkflowPath)
foreach ($action in @('actions/configure-pages@v5', 'actions/upload-pages-artifact@v4', 'actions/deploy-pages@v4')) {
    Assert-Contains -Content $pagesWorkflow -Pattern ([regex]::Escape($action)) -Message "Pages workflow is missing $action."
}

$site = [System.IO.File]::ReadAllText($sitePath)
Assert-Contains -Content $site -Pattern 'releases/latest/download/obs-game-replay-automation-latest\.zip' -Message 'Website does not link to the stable latest download.'
Assert-Contains -Content $site -Pattern '>0BSD License<' -Message 'Website does not identify the project license.'

$updater = [System.IO.File]::ReadAllText((Join-Path $ProjectRoot 'update.ps1'))
Assert-Contains -Content $updater -Pattern '\[switch\]\$NoStartMenuShortcut' -Message 'Updater is missing the isolated-test shortcut switch.'
Assert-Contains -Content $updater -Pattern '-NoStartMenuShortcut:\$NoStartMenuShortcut' -Message 'Updater does not pass the isolated-test shortcut switch to the installer.'

if ($null -eq (Get-Process -Name 'obs64' -ErrorAction SilentlyContinue)) {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("obs-game-replay-config-preservation-{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $scriptsDirectory = Join-Path $tempRoot 'scripts'
        $outputDirectory = Join-Path $tempRoot 'replays'
        $obsConfigDirectory = Join-Path $tempRoot 'obs-config'
        New-Item -ItemType Directory -Path $scriptsDirectory, $outputDirectory, $obsConfigDirectory -Force | Out-Null

        & $installerPath `
            -ScriptsDir $scriptsDirectory `
            -OutputRoot $outputDirectory `
            -ObsConfigRoot $obsConfigDirectory `
            -NonInteractive `
            -NoStartMenuShortcut

        $installedConfig = Join-Path $scriptsDirectory 'game-replay-auto-config.txt'
        $customConfig = @(
            "root_folder=$outputDirectory",
            'game_capture_source=Custom Game Capture',
            'game_audio_source=Custom Game Audio',
            'fullscreen_only=false',
            'default_replay_seconds=240',
            '',
            '[game_folders]',
            'customgame.exe=My Custom Game',
            '',
            '[game_overrides]',
            'customgame.exe=fullscreen_only=false;anti_cheat_hook=true',
            ''
        ) -join [Environment]::NewLine
        [System.IO.File]::WriteAllText($installedConfig, $customConfig, [System.Text.UTF8Encoding]::new($false))
        $beforeHash = (Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash

        & $installerPath `
            -ScriptsDir $scriptsDirectory `
            -ObsConfigRoot $obsConfigDirectory `
            -NonInteractive `
            -NoStartMenuShortcut

        $afterHash = (Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash
        if ($beforeHash -ne $afterHash) {
            throw 'Upgrade changed the existing user configuration.'
        }
        foreach ($installedMetadata in @('VERSION', 'manifest.json', 'LICENSE', 'update.ps1', 'Update OBS Game Replay Automation.cmd')) {
            if (-not (Test-Path -LiteralPath (Join-Path $scriptsDirectory $installedMetadata) -PathType Leaf)) {
                throw "Upgrade did not install $installedMetadata."
            }
        }
        if ((Get-FileHash -LiteralPath (Join-Path $scriptsDirectory 'LICENSE') -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $licensePath -Algorithm SHA256).Hash) {
            throw 'Installed LICENSE does not match the source 0BSD license.'
        }
        Write-Host 'Installer config-preservation regression passed.'
    } finally {
        $fullTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
        $systemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if ($fullTempRoot.StartsWith($systemTemp, [System.StringComparison]::OrdinalIgnoreCase) -and
            [System.IO.Path]::GetFileName($fullTempRoot).StartsWith('obs-game-replay-config-preservation-', [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $fullTempRoot)) {
            Remove-Item -LiteralPath $fullTempRoot -Recurse -Force
        }
    }
} else {
    Write-Warning 'Skipped installer config-preservation regression because OBS is running.'
}

Write-Host 'Release-system tests passed.'
