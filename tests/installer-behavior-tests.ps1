#Requires -Version 5.1
[CmdletBinding()]
param([string]$ProjectRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path $PSScriptRoot -Parent }

# Process discovery is the only dependency replaced. Every file path below is
# under a new temporary directory; installed OBS and live profiles are untouched.
function Get-Process {
    param($Name, $Id, $ErrorAction)
    if ($Name -eq 'obs64') {
        if ($simulateRunningObs) { return [pscustomobject]@{ Id = 12345 } }
        return
    }
    Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
}
function Get-FixtureHashes {
    $result = @{}
    Get-ChildItem -LiteralPath $scriptsDirectory -File | Where-Object { $_.Name -ne '.game-replay-install.lock' -and $_.Name -notlike '*.bak*' } |
        ForEach-Object { $result[$_.Name] = (Get-FileHash -LiteralPath $_.FullName).Hash }
    return $result
}
function Copy-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    if ($simulateCorruptCopy -and $LiteralPath -like '*\stage\game-replay-auto.lua' -and
        $Destination -eq (Join-Path $scriptsDirectory 'game-replay-auto.lua')) {
        [IO.File]::WriteAllText($Destination, 'CORRUPTED COPY')
    }
}
function Assert-HashesUnchanged($Expected) {
    $actual = Get-FixtureHashes
    if ($actual.Count -ne $Expected.Count) { throw 'Rollback changed the installed file count.' }
    foreach ($name in $Expected.Keys) {
        if ($actual[$name] -ne $Expected[$name]) { throw "Rollback did not restore $name." }
    }
}
function Invoke-FixtureInstall {
    & (Join-Path $ProjectRoot 'install.ps1') -ScriptsDir $scriptsDirectory -ObsConfigRoot $obsConfigDirectory -NonInteractive -NoStartMenuShortcut 6>$null
}
$simulateRunningObs = $false
$simulateCorruptCopy = $false
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('obs-replay-installer-test-' + [guid]::NewGuid().ToString('N'))
try {
    $scriptsDirectory = Join-Path $tempRoot 'scripts'
    $outputDirectory = Join-Path $tempRoot 'replays'
    $obsConfigDirectory = Join-Path $tempRoot 'obs-config'
    $sceneDirectory = Join-Path $obsConfigDirectory 'basic\scenes'
    New-Item -ItemType Directory -Path $scriptsDirectory, $outputDirectory, $sceneDirectory -Force | Out-Null
    $configPath = Join-Path $scriptsDirectory 'game-replay-auto-config.txt'
    $customConfig = "root_folder=$outputDirectory`r`ngame_capture_source=Game Capture`r`ndefault_replay_seconds=240`r`n[game_overrides]`r`ngame.exe=fullscreen_only=false;anti_cheat_hook=true`r`n"
    [IO.File]::WriteAllText($configPath, $customConfig, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $scriptsDirectory 'game-replay-auto.lua'), 'OLD LUA')
    [IO.File]::WriteAllText((Join-Path $scriptsDirectory 'VERSION'), '0.4.1')
    [IO.File]::WriteAllText((Join-Path $scriptsDirectory 'manifest.json'), '{"version":"0.4.1"}')
    $before = Get-FixtureHashes
    $simulateRunningObs = $true
    $failed = $false
    try { Invoke-FixtureInstall } catch { $failed = $_.Exception.Message -match 'OBS Studio is running'; if (-not $failed) { throw } }
    if (-not $failed) { throw 'Installer did not reject running OBS.' }
    Assert-HashesUnchanged $before
    $simulateRunningObs = $false

    $lock = [IO.File]::Open((Join-Path $scriptsDirectory 'manifest.json'), 'Open', 'Read', 'Read')
    try {
        $failed = $false
        try { Invoke-FixtureInstall } catch { $failed = $_.Exception.Message -match 'previous installation was preserved' }
        if (-not $failed) { throw 'Installer did not report locked destination failure.' }
        Assert-HashesUnchanged $before
    } finally { $lock.Dispose() }
    Write-Host 'PASS locked destination preserves the installed files'

    $directoryCollision = Join-Path $scriptsDirectory 'LICENSE'
    New-Item -ItemType Directory -Path $directoryCollision | Out-Null
    $failed = $false
    try { Invoke-FixtureInstall } catch { $failed = $_.Exception.Message -match 'occupied by a directory' }
    if (-not $failed) { throw 'Installer accepted a directory in place of a runtime file.' }
    Assert-HashesUnchanged $before
    if (@(Get-ChildItem -LiteralPath $directoryCollision -Force).Count -ne 0) { throw 'Installer wrote inside a conflicting directory.' }
    Remove-Item -LiteralPath $directoryCollision
    Write-Host 'PASS directory collision fails before changing installed files'

    # Fail AFTER runtime files have been copied, during configuration validation.
    [IO.File]::WriteAllText($configPath, "game_capture_source=Duplicate`r`n" + $customConfig)
    $before = Get-FixtureHashes
    $failed = $false
    try { Invoke-FixtureInstall } catch { $failed = $_.Exception.Message -match 'more than one game_capture_source' }
    if (-not $failed) { throw 'Expected a late configuration failure.' }
    Assert-HashesUnchanged $before
    Write-Host 'PASS late failure rolls back changed and newly created files'

    [IO.File]::WriteAllText($configPath, $customConfig)
    $before = Get-FixtureHashes
    $simulateCorruptCopy = $true
    $failed = $false
    try { Invoke-FixtureInstall } catch { $failed = $_.Exception.Message -match 'Installed file verification failed' }
    finally { $simulateCorruptCopy = $false }
    if (-not $failed) { throw 'Corrupted destination was not detected' }
    Assert-HashesUnchanged $before
    Write-Host 'PASS corrupt copied file is detected and rolled back'

    [IO.File]::WriteAllText($configPath, $customConfig, [Text.UTF8Encoding]::new($true))
    $configHash = (Get-FileHash -LiteralPath $configPath).Hash
    $scenePath = Join-Path $sceneDirectory 'Fixture.json'
    $originalScene = '{"sources":[{"name":"Game Capture","id":"game_capture","settings":null},{"name":"Other","id":"other","settings":{"keep":42}}]}'
    [IO.File]::WriteAllText($scenePath, $originalScene)
    Invoke-FixtureInstall
    $recoveries = @(Get-ChildItem -LiteralPath $scriptsDirectory -Directory -Filter '.game-replay-install-*' |
        Where-Object { Test-Path (Join-Path $_.FullName 'recovery.json') })
    if ($recoveries.Count -lt 1) { throw 'Successful installation did not retain recovery files' }
    if ((Get-FileHash -LiteralPath $configPath).Hash -ne $configHash) { throw 'Upgrade changed existing config bytes.' }
    $scene = [IO.File]::ReadAllText($scenePath) | ConvertFrom-Json
    if ($scene.sources[0].settings.anti_cheat_hook -ne $false -or $scene.sources[0].settings.window -ne '' -or $scene.sources[1].settings.keep -ne 42) {
        throw 'Scene migration failed or altered an unrelated source.'
    }
    if ([IO.File]::ReadAllText("$scenePath.bak") -ne $originalScene) { throw 'Scene backup differs from the original.' }
    foreach ($name in @('game-replay-auto.lua','VERSION','manifest.json','LICENSE','update.ps1','Update OBS Game Replay Automation.cmd')) {
        if ((Get-FileHash -LiteralPath (Join-Path $scriptsDirectory $name)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $ProjectRoot $name)).Hash) {
            throw "Installed file mismatch: $name"
        }
    }
    Invoke-FixtureInstall
    if (@(Get-ChildItem -LiteralPath $sceneDirectory -Filter '*.bak*').Count -ne 1) { throw 'Repeated installation made an unnecessary scene backup.' }
    Write-Host 'PASS exact config preservation, optional scene fields, metadata, and repeat installation'

    # Test the path parser without running installer entrypoint code.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $ProjectRoot 'install.ps1'), [ref]$tokens, [ref]$errors)
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertTo-AbsolutePath' }, $false)
    . ([scriptblock]::Create($function.Extent.Text))
    foreach ($badPath in @('C:relative','\relative')) {
        $failed = $false
        try { ConvertTo-AbsolutePath -Path $badPath -Label 'Fixture' | Out-Null } catch { $failed = $true }
        if (-not $failed) { throw "Accepted a non-absolute path: $badPath" }
    }
    Write-Host 'PASS drive-relative paths are rejected'
    Write-Host "Installer behavioral tests passed ($($PSVersionTable.PSVersion))."
} finally {
    $fullTemp = [IO.Path]::GetFullPath($tempRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Directory]::GetParent($fullTemp).FullName.TrimEnd('\') -eq $expectedParent -and
        [IO.Path]::GetFileName($fullTemp).StartsWith('obs-replay-installer-test-') -and (Test-Path -LiteralPath $fullTemp)) {
        Remove-Item -LiteralPath $fullTemp -Recurse -Force
    }
}
