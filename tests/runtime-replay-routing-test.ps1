#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [string]$ObsExe = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe',

    [string]$PortableConfigRoot = (Join-Path (Split-Path $ProjectRoot -Parent) 'OBS-Studio-32.1.1-Windows-x64\config\obs-studio'),

    [string]$EvidenceDir = (Join-Path (Split-Path $ProjectRoot -Parent) 'dist\verification\0.5.0-lazy-folder')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    throw $FailureMessage
}

function Stop-TestProcess {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process -or $Process.HasExited) {
        return
    }
    [void]$Process.CloseMainWindow()
    if (-not $Process.WaitForExit(5000)) {
        Stop-Process -Id $Process.Id -Force
        [void]$Process.WaitForExit(5000)
    }
}

$projectFull = [System.IO.Path]::GetFullPath($ProjectRoot)
$obsFull = [System.IO.Path]::GetFullPath($ObsExe)
$portableConfigFull = [System.IO.Path]::GetFullPath($PortableConfigRoot)
$evidenceFull = [System.IO.Path]::GetFullPath($EvidenceDir)

foreach ($requiredPath in @(
    $obsFull,
    (Join-Path $projectFull 'game-replay-auto.lua'),
    (Join-Path $projectFull 'tests\runtime-save-replay.lua'),
    (Join-Path $projectFull 'tests\hook-policy-window-fixture.cs'),
    (Join-Path $portableConfigFull 'global.ini'),
    (Join-Path $portableConfigFull 'user.ini'),
    (Join-Path $portableConfigFull 'basic\profiles\Untitled\basic.ini'),
    (Join-Path $portableConfigFull 'basic\scenes\Untitled.json')
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Runtime replay-routing input is missing: $requiredPath"
    }
}

if (Get-Process -Name obs64 -ErrorAction SilentlyContinue) {
    throw 'Close OBS before running the isolated replay-routing test.'
}

$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempBase ("obs-replay-routing-runtime-{0}" -f [guid]::NewGuid().ToString('N'))
$tempFull = [System.IO.Path]::GetFullPath($tempRoot)
if (-not $tempFull.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -or
    -not [System.IO.Path]::GetFileName($tempFull).StartsWith('obs-replay-routing-runtime-', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use an unexpected runtime test directory: $tempFull"
}

$installedObsRoot = Split-Path (Split-Path (Split-Path $obsFull -Parent) -Parent) -Parent
$runtimeObsRoot = Join-Path $tempFull 'obs-runtime'
$runtimeObsExe = Join-Path $runtimeObsRoot 'bin\64bit\obs64.exe'
$runtimeJunctionPaths = @(
    (Join-Path $runtimeObsRoot 'bin'),
    (Join-Path $runtimeObsRoot 'data'),
    (Join-Path $runtimeObsRoot 'obs-plugins')
)
$obsConfigRoot = Join-Path $runtimeObsRoot 'config\obs-studio'
$scriptsRoot = Join-Path $tempFull 'scripts'
$outputRoot = Join-Path $tempFull 'replays'
$expectedGameFolder = Join-Path $outputRoot 'Lazy Folder Test'
$fixtureExe = Join-Path $tempFull 'obs-hook-policy-fixture.exe'
$obsProcess = $null
$fixtureProcess = $null
$runtimeLog = $null
$folderAbsentBeforeSave = $false
$savedReplay = $null
$testSucceeded = $false
$script:runtimeLog = $null
$script:savedReplay = $null

try {
    New-Item -ItemType Directory -Path $runtimeObsRoot, $obsConfigRoot, $scriptsRoot, $outputRoot -Force | Out-Null
    foreach ($directoryName in @('bin', 'data', 'obs-plugins')) {
        $junctionPath = Join-Path $runtimeObsRoot $directoryName
        $junctionTarget = Join-Path $installedObsRoot $directoryName
        if (-not (Test-Path -LiteralPath $junctionTarget -PathType Container)) {
            throw "Installed OBS runtime directory is missing: $junctionTarget"
        }
        New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $runtimeObsRoot 'portable_mode.txt'),
        '',
        [System.Text.UTF8Encoding]::new($false)
    )
    Copy-Item -LiteralPath (Join-Path $portableConfigFull 'global.ini') -Destination (Join-Path $obsConfigRoot 'global.ini')
    Copy-Item -LiteralPath (Join-Path $portableConfigFull 'user.ini') -Destination (Join-Path $obsConfigRoot 'user.ini')
    Copy-Item -LiteralPath (Join-Path $portableConfigFull 'basic') -Destination $obsConfigRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $projectFull 'game-replay-auto.lua') -Destination (Join-Path $scriptsRoot 'game-replay-auto.lua')
    Copy-Item -LiteralPath (Join-Path $projectFull 'tests\runtime-save-replay.lua') -Destination (Join-Path $scriptsRoot 'runtime-save-replay.lua')

    $outputRootForObs = $outputRoot.Replace('\', '/')
    $testConfig = @(
        "root_folder=$outputRootForObs",
        'game_capture_source=Game Capture',
        'game_audio_source=Game Audio',
        'fullscreen_only=false',
        'fullscreen_min_coverage_percent=98',
        'match_priority=2',
        'stop_replay_buffer_when_game_exits=false',
        'game_exit_stop_delay_seconds=0',
        'default_replay_seconds=5',
        '',
        '[game_folders]',
        'obs-hook-policy-fixture.exe=Lazy Folder Test',
        'chatgpt.exe=Lazy Folder Test',
        'codex.exe=Lazy Folder Test',
        'powershell.exe=Lazy Folder Test',
        'pwsh.exe=Lazy Folder Test',
        '',
        '[game_overrides]',
        'obs-hook-policy-fixture.exe=fullscreen_only=false;enabled=true',
        'chatgpt.exe=fullscreen_only=false;enabled=true',
        'codex.exe=fullscreen_only=false;enabled=true',
        'powershell.exe=fullscreen_only=false;enabled=true',
        'pwsh.exe=fullscreen_only=false;enabled=true',
        '',
        '[ignored_exes]',
        ''
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText(
        (Join-Path $scriptsRoot 'game-replay-auto-config.txt'),
        $testConfig,
        [System.Text.UTF8Encoding]::new($false)
    )

    $profilePath = Join-Path $obsConfigRoot 'basic\profiles\Untitled\basic.ini'
    $profile = [System.IO.File]::ReadAllText($profilePath)
    $profile = [regex]::Replace($profile, '(?m)^Mode=.*$', 'Mode=Simple')
    $profile = [regex]::Replace($profile, '(?m)^FilenameFormatting=.*$', 'FilenameFormatting=%CCYY-%MM/%CCYY-%MM-%DD %hh-%mm-%ss')
    $profile = [regex]::Replace($profile, '(?m)^FilePath=.*$', "FilePath=$outputRootForObs")
    $profile = [regex]::Replace($profile, '(?m)^RecFilePath=.*$', "RecFilePath=$outputRootForObs")
    $profile = [regex]::Replace($profile, '(?m)^FFFilePath=.*$', "FFFilePath=$outputRootForObs")
    $profile = [regex]::Replace($profile, '(?m)^RecFormat2=.*$', 'RecFormat2=mkv')
    $profile = [regex]::Replace($profile, '(?m)^RecEncoder=.*$', 'RecEncoder=x264')
    $profile = [regex]::Replace($profile, '(?m)^RecRBTime=.*$', 'RecRBTime=5')
    [System.IO.File]::WriteAllText($profilePath, $profile, [System.Text.UTF8Encoding]::new($false))

    $scenePath = Join-Path $obsConfigRoot 'basic\scenes\Untitled.json'
    $scene = [System.IO.File]::ReadAllText($scenePath) | ConvertFrom-Json
    $scene.modules.'scripts-tool' = @(
        [pscustomobject]@{
            path = (Join-Path $scriptsRoot 'game-replay-auto.lua').Replace('\', '/')
            settings = [pscustomobject]@{
                output_root = $outputRootForObs
                poll_interval_ms = 500
                minimum_window_area_percent = 0
                fullscreen_only = $false
                stable_poll_count = 1
                start_replay_buffer = $true
                restart_replay_buffer_on_game_change = $true
                stop_replay_buffer_when_game_exits = $false
            }
        },
        [pscustomobject]@{
            path = (Join-Path $scriptsRoot 'runtime-save-replay.lua').Replace('\', '/')
            settings = [pscustomobject]@{}
        }
    )
    [System.IO.File]::WriteAllText(
        $scenePath,
        ($scene | ConvertTo-Json -Depth 100),
        [System.Text.UTF8Encoding]::new($false)
    )

    $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $csc /nologo /target:winexe /optimize+ /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll "/out:$fixtureExe" (Join-Path $projectFull 'tests\hook-policy-window-fixture.cs')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fixtureExe -PathType Leaf)) {
        throw 'Could not compile the runtime foreground-window fixture.'
    }

    $oldCompatibilityLayer = $env:__COMPAT_LAYER
    try {
        # This machine intentionally runs normal OBS sessions elevated. The
        # portable fixture neither needs nor should inherit that AppCompat flag.
        $env:__COMPAT_LAYER = 'RunAsInvoker'
        $obsProcess = Start-Process -FilePath $runtimeObsExe -ArgumentList '--multi', '--disable-shutdown-check', '--minimize-to-tray' -WorkingDirectory (Split-Path $runtimeObsExe -Parent) -WindowStyle Hidden -PassThru
    } finally {
        if ([string]::IsNullOrEmpty($oldCompatibilityLayer)) {
            Remove-Item -LiteralPath Env:\__COMPAT_LAYER -ErrorAction SilentlyContinue
        } else {
            $env:__COMPAT_LAYER = $oldCompatibilityLayer
        }
    }

    $logsRoot = Join-Path $obsConfigRoot 'logs'
    Wait-Until -TimeoutSeconds 20 -FailureMessage 'Isolated OBS did not create a runtime log.' -Condition {
        $script:runtimeLog = Get-ChildItem -LiteralPath $logsRoot -Filter '*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $null -ne $script:runtimeLog
    }
    Wait-Until -TimeoutSeconds 20 -FailureMessage 'The replay automation did not load in isolated OBS.' -Condition {
        (Get-Content -LiteralPath $script:runtimeLog.FullName -Raw -ErrorAction SilentlyContinue) -match 'Loaded lua script: game-replay-auto\.lua'
    }

    $fixtureProcess = Start-Process -FilePath $fixtureExe -PassThru
    Wait-Until -TimeoutSeconds 25 -FailureMessage 'The runtime fixture was not configured as the active game.' -Condition {
        (Get-Content -LiteralPath $script:runtimeLog.FullName -Raw -ErrorAction SilentlyContinue) -match "Configured game replay automation for 'Lazy Folder Test'"
    }
    Wait-Until -TimeoutSeconds 15 -FailureMessage 'The replay buffer did not start for the runtime fixture.' -Condition {
        (Get-Content -LiteralPath $script:runtimeLog.FullName -Raw -ErrorAction SilentlyContinue) -match 'Replay Buffer Start'
    }

    $folderAbsentBeforeSave = -not (Test-Path -LiteralPath $expectedGameFolder)
    if (-not $folderAbsentBeforeSave) {
        throw "The game folder was created before a replay save: $expectedGameFolder"
    }

    Wait-Until -TimeoutSeconds 30 -FailureMessage 'OBS did not save a replay into the lazy-created game folder.' -Condition {
        $script:savedReplay = Get-ChildItem -LiteralPath $expectedGameFolder -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $null -ne $script:savedReplay
    }
    Wait-Until -TimeoutSeconds 10 -FailureMessage 'OBS did not emit the replay-saved frontend event.' -Condition {
        (Get-Content -LiteralPath $script:runtimeLog.FullName -Raw -ErrorAction SilentlyContinue) -match 'Runtime routing fixture observed replay saved\.'
    }

    $logText = Get-Content -LiteralPath $script:runtimeLog.FullName -Raw
    if ($logText -match "\[Lua: game-replay-auto\.lua\].*(error|failed)" -or $logText -match 'Failed to load.*game-replay-auto\.lua') {
        throw 'The runtime OBS log contains a replay-automation Lua failure.'
    }

    $profileAfter = [System.IO.File]::ReadAllText($profilePath)
    if ($profileAfter -match '(?im)^(FilePath|RecFilePath|FFFilePath)=.*Lazy Folder Test') {
        throw 'The OBS profile path was incorrectly persisted to the per-game folder.'
    }

    New-Item -ItemType Directory -Path $evidenceFull -Force | Out-Null
    Copy-Item -LiteralPath $script:runtimeLog.FullName -Destination (Join-Path $evidenceFull 'obs-runtime.log') -Force
    $summary = [ordered]@{
        obs_version = (Get-Item -LiteralPath $runtimeObsExe).VersionInfo.ProductVersion
        folder_absent_before_save = $folderAbsentBeforeSave
        replay_path = $script:savedReplay.FullName
        replay_size_bytes = $script:savedReplay.Length
        replay_sha256 = (Get-FileHash -LiteralPath $script:savedReplay.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        profile_paths_remained_at_root = $true
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $evidenceFull 'summary.json'),
        ($summary | ConvertTo-Json),
        [System.Text.UTF8Encoding]::new($false)
    )

    $testSucceeded = $true
    Write-Host 'Runtime replay-routing test passed.'
    Write-Host "  Folder absent before save: $folderAbsentBeforeSave"
    Write-Host "  Saved replay:              $($script:savedReplay.FullName)"
    Write-Host "  Evidence:                  $evidenceFull"
} finally {
    Stop-TestProcess -Process $fixtureProcess
    Stop-TestProcess -Process $obsProcess

    if (-not $testSucceeded -and $null -ne $script:runtimeLog -and (Test-Path -LiteralPath $script:runtimeLog.FullName -PathType Leaf)) {
        New-Item -ItemType Directory -Path $evidenceFull -Force | Out-Null
        Copy-Item -LiteralPath $script:runtimeLog.FullName -Destination (Join-Path $evidenceFull 'obs-runtime-failure.log') -Force
        Write-Warning "Runtime failure log retained at: $(Join-Path $evidenceFull 'obs-runtime-failure.log')"
    }

    $safeToRemoveTemp = $true
    foreach ($junctionPath in $runtimeJunctionPaths) {
        if (-not (Test-Path -LiteralPath $junctionPath)) {
            continue
        }
        $junction = Get-Item -LiteralPath $junctionPath -Force
        if (-not $junction.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
            Write-Warning "Refusing to remove a runtime path that is not a junction: $junctionPath"
            $safeToRemoveTemp = $false
            continue
        }
        Remove-Item -LiteralPath $junctionPath -Force
    }

    if (Test-Path -LiteralPath $tempFull) {
        $resolvedCleanup = [System.IO.Path]::GetFullPath($tempFull)
        if ($safeToRemoveTemp -and
            $resolvedCleanup.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
            [System.IO.Path]::GetFileName($resolvedCleanup).StartsWith('obs-replay-routing-runtime-', [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedCleanup -Recurse -Force
        } else {
            Write-Warning "Refusing to remove unexpected runtime directory: $resolvedCleanup"
        }
    }
}
