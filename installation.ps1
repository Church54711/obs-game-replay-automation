# Shared installation metadata used by ZIP setup, EXE setup, and the updater.
# This file only defines functions; importing it never modifies an installation.
function ConvertTo-ReplayAbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)' -or $Path -match '["\r\n]') {
        throw "Expected an absolute installation path: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -eq [IO.Path]::GetPathRoot($full)) { return $full }
    return $full.TrimEnd('\', '/')
}

function Read-ReplayInstallation {
    param([Parameter(Mandatory = $true)][string]$ScriptsDir)
    $ScriptsDir = ConvertTo-ReplayAbsolutePath $ScriptsDir
    $path = Join-Path $ScriptsDir 'game-replay-installation.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $record = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($record.schemaVersion -ne 1 -or $record.product -ne 'obs-game-replay-automation') {
        throw "Unsupported installation record: $path"
    }
    foreach ($key in @('scriptsDir', 'obsConfigRoot', 'settingsDir')) {
        $record.$key = ConvertTo-ReplayAbsolutePath ([string]$record.$key)
    }
    if ($record.scriptsDir -ine $ScriptsDir) { throw 'Installation record points to a different scripts folder.' }
    if (-not [string]::IsNullOrWhiteSpace([string]$record.setupAppDir)) {
        $record.setupAppDir = ConvertTo-ReplayAbsolutePath ([string]$record.setupAppDir)
    }
    return $record
}

function Get-ReplayUpdateCommand {
    param([Parameter(Mandatory = $true)][string]$InstallerPath,
          [Parameter(Mandatory = $true)][string]$ScriptsDir,
          [switch]$NoStartMenuShortcut)
    $quote = { param($value) "'" + ([string]$value).Replace("'", "''") + "'" }
    $command = '& ' + (& $quote $InstallerPath) + ' -ScriptsDir ' + (& $quote $ScriptsDir) + ' -NonInteractive'
    $record = Read-ReplayInstallation $ScriptsDir
    if ($null -ne $record) {
        foreach ($pair in @(@('ObsConfigRoot','obsConfigRoot'), @('SettingsDir','settingsDir'), @('SetupAppDir','setupAppDir'))) {
            $value = [string]$record.($pair[1])
            if (-not [string]::IsNullOrWhiteSpace($value)) { $command += ' -' + $pair[0] + ' ' + (& $quote $value) }
        }
    }
    if ($NoStartMenuShortcut) { $command += ' -NoStartMenuShortcut' }
    return $command
}

function Find-ReplayLegacySetup {
    param([Parameter(Mandatory = $true)][string]$ScriptsDir)
    $found = @()
    foreach ($hive in @('HKCU:', 'HKLM:')) {
        $key = "$hive\Software\Microsoft\Windows\CurrentVersion\Uninstall\{A8DA1B8E-15F0-460D-A8EF-59B198B94FEC}_is1"
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $entry = Get-ItemProperty -LiteralPath $key
        if ($entry.DisplayName -ne 'OBS Game Replay Automation') { continue }
        $appDir = ConvertTo-ReplayAbsolutePath $entry.InstallLocation
        $inventory = Join-Path $appDir 'deployment-state.json'
        if (-not (Test-Path -LiteralPath $inventory -PathType Leaf)) { continue }
        $state = [IO.File]::ReadAllText($inventory) | ConvertFrom-Json
        if ($state.product -ne 'obs-game-replay-automation' -or $state.schemaVersion -ne 1 -or
            (ConvertTo-ReplayAbsolutePath $state.scriptsDir) -ine $ScriptsDir) { continue }
        if ($null -ne $state.PSObject.Properties['runtimeInstalled'] -and -not $state.runtimeInstalled) { continue }
        $config = ConvertTo-ReplayAbsolutePath $state.obsConfigRoot
        $found += [pscustomobject]@{obsConfigRoot=$config; settingsDir=(Join-Path $config 'game-replay-automation'); setupAppDir=$appDir}
    }
    if ($found.Count -gt 1) { throw 'Multiple Setup inventories own this script folder. Repair the duplicate installation first.' }
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

function Sync-ReplayInstalledAppsVersion {
    param([string]$AppDir, [string]$Version)
    if ([string]::IsNullOrWhiteSpace($AppDir)) { return }
    foreach ($hive in @('HKCU:', 'HKLM:')) {
        $key = "$hive\Software\Microsoft\Windows\CurrentVersion\Uninstall\{A8DA1B8E-15F0-460D-A8EF-59B198B94FEC}_is1"
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $entry = Get-ItemProperty -LiteralPath $key
        if ($entry.DisplayName -eq 'OBS Game Replay Automation' -and
            (ConvertTo-ReplayAbsolutePath $entry.InstallLocation) -ieq $AppDir) {
            Set-ItemProperty -LiteralPath $key -Name DisplayVersion -Value $Version
        }
    }
}
