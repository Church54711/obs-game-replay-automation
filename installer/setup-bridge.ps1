#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Check', 'CheckUninstall', 'Install', 'Uninstall')][string]$Action,
    [Parameter(Mandatory = $true)][string]$AppDir,
    [string]$RequestFile,
    [Parameter(Mandatory = $true)][string]$ResultFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$product = 'obs-game-replay-automation'
$utf8 = [Text.UTF8Encoding]::new($false)

function Get-AbsolutePath([string]$Value) {
    if ($Value -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)' -or $Value -match '["\r\n]') {
        throw "An absolute folder path is required: $Value"
    }
    $fullPath = [IO.Path]::GetFullPath($Value)
    if ($fullPath -eq [IO.Path]::GetPathRoot($fullPath)) { return $fullPath }
    return $fullPath.TrimEnd('\', '/')
}
function Assert-ObsClosed {
    if (Get-Process -Name obs64 -ErrorAction SilentlyContinue) {
        throw 'Close OBS Studio completely, then try again. Setup never stops a recording or closes OBS for you.'
    }
}
function Get-Request {
    $request = @{}
    foreach ($line in [IO.File]::ReadAllLines($RequestFile)) {
        if ($line -match '^([^=]+)=(.*)$') { $request[$matches[1]] = $matches[2] }
    }
    foreach ($key in @('ObsRoot', 'ObsConfigRoot', 'ScriptsDir')) {
        $request[$key] = Get-AbsolutePath $request[$key]
    }
    if (-not (Test-Path -LiteralPath (Join-Path $request.ObsRoot 'bin\64bit\obs64.exe') -PathType Leaf)) {
        throw 'Select the OBS installation folder containing bin\64bit\obs64.exe.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $request.ScriptsDir 'game-replay-auto-config.txt') -PathType Leaf)) {
        $request.ReplayRoot = Get-AbsolutePath $request.ReplayRoot
    }
    return $request
}
function Read-State {
    $state = [IO.File]::ReadAllText((Join-Path $AppDir 'deployment-state.json')) | ConvertFrom-Json
    if ($state.product -ne $product -or $state.schemaVersion -ne 1) { throw 'Invalid installation inventory. No files were removed.' }
    $state.scriptsDir = Get-AbsolutePath $state.scriptsDir
    $state.obsConfigRoot = Get-AbsolutePath $state.obsConfigRoot
    return $state
}
function Remove-Installation {
    $state = Read-State
    $scripts = $state.scriptsDir
    $manifestPath = Join-Path $scripts 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        if ($manifest.name -ne $product) { throw 'The installation folder belongs to another product. No files were removed.' }
    } elseif (Test-Path -LiteralPath (Join-Path $scripts 'game-replay-auto.lua')) {
        throw 'The installation manifest is missing. Repair with Setup before uninstalling.'
    }
    # No recursive deletion: scenes, sources, profiles, clips, config, and
    # existing recovery directories are never part of the removal inventory.
    $targets = [Collections.Generic.List[object]]::new()
    foreach ($name in @('game-replay-auto.lua', 'update.ps1', 'Update OBS Game Replay Automation.cmd', 'manifest.json', 'VERSION', 'LICENSE')) {
        $path = Join-Path $scripts $name
        if (Test-Path -LiteralPath $path -PathType Container) { throw "Expected a file, found a directory: $path" }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        # LICENSE is a shared filename in older frontend-tools installations.
        if ($name -eq 'LICENSE' -and (Get-FileHash -LiteralPath $path).Hash -ne $state.licenseHash) { continue }
        $targets.Add([pscustomobject]@{ Path = $path; Content = $null })
    }
    $entryPath = Join-Path $scripts 'game-replay-auto.lua'
    $sceneDirectory = Join-Path $state.obsConfigRoot 'basic\scenes'
    if (Test-Path -LiteralPath $sceneDirectory -PathType Container) {
        foreach ($scene in Get-ChildItem -LiteralPath $sceneDirectory -Filter '*.json' -File) {
            # Fail before mutation on malformed scenes; silently skipping could
            # leave OBS attempting to load a file removed by uninstall.
            $collection = [IO.File]::ReadAllText($scene.FullName) | ConvertFrom-Json
            $modules = $collection.PSObject.Properties['modules']
            if ($null -eq $modules -or $null -eq $modules.Value) { continue }
            $scriptsProperty = $modules.Value.PSObject.Properties['scripts-tool']
            if ($null -eq $scriptsProperty) { continue }
            $kept = @($scriptsProperty.Value | Where-Object {
                $pathProperty = $_.PSObject.Properties['path']
                if ($null -eq $pathProperty) { return $true }
                try { return (Get-AbsolutePath ([string]$pathProperty.Value)) -ine $entryPath }
                catch { return $true }
            })
            if ($kept.Count -eq @($scriptsProperty.Value).Count) { continue }
            $scriptsProperty.Value = $kept
            $targets.Add([pscustomobject]@{ Path = $scene.FullName; Content = ($collection | ConvertTo-Json -Depth 100) + [Environment]::NewLine })
        }
    }
    if ($targets.Count -eq 0) { return }
    $recovery = Join-Path $scripts ('.game-replay-uninstall-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $recovery -Force | Out-Null
    $lock = [IO.File]::Open((Join-Path $scripts '.game-replay-install.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $snapshots = [Collections.Generic.List[object]]::new()
    $mutated = $false
    try {
        foreach ($target in $targets) {
            $probe = [IO.File]::Open($target.Path, 'Open', 'ReadWrite', 'None')
            $probe.Dispose()
            $backup = Join-Path $recovery ([string]$snapshots.Count)
            Copy-Item -LiteralPath $target.Path -Destination $backup
            $snapshots.Add([pscustomobject]@{ Target = $target.Path; Backup = $backup; Hash = (Get-FileHash -LiteralPath $backup).Hash })
        }
        [IO.File]::WriteAllText((Join-Path $recovery 'recovery.json'), ($snapshots.ToArray() | ConvertTo-Json -Depth 5), $utf8)
        $mutated = $true
        foreach ($target in $targets) {
            if ($null -eq $target.Content) { Remove-Item -LiteralPath $target.Path -Force }
            else {
                [IO.File]::WriteAllText($target.Path, $target.Content, $utf8)
                if ([IO.File]::ReadAllText($target.Path) -cne $target.Content) { throw "Scene verification failed: $($target.Path)" }
            }
        }
    } catch {
        $failure = $_
        if ($mutated) {
            foreach ($snapshot in $snapshots) {
                Copy-Item -LiteralPath $snapshot.Backup -Destination $snapshot.Target -Force
                if ((Get-FileHash -LiteralPath $snapshot.Target).Hash -ne $snapshot.Hash) {
                    throw "Uninstall rollback failed. Recovery files: $recovery"
                }
            }
        }
        throw "Uninstall stopped; previous files preserved. $failure"
    } finally { $lock.Dispose() }
    # Only remove a notification task owned by this exact installation.
    $task = Get-ScheduledTask -TaskPath '\OBS Game Replay Automation\' -TaskName 'Daily Update Check' -ErrorAction SilentlyContinue
    if ($null -ne $task -and @($task.Actions | Where-Object {
        $_.Arguments.IndexOf(('"' + (Join-Path $scripts 'update.ps1') + '"'), [StringComparison]::OrdinalIgnoreCase) -ge 0
    }).Count -gt 0) {
        try { $task | Unregister-ScheduledTask -Confirm:$false }
        catch { Write-Warning "Could not remove the update notification task: $_" }
    }
}

try {
    $AppDir = Get-AbsolutePath $AppDir
    Assert-ObsClosed
    if ($Action -eq 'CheckUninstall') { $null = Read-State }
    elseif ($Action -eq 'Uninstall') { Remove-Installation }
    else {
        $request = Get-Request
        $statePath = Join-Path $AppDir 'deployment-state.json'
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $oldState = Read-State
            if ($oldState.scriptsDir -ine $request.ScriptsDir -or $oldState.obsConfigRoot -ine $request.ObsConfigRoot) {
                throw 'This setup already manages another OBS location or configuration folder. Uninstall it before changing those folders; settings and clips will be retained.'
            }
        }
        if ($Action -eq 'Install') {
            $payload = Join-Path $AppDir 'payload'
            $parameters = @{
                ScriptsDir = $request.ScriptsDir
                ObsConfigRoot = $request.ObsConfigRoot
                NonInteractive = $true
                NoStartMenuShortcut = $true
            }
            if (-not (Test-Path -LiteralPath (Join-Path $request.ScriptsDir 'game-replay-auto-config.txt') -PathType Leaf)) {
                $parameters.OutputRoot = $request.ReplayRoot
            }
            if ($request.EnableUpdateChecks -eq '1') { $parameters.EnableUpdateChecks = $true }
            $state = [ordered]@{
                schemaVersion = 1; product = $product; obsRoot = $request.ObsRoot
                scriptsDir = $request.ScriptsDir; obsConfigRoot = $request.ObsConfigRoot
                version = [IO.File]::ReadAllText((Join-Path $payload 'VERSION')).Trim()
                licenseHash = (Get-FileHash -LiteralPath (Join-Path $payload 'LICENSE')).Hash
            }
            # Reserve and flush the inventory before touching the OBS files.
            $pendingState = Join-Path $AppDir 'deployment-state.pending.json'
            [IO.File]::WriteAllText($pendingState, ($state | ConvertTo-Json), $utf8)
            & (Join-Path $payload 'install.ps1') @parameters
            Move-Item -LiteralPath $pendingState -Destination $statePath -Force
        }
    }
    [IO.File]::WriteAllText($ResultFile, 'OK', $utf8)
    exit 0
} catch {
    [IO.File]::WriteAllText($ResultFile, $_.Exception.Message, $utf8)
    Write-Error $_ -ErrorAction Continue
    exit 1
}
