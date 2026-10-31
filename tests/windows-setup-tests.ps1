#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SetupPath,
    [string]$EvidenceDir = (Join-Path $PSScriptRoot '..\dist\setup-tests')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SetupPath = (Resolve-Path -LiteralPath $SetupPath).Path
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
if (Get-Process -Name obs64 -ErrorAction SilentlyContinue) { throw 'Close OBS before running executable installer tests.' }
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{A8DA1B8E-15F0-460D-A8EF-59B198B94FEC}_is1'
if (Test-Path $uninstallKey) { throw 'A per-user Setup installation already exists. Tests will not replace it.' }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('obs-setup-test-' + [guid]::NewGuid().ToString('N'))
$appDirectory = Join-Path $testRoot 'Setup files'
$obsDirectory = Join-Path $testRoot 'OBS Studio'
$configDirectory = Join-Path $testRoot 'OBS config'
$replayDirectory = Join-Path $testRoot ('Clips ' + [char]0x00e9 + ' & games')
$scriptsDirectory = Join-Path $obsDirectory 'data\scripts\obs-game-replay-automation'
$utf8 = [Text.UTF8Encoding]::new($false)
$arguments = @('/CURRENTUSER', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/SP-', '/NORESTART', '/NOICONS', '/TASKS=""',
    ('/DIR="' + $appDirectory + '"'), ('/OBSROOT="' + $obsDirectory + '"'),
    ('/OBSCONFIGROOT="' + $configDirectory + '"'), ('/REPLAYROOT="' + $replayDirectory + '"'))
$uninstaller = Join-Path $appDirectory 'unins000.exe'
$fixtureProcess = $null
$completed = $false
function Invoke-Setup([string]$Name, [bool]$ShouldPass = $true) {
    $process = Start-Process -FilePath $SetupPath -ArgumentList ($arguments + ('/LOG="' + (Join-Path $EvidenceDir "$Name.log") + '"')) -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(60000)) { throw "Setup did not finish within 60 seconds: $Name" }
    if (($process.ExitCode -eq 0) -ne $ShouldPass) { throw "Unexpected Setup exit $($process.ExitCode): $Name" }
}
function Invoke-Uninstall([string]$Name, [bool]$ShouldPass = $true) {
    $process = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG="' + (Join-Path $EvidenceDir "$Name.log") + '"')) -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(60000)) { throw "Uninstall did not finish within 60 seconds: $Name" }
    if (($process.ExitCode -eq 0) -ne $ShouldPass) { throw "Unexpected Uninstall exit $($process.ExitCode): $Name" }
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    $bin = Join-Path $obsDirectory 'bin\64bit'
    $scenes = Join-Path $configDirectory 'basic\scenes'
    New-Item -ItemType Directory -Path $bin, $scenes, $replayDirectory -Force | Out-Null
    # This native Windows process has the OBS executable name, but no OBS
    # runtime or user's settings. Only this test-owned process is stopped.
    $fakeObs = Join-Path $bin 'obs64.exe'
    Copy-Item -LiteralPath "$env:WINDIR\System32\ping.exe" -Destination $fakeObs
    $fixtureProcess = Start-Process -FilePath $fakeObs -ArgumentList @('-t', '127.0.0.1') -WindowStyle Hidden -PassThru
    Invoke-Setup 'running-obs' $false
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $scriptsDirectory 'game-replay-auto.lua'))) 'Setup installed while OBS was running.'
    Stop-Process -Id $fixtureProcess.Id
    $fixtureProcess.WaitForExit(); $fixtureProcess = $null
    Write-Host 'PASS executable refuses running OBS before installation'

    $scenePath = Join-Path $scenes 'Test.json'
    $sceneText = '{"sources":[{"name":"Game Capture","id":"game_capture","settings":{"anti_cheat_hook":true,"window":"old"}},{"name":"Unrelated","id":"color_source","settings":{"color":12345}}],"modules":{"scripts-tool":[{"path":"C:/other/script.lua","settings":{"value":12}}]}}'
    [IO.File]::WriteAllText($scenePath, $sceneText, $utf8)
    Invoke-Setup 'fresh-install'
    Assert-True (Test-Path -LiteralPath $uninstaller) 'Setup did not create an uninstaller.'
    $setupSignature = Get-AuthenticodeSignature -LiteralPath $SetupPath
    if ($setupSignature.Status -eq 'Valid') {
        & (Join-Path $PSScriptRoot '..\verify-release.ps1') -Path $uninstaller -SignatureOnly -RequireSignature -ExpectedThumbprint $setupSignature.SignerCertificate.Thumbprint
    }
    Assert-True (Test-Path $uninstallKey) 'Setup did not register Installed Apps.'
    Assert-True ((Get-ItemProperty $uninstallKey).InstallLocation.TrimEnd('\') -eq $appDirectory) 'Installed Apps points outside the fixture.'
    $state = [IO.File]::ReadAllText((Join-Path $appDirectory 'deployment-state.json')) | ConvertFrom-Json
    Assert-True ($state.scriptsDir -eq $scriptsDirectory) 'Setup saved the wrong scripts directory.'
    $configPath = Join-Path $scriptsDirectory 'game-replay-auto-config.txt'
    Assert-True ([IO.File]::ReadAllText($configPath).Contains('root_folder=' + $replayDirectory)) 'Unicode replay folder did not survive the setup bridge.'
    $scene = [IO.File]::ReadAllText($scenePath) | ConvertFrom-Json
    Assert-True (-not $scene.sources[0].settings.anti_cheat_hook) 'Setup did not apply safe capture defaults.'
    Write-Host 'PASS fresh executable install, Unicode path, inventory, and Installed Apps registration'

    # User settings must survive upgrades byte-for-byte; all unrelated OBS
    # content and a saved replay must also survive uninstall.
    [IO.File]::AppendAllText($configPath, "`r`n# User customized this installation.`r`n", $utf8)
    $scriptPath = Join-Path $scriptsDirectory 'game-replay-auto.lua'
    $scene.modules.'scripts-tool' += [pscustomobject]@{ path = $scriptPath.Replace('\', '/'); settings = @{ ui_game_overrides = 'game.exe=replay_seconds=120'; hotkeys = @(1, 2, 3) } }
    [IO.File]::WriteAllText($scenePath, ($scene | ConvertTo-Json -Depth 100), $utf8)
    $configHash = (Get-FileHash -LiteralPath $configPath).Hash
    $sceneHash = (Get-FileHash -LiteralPath $scenePath).Hash
    # A 0.7 EXE inventory predates the shared runtime record. Its ZIP updater
    # passes only ScriptsDir; recover the custom config from Installed Apps.
    Remove-Item -LiteralPath (Join-Path $scriptsDirectory 'game-replay-installation.json')
    & (Join-Path $appDirectory 'payload\install.ps1') -ScriptsDir $scriptsDirectory -NonInteractive -NoStartMenuShortcut
    $migratedRecord = Get-Content (Join-Path $scriptsDirectory 'game-replay-installation.json') -Raw | ConvertFrom-Json
    Assert-True ($migratedRecord.obsConfigRoot -eq $configDirectory -and $migratedRecord.setupAppDir -eq $appDirectory) 'Legacy EXE upgrade lost its custom OBS folder or maintenance ownership.'
    Write-Host 'PASS legacy EXE inventory migrates through the ZIP updater path'
    $clip = Join-Path $replayDirectory 'keep-this-clip.mkv'
    [IO.File]::WriteAllText($clip, 'TEST CLIP DATA', $utf8)
    [IO.File]::WriteAllText((Join-Path $scriptsDirectory 'unrelated.lua'), '-- another script', $utf8)
    [IO.File]::WriteAllText((Join-Path $scriptsDirectory 'VERSION'), '0.6.0', $utf8)
    [IO.File]::WriteAllText($scriptPath, '-- OLD RELEASE', $utf8)
    Invoke-Setup 'upgrade'
    Assert-True ((Get-FileHash -LiteralPath $configPath).Hash -eq $configHash) 'Upgrade changed the user configuration.'
    Assert-True ((Get-FileHash -LiteralPath $scenePath).Hash -eq $sceneHash) 'Upgrade changed existing script settings.'
    Assert-True ([IO.File]::ReadAllText($scriptPath) -ne '-- OLD RELEASE') 'Upgrade did not replace the runtime.'
    Assert-True (@(Get-ChildItem -LiteralPath $scriptsDirectory -Directory -Filter '.game-replay-install-*').Count -ge 2) 'Upgrade discarded recovery backups.'
    Write-Host 'PASS upgrade replaces runtime and preserves config, script settings, and backups'

    # Simulate a subsequent ZIP updater release. The shared record must update
    # the EXE maintenance payload and Installed Apps while preserving preferences.
    $prefsDir = Join-Path $configDirectory 'game-replay-automation'
    New-Item -ItemType Directory -Path $prefsDir -Force | Out-Null
    $prefsPath = Join-Path $prefsDir 'settings.json'
    $preferencesText = @{ schemaVersion=1; settings=@{output_root=$replayDirectory; game_capture_source='Game Capture'; game_audio_source='Game Audio'} } | ConvertTo-Json
    [IO.File]::WriteAllText($prefsPath, $preferencesText, $utf8)
    $prefsHash = (Get-FileHash -LiteralPath $prefsPath).Hash
    $project = Split-Path $PSScriptRoot -Parent
    $next = Join-Path $testRoot 'Next release'
    New-Item -ItemType Directory -Path $next -Force | Out-Null
    Copy-Item -Path (Join-Path $appDirectory 'payload\*') -Destination $next
    [IO.File]::WriteAllText((Join-Path $next 'VERSION'), '0.8.1', $utf8)
    $nextManifest = Get-Content (Join-Path $next 'manifest.json') -Raw | ConvertFrom-Json
    $nextManifest.version = '0.8.1'
    [IO.File]::WriteAllText((Join-Path $next 'manifest.json'), ($nextManifest | ConvertTo-Json -Depth 20), $utf8)
    . (Join-Path $next 'installation.ps1')
    $updateCommand = Get-ReplayUpdateCommand -InstallerPath (Join-Path $next 'install.ps1') -ScriptsDir $scriptsDirectory -NoStartMenuShortcut
    & ([scriptblock]::Create($updateCommand))
    Assert-True ((Get-ItemProperty $uninstallKey).DisplayVersion -eq '0.8.1') 'ZIP update left a stale Installed Apps version.'
    Assert-True ((Get-Content (Join-Path $appDirectory 'payload\VERSION') -Raw).Trim() -eq '0.8.1') 'ZIP update left stale maintenance payload.'
    Assert-True ((Get-FileHash -LiteralPath $prefsPath).Hash -eq $prefsHash) 'ZIP update changed canonical preferences.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $appDirectory 'setup-bridge.ps1')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $next 'setup-bridge.ps1')).Hash) 'ZIP update did not synchronize the uninstall helper.'
    Write-Host 'PASS ZIP update keeps EXE inventory, Installed Apps, maintenance payload and preferences consistent'

    # Restore the test's pre-migration state for the legacy-config failure case.
    Remove-Item -LiteralPath $prefsPath

    $beforeFailure = (Get-FileHash -LiteralPath $scriptPath).Hash
    $validConfig = [IO.File]::ReadAllBytes($configPath)
    [IO.File]::AppendAllText($configPath, "`r`ngame_capture_source=Duplicate`r`n", $utf8)
    $invalidConfigHash = (Get-FileHash -LiteralPath $configPath).Hash
    try {
        Invoke-Setup 'failed-upgrade' $false
        Assert-True (Test-Path -LiteralPath $uninstaller) 'Failed upgrade removed the existing uninstaller.'
        Assert-True (Test-Path $uninstallKey) 'Failed upgrade removed the existing Installed Apps entry.'
        Assert-True ((Get-FileHash -LiteralPath $scriptPath).Hash -eq $beforeFailure) 'Failed upgrade changed the runtime.'
        Assert-True ((Get-FileHash -LiteralPath $configPath).Hash -eq $invalidConfigHash) 'Failed upgrade changed the user configuration.'
        Assert-True (Test-Path -LiteralPath (Join-Path $appDirectory 'setup-bridge.ps1')) 'Failed upgrade removed the maintenance helper.'
    } finally { [IO.File]::WriteAllBytes($configPath, $validConfig) }
    Write-Host 'PASS late upgrade failure preserves the existing runtime, config, and uninstall entry'

    $locked = [IO.File]::Open($scriptPath, 'Open', 'Read', 'Read')
    try { Invoke-Uninstall 'locked-uninstall' $false } finally { $locked.Dispose() }
    Assert-True (Test-Path -LiteralPath $uninstaller) 'Failed uninstall removed its maintenance files.'
    Assert-True (Test-Path $uninstallKey) 'Failed uninstall removed Installed Apps registration.'
    Assert-True ((Get-FileHash -LiteralPath $scriptPath).Hash -eq $beforeFailure) 'Failed uninstall changed the script.'
    Assert-True ((Get-FileHash -LiteralPath $scenePath).Hash -eq $sceneHash) 'Failed uninstall changed the scene.'
    Write-Host 'PASS locked-file uninstall aborts before removing runtime or maintenance files'

    [IO.File]::WriteAllText($prefsPath, $preferencesText, $utf8)
    Invoke-Uninstall 'uninstall'
    Assert-True ((Get-FileHash -LiteralPath $prefsPath).Hash -eq $prefsHash) 'Uninstall changed canonical user preferences.'
    Assert-True (-not (Test-Path -LiteralPath $scriptPath)) 'Uninstall left the runtime file.'
    Assert-True (-not (Test-Path $uninstallKey)) 'Uninstall left Installed Apps registration.'
    Assert-True ((Get-FileHash -LiteralPath $configPath).Hash -eq $configHash) 'Uninstall removed or changed the user configuration.'
    Assert-True ([IO.File]::ReadAllText($clip) -eq 'TEST CLIP DATA') 'Uninstall changed a replay.'
    Assert-True (Test-Path -LiteralPath (Join-Path $scriptsDirectory 'unrelated.lua')) 'Uninstall removed another script.'
    $scene = [IO.File]::ReadAllText($scenePath) | ConvertFrom-Json
    Assert-True (@($scene.modules.'scripts-tool').Count -eq 1 -and $scene.modules.'scripts-tool'[0].path -eq 'C:/other/script.lua') 'Uninstall failed to remove only its own OBS registration.'
    Assert-True ($scene.sources[1].settings.color -eq 12345) 'Uninstall changed unrelated sources.'
    $recovery = @(Get-ChildItem -LiteralPath $scriptsDirectory -Directory -Filter '.game-replay-uninstall-*' | Where-Object { Test-Path (Join-Path $_.FullName 'recovery.json') })
    Assert-True ($recovery.Count -ge 1) 'Uninstall did not keep recovery backups.'
    Write-Host 'PASS uninstall retains clips, config, unrelated sources/scripts, and recovery backups'

    # A failed first EXE setup can encounter a pre-existing ZIP installation.
    # Its maintenance-only uninstall must preserve that previous runtime.
    [IO.File]::WriteAllText($scriptPath, '-- PRE-EXISTING ZIP RUNTIME', $utf8)
    [IO.File]::WriteAllText((Join-Path $scriptsDirectory 'manifest.json'), '{"name":"obs-game-replay-automation","version":"0.6.0"}', $utf8)
    [IO.File]::AppendAllText($configPath, "`r`ngame_capture_source=Duplicate`r`n", $utf8)
    $failedFreshHash = (Get-FileHash -LiteralPath $configPath).Hash
    Invoke-Setup 'failed-first-setup' $false
    Assert-True ([IO.File]::ReadAllText($scriptPath) -eq '-- PRE-EXISTING ZIP RUNTIME') 'Failed first setup changed the previous ZIP runtime.'
    $state = [IO.File]::ReadAllText((Join-Path $appDirectory 'deployment-state.json')) | ConvertFrom-Json
    Assert-True ($state.runtimeInstalled -eq $false) 'Failed first setup claimed ownership of the previous runtime.'
    Invoke-Uninstall 'failed-first-setup-cleanup'
    Assert-True (-not (Test-Path $uninstallKey)) 'Failed first setup could not be removed from Installed Apps.'
    Assert-True ([IO.File]::ReadAllText($scriptPath) -eq '-- PRE-EXISTING ZIP RUNTIME') 'Maintenance cleanup removed the previous ZIP runtime.'
    Assert-True ((Get-FileHash -LiteralPath $configPath).Hash -eq $failedFreshHash) 'Maintenance cleanup changed user configuration.'
    Write-Host 'PASS failed first setup reports failure and remains removable without deleting a previous ZIP installation'
    $completed = $true
} finally {
    if ($null -ne $fixtureProcess -and -not $fixtureProcess.HasExited) { Stop-Process -Id $fixtureProcess.Id }
    # Keep failing fixtures intact for diagnosis and a repeatable uninstall.
    if ($completed -and [IO.Path]::GetDirectoryName($testRoot) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($testRoot).StartsWith('obs-setup-test-')) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    } elseif (-not $completed) { Write-Warning "Setup test fixture retained: $testRoot" }
}
