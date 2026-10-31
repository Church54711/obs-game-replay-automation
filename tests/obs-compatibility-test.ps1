#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ObsRoot,
    [ValidateSet('Simple', 'Advanced')][string]$Mode = 'Simple',
    [string]$EvidenceDir = (Join-Path $PSScriptRoot '..\dist\compatibility'),
    [int]$TimeoutSeconds = 60,
    [switch]$CaptureAcceptance,
    [ValidateSet('x264', 'NVENC')][string]$Encoder = 'x264'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path $PSScriptRoot -Parent
$obsFull = (Resolve-Path -LiteralPath $ObsRoot).Path
if (-not (Test-Path (Join-Path $obsFull 'bin\64bit\obs64.exe'))) { throw 'Expected Windows x64 OBS distribution' }
$expectedVersion = (Get-Item (Join-Path $obsFull 'bin\64bit\obs64.exe')).VersionInfo.ProductVersion
$evidence = [IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Force $evidence | Out-Null
$runtime = Join-Path ([IO.Path]::GetTempPath()) ('obs-compatibility-' + [guid]::NewGuid().ToString('N'))
$process = $null
$fixture = $null
$junctions = @()
function Write-Utf8([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force (Split-Path $Path -Parent) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
try {
    New-Item -ItemType Directory -Force $runtime | Out-Null
    if ($Encoder -ne 'x264' -and -not $CaptureAcceptance) { throw 'Hardware encoding requires CaptureAcceptance.' }
    if ($CaptureAcceptance) {
        $null = Get-Command ffmpeg -ErrorAction Stop
        $fixtureExe = Join-Path $runtime 'ReplayCaptureFixture.exe'
        & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /optimize+ /define:CAPTURE_ACCEPTANCE /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll "/out:$fixtureExe" (Join-Path $PSScriptRoot 'hook-policy-window-fixture.cs')
        if ($LASTEXITCODE -ne 0) { throw 'Capture fixture compilation failed.' }
        $handleFile = Join-Path $runtime 'fixture-handle.txt'
        $fixture = Start-Process -FilePath $fixtureExe -ArgumentList ('"' + $handleFile + '"') -WindowStyle Hidden -PassThru
        $until = [DateTime]::UtcNow.AddSeconds(10)
        do { Start-Sleep -Milliseconds 100 } while (-not (Test-Path -LiteralPath $handleFile) -and -not $fixture.HasExited -and [DateTime]::UtcNow -lt $until)
        if (-not (Test-Path -LiteralPath $handleFile)) { throw 'Capture fixture window was not created.' }
        $fixtureHandle = [long][IO.File]::ReadAllText($handleFile)
    }
    foreach ($name in @('bin', 'data', 'core', 'obs-plugins')) {
        $target = Join-Path $obsFull $name
        if (Test-Path -LiteralPath $target -PathType Container) {
            $link = Join-Path $runtime $name
            New-Item -ItemType Junction -Path $link -Target $target | Out-Null
            $junctions += $link
        }
    }
    Write-Utf8 (Join-Path $runtime 'portable_mode.txt') ''
    $config = Join-Path $runtime 'config\obs-studio'
    $output = Join-Path $runtime 'replays'
    New-Item -ItemType Directory -Force $output | Out-Null
    $recording = Join-Path $runtime 'recordings'
    New-Item -ItemType Directory -Force $recording | Out-Null
    $recordingObs = $recording.Replace('\', '/')
    $outputObs = $output.Replace('\', '/')
    $userIni = "[General]`nFirstRun=true`nEnableAutoUpdates=false`n[Basic]`nProfile=Compatibility`nProfileDir=Compatibility`nSceneCollection=Compatibility`nSceneCollectionFile=Compatibility`n[BasicWindow]`nPreviewEnabled=false`n"
    Write-Utf8 (Join-Path $config 'global.ini') $userIni
    Write-Utf8 (Join-Path $config 'user.ini') $userIni
    $profile = @"
[General]
Name=Compatibility
[Output]
Mode=$Mode
FilenameFormatting=%CCYY-%MM/%CCYY-%MM-%DD %hh-%mm-%ss
[SimpleOutput]
FilePath=$recordingObs
RecFormat2=mkv
StreamEncoder=x264
RecEncoder=x264
RecQuality=Small
RecRB=true
RecRBTime=3
RecRBSize=64
VBitrate=500
ABitrate=64
RecAudioEncoder=aac
StreamAudioEncoder=aac
[AdvOut]
RecType=Standard
RecFilePath=$recordingObs
RecFormat2=mkv
RecEncoder=obs_x264
RecAudioEncoder=ffmpeg_aac
RecTracks=1
RecRB=true
RecRBTime=3
RecRBSize=64
[Video]
BaseCX=320
BaseCY=180
OutputCX=320
OutputCY=180
FPSType=0
FPSCommon=10
[Audio]
SampleRate=48000
ChannelSetup=Stereo
"@
    Write-Utf8 (Join-Path $config 'basic\profiles\Compatibility\basic.ini') $profile
    if ($Encoder -eq 'NVENC') {
        $profile = $profile.Replace('RecEncoder=x264', 'RecEncoder=nvenc').Replace('RecEncoder=obs_x264','RecEncoder=obs_nvenc_h264_tex')
        Write-Utf8 (Join-Path $config 'basic\profiles\Compatibility\basic.ini') $profile
    }
    $script = Join-Path $runtime 'scripts\game-replay-auto.lua'
    Write-Utf8 $script ([IO.File]::ReadAllText((Join-Path $project 'game-replay-auto.lua')) + "`n" + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'compatibility-runtime.lua')))
    Write-Utf8 (Join-Path $runtime 'scripts\game-replay-auto-config.txt') "root_folder=$outputObs`nfullscreen_only=false`ndefault_replay_seconds=3`n[game_folders]`nobs64.exe=Compatibility Fixture`n[game_overrides]`nobs64.exe=enabled=true`n"
    Write-Utf8 (Join-Path $runtime 'scripts\game-replay-installation.json') (@{
        schemaVersion=1; product='obs-game-replay-automation'
        scriptsDir=(Join-Path $runtime 'scripts'); obsConfigRoot=$config
        settingsDir=(Join-Path $config 'game-replay-automation'); setupAppDir=''
    } | ConvertTo-Json)
    if ($CaptureAcceptance) {
        $driver = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'compatibility-runtime.lua'))
        $identity = 'local acceptance_fixture = {pid=' + $fixture.Id + ', handle=' + $fixtureHandle + ', exe="ReplayCaptureFixture.exe"}'
        Write-Utf8 $script ([IO.File]::ReadAllText((Join-Path $project 'game-replay-auto.lua')) + [Environment]::NewLine + $identity + [Environment]::NewLine + $driver)
        $sidecar = Join-Path $runtime 'scripts\game-replay-auto-config.txt'
        Write-Utf8 $sidecar ([IO.File]::ReadAllText($sidecar).Replace('obs64.exe=', 'ReplayCaptureFixture.exe='))
    }
    $scene = @{
        name = 'Compatibility'; current_scene = 'Fixture'; current_program_scene = 'Fixture'
        scene_order = @(@{name='Fixture'})
        sources = @(@{name='Fixture'; id='scene'; settings=@{items=@()}})
        modules = @{'scripts-tool'=@(@{path=$script.Replace('\','/'); settings=@{
            poll_interval_ms=500; stable_poll_count=1; minimum_window_area_percent=0
        }})}
    }
    Write-Utf8 (Join-Path $config 'basic\scenes\Compatibility.json') ($scene | ConvertTo-Json -Depth 20)
    $exe = Join-Path $runtime 'bin\64bit\obs64.exe'
    $oldLayer = $env:__COMPAT_LAYER
    try {
        $env:__COMPAT_LAYER = 'RunAsInvoker'
        $process = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Hidden -PassThru -ArgumentList '--portable','--multi','--only-bundled-plugins','--disable-updater','--disable-shutdown-check','--minimize-to-tray'
    } finally { $env:__COMPAT_LAYER = $oldLayer }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $passed = $false
    do {
        $logs = @(Get-ChildItem (Join-Path $config 'logs') -Filter '*.txt' -ErrorAction SilentlyContinue)
        if ($logs.Count -gt 0) {
            $logText = Get-Content -LiteralPath $logs[0].FullName -Raw
            if ($logText -match 'COMPATIBILITY PASSED:') { $passed = $true; break }
            if ($logText -match '\[Lua: game-replay-auto.lua\].*(Error|Failed|Error loading|not supported|Lifecycle timeout)') { throw 'Lua runtime failure; see retained OBS log' }
        }
        if ($process.HasExited) { throw "Test OBS exited: $($process.ExitCode)" }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $passed) { throw 'OBS compatibility test timed out; see retained OBS log' }
    $versionMatch = [regex]::Match($logText, 'COMPATIBILITY PASSED: ([^\r\n]+)')
    $runningVersion = $versionMatch.Groups[1].Value.Trim()
    if ($runningVersion -ne $expectedVersion) { throw "Unexpected running OBS version: $runningVersion; expected $expectedVersion" }
    $clips = @(Get-ChildItem (Join-Path $output 'Compatibility Fixture') -Recurse -Filter '*.mkv')
    if ($clips.Count -ne 1 -or $clips[0].Length -le 0) { throw 'Expected one non-empty routed replay' }
    if ($clips[0].Directory.Name -notmatch '^\d{4}-\d{2}$') { throw 'Date subfolder format was not preserved' }
    $diagnosticPath = Join-Path $config 'game-replay-automation\diagnostics.json'
    $diagnostics = [IO.File]::ReadAllText($diagnosticPath)
    if ($diagnostics -match '(?i)Private Person|Secret Game|[a-z]:[\\/]|Users[\\/]') { throw 'Diagnostic report contains private paths or game names' }
    $null = $diagnostics | ConvertFrom-Json
    Copy-Item -LiteralPath $diagnosticPath -Destination (Join-Path $evidence "$Mode-diagnostics.json") -Force
    Copy-Item -LiteralPath $clips[0].FullName -Destination (Join-Path $evidence "$Mode-replay.mkv") -Force
    $summary = @{
        obsVersion = $runningVersion; mode = $Mode
        passed = $true; replayBytes = $clips[0].Length
        replaySha256 = (Get-FileHash $clips[0].FullName).Hash
        encoder = $Encoder; captureAcceptance = [bool]$CaptureAcceptance
        scope = 'Real OBS APIs, preferences, setup, status, diagnostics, lifecycle, replay encoding and routing'
    }
    if ($CaptureAcceptance) {
        & (Join-Path $PSScriptRoot 'verify-capture-media.ps1') -Clip $clips[0].FullName -EvidenceDir $evidence
        if ($logText -notmatch 'capture successful') { throw 'OBS did not confirm successful graphics capture.' }
        if ($Encoder -eq 'NVENC' -and $logText -notmatch '\[obs-nvenc:') { throw 'Hardware encoder was not used.' }
        $summary.scope += '; actual OpenGL hook and application audio from isolated fixture, decoded motion and tone; commercial games/anti-cheat not covered'
    } else { $summary.scope += '; synthetic color video, no game injection or audio acceptance' }
    Write-Utf8 (Join-Path $evidence "$Mode-summary.json") ($summary | ConvertTo-Json)
    Write-Host "OBS $($summary.obsVersion) $Mode compatibility PASSED"
} finally {
    if ($null -ne $fixture -and -not $fixture.HasExited) {
        [void]$fixture.CloseMainWindow()
        if (-not $fixture.WaitForExit(3000)) { Stop-Process -Id $fixture.Id -Force; $fixture.WaitForExit() }
    }
    if ($null -ne $process -and -not $process.HasExited) {
        [void]$process.CloseMainWindow()
        if (-not $process.WaitForExit(5000)) { Stop-Process -Id $process.Id -Force; $process.WaitForExit() }
    }
    $logsPath = Join-Path $runtime 'config\obs-studio\logs'
    if (Test-Path $logsPath) {
        Get-ChildItem $logsPath -Filter '*.txt' | ForEach-Object { Copy-Item $_.FullName (Join-Path $evidence "$Mode-obs.log") -Force }
    }
    foreach ($link in $junctions) {
        # Directory.Delete removes the junction itself, never its target.
        if (-not (Get-Item -LiteralPath $link -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw "Unexpected non-junction: $link" }
        [IO.Directory]::Delete($link)
    }
    $full = [IO.Path]::GetFullPath($runtime)
    if ((Split-Path $full -Parent) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and
        (Split-Path $full -Leaf) -like 'obs-compatibility-*') { Remove-Item -LiteralPath $full -Recurse -Force }
}
