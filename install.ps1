<#
.SYNOPSIS
Installs OBS Game Replay Automation into an installed copy of OBS Studio.

.DESCRIPTION
Detects the standard Windows OBS Studio installation, installs the Lua script
and sidecar config, installs the release updater, prompts for the replay output
folder, and migrates the configured Game Capture source to the safe direct-hook
default while OBS is closed. Existing config settings are preserved during
upgrades unless -OverwriteConfig is supplied.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ObsRoot,
    [string]$ScriptsDir,
    [string]$OutputRoot,
    [string]$ObsConfigRoot,
    [switch]$OverwriteConfig,
    [switch]$EnableUpdateChecks,
    [switch]$DisableUpdateChecks,
    [switch]$NoStartMenuShortcut,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $value = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') {
        $value = $value.Substring(1, $value.Length - 2).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Label cannot be empty."
    }
    if (-not [System.IO.Path]::IsPathRooted($value)) {
        throw "$Label must be an absolute path: $value"
    }

    return [System.IO.Path]::GetFullPath($value)
}

function Get-ScriptsDirFromObsRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    return (Join-Path (ConvertTo-AbsolutePath -Path $Root -Label "OBS install folder") "data\obs-plugins\frontend-tools\scripts")
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ProgramFilesRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
        $env:ProgramFiles,
        [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $roots.Add([System.IO.Path]::GetFullPath($candidate)) | Out-Null
        }
    }
    return $roots
}

function Test-IsProgramFilesPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($root in Get-ProgramFilesRoots) {
        $fullRoot = $root.TrimEnd('\')
        if ([string]::Equals($fullPath, $fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if ($fullPath.StartsWith($fullRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Add-ObsRootCandidate {
    param(
        [System.Collections.Generic.List[string]]$Candidates,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    try {
        $fullPath = ConvertTo-AbsolutePath -Path $Path -Label "OBS install folder"
    } catch {
        return
    }

    $obsExecutable = Join-Path $fullPath "bin\64bit\obs64.exe"
    if (-not (Test-Path -LiteralPath $obsExecutable -PathType Leaf)) {
        return
    }

    foreach ($candidate in $Candidates) {
        if ([string]::Equals($candidate, $fullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }
    $Candidates.Add($fullPath) | Out-Null
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-InstalledObsRoots {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $uninstallLocations = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($location in $uninstallLocations) {
        $entries = Get-ItemProperty -Path $location -ErrorAction SilentlyContinue |
            Where-Object { (Get-OptionalPropertyValue -InputObject $_ -Name "DisplayName") -eq "OBS Studio" }
        foreach ($entry in $entries) {
            $installLocation = Get-OptionalPropertyValue -InputObject $entry -Name "InstallLocation"
            $displayIcon = Get-OptionalPropertyValue -InputObject $entry -Name "DisplayIcon"
            $uninstallString = Get-OptionalPropertyValue -InputObject $entry -Name "UninstallString"
            Add-ObsRootCandidate -Candidates $candidates -Path $installLocation

            if (-not [string]::IsNullOrWhiteSpace($displayIcon)) {
                $iconPath = ([string]$displayIcon).Trim().Trim('"')
                $iconPath = ($iconPath -split ",")[0].Trim().Trim('"')
                if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
                    $rootFromIcon = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $iconPath -Parent) "..\.."))
                    Add-ObsRootCandidate -Candidates $candidates -Path $rootFromIcon
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($uninstallString)) {
                $uninstallPath = ([string]$uninstallString).Trim()
                if ($uninstallPath -match '^"([^"]+)"') {
                    $uninstallPath = $Matches[1]
                } else {
                    $uninstallPath = ($uninstallPath -split "\s+")[0]
                }
                if (Test-Path -LiteralPath $uninstallPath -PathType Leaf) {
                    Add-ObsRootCandidate -Candidates $candidates -Path (Split-Path $uninstallPath -Parent)
                }
            }
        }
    }

    foreach ($programFilesRoot in Get-ProgramFilesRoots) {
        Add-ObsRootCandidate -Candidates $candidates -Path (Join-Path $programFilesRoot "obs-studio")
    }
    return $candidates
}

function Get-InstallTarget {
    if (-not [string]::IsNullOrWhiteSpace($ScriptsDir)) {
        return (ConvertTo-AbsolutePath -Path $ScriptsDir -Label "OBS scripts folder")
    }
    if (-not [string]::IsNullOrWhiteSpace($ObsRoot)) {
        $explicitRoot = ConvertTo-AbsolutePath -Path $ObsRoot -Label "OBS install folder"
        if (-not (Test-Path -LiteralPath (Join-Path $explicitRoot "bin\64bit\obs64.exe") -PathType Leaf)) {
            throw "OBS Studio was not found in: $explicitRoot"
        }
        return (Get-ScriptsDirFromObsRoot -Root $explicitRoot)
    }

    $installedRoots = @(Get-InstalledObsRoots)
    if ($installedRoots.Count -eq 1) {
        return (Get-ScriptsDirFromObsRoot -Root $installedRoots[0])
    }
    if ($installedRoots.Count -gt 1) {
        if ($NonInteractive) {
            return (Get-ScriptsDirFromObsRoot -Root $installedRoots[0])
        }

        Write-Host "Multiple installed copies of OBS Studio were found:"
        for ($index = 0; $index -lt $installedRoots.Count; $index++) {
            Write-Host ("  {0}. {1}" -f ($index + 1), $installedRoots[$index])
        }
        do {
            $choice = Read-Host "Choose the OBS installation"
            $selectedIndex = 0
            $validChoice = [int]::TryParse($choice, [ref]$selectedIndex) -and
                $selectedIndex -ge 1 -and
                $selectedIndex -le $installedRoots.Count
            if (-not $validChoice) {
                Write-Warning "Enter a number from 1 to $($installedRoots.Count)."
            }
        } until ($validChoice)
        return (Get-ScriptsDirFromObsRoot -Root $installedRoots[$selectedIndex - 1])
    }

    if ($NonInteractive) {
        throw "No installed copy of OBS Studio was detected. Supply -ObsRoot or -ScriptsDir."
    }

    $defaultObsRoot = Join-Path $env:ProgramFiles "obs-studio"
    Write-Host "No installed copy of OBS Studio was detected automatically."
    $enteredRoot = Read-Host "OBS Studio install folder [$defaultObsRoot]"
    if ([string]::IsNullOrWhiteSpace($enteredRoot)) {
        $enteredRoot = $defaultObsRoot
    }
    $enteredRoot = ConvertTo-AbsolutePath -Path $enteredRoot -Label "OBS install folder"
    if (-not (Test-Path -LiteralPath (Join-Path $enteredRoot "bin\64bit\obs64.exe") -PathType Leaf)) {
        throw "OBS Studio was not found in: $enteredRoot"
    }
    return (Get-ScriptsDirFromObsRoot -Root $enteredRoot)
}

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Restart-Elevated {
    param([Parameter(Mandatory = $true)][string]$ResolvedScriptsDir)

    $hostExecutable = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($hostExecutable)) {
        $hostExecutable = "powershell.exe"
    }

    $commandParts = @(
        "&",
        (ConvertTo-PowerShellLiteral -Value $PSCommandPath),
        "-ScriptsDir", (ConvertTo-PowerShellLiteral -Value $ResolvedScriptsDir)
    )
    if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
        $commandParts += @("-OutputRoot", (ConvertTo-PowerShellLiteral -Value $OutputRoot))
    }
    if (-not [string]::IsNullOrWhiteSpace($ObsConfigRoot)) {
        $commandParts += @("-ObsConfigRoot", (ConvertTo-PowerShellLiteral -Value $ObsConfigRoot))
    }
    if ($OverwriteConfig) {
        $commandParts += "-OverwriteConfig"
    }
    if ($EnableUpdateChecks) {
        $commandParts += "-EnableUpdateChecks"
    }
    if ($DisableUpdateChecks) {
        $commandParts += "-DisableUpdateChecks"
    }
    if ($NoStartMenuShortcut) {
        $commandParts += "-NoStartMenuShortcut"
    }
    if ($NonInteractive) {
        $commandParts += "-NonInteractive"
    }

    $encodedCommand = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes(($commandParts -join " "))
    )
    $arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"

    Write-Host "Administrator permission is required to install into OBS Studio."
    $process = Start-Process -FilePath $hostExecutable -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

function Get-DefaultOutputRoot {
    $videos = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyVideos)
    if ([string]::IsNullOrWhiteSpace($videos)) {
        $videos = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    }
    return (Join-Path $videos "OBS Replays")
}

function Get-ConfiguredOutputRoot {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return $null
    }
    $content = [System.IO.File]::ReadAllText($ConfigPath)
    $matches = [regex]::Matches($content, '(?im)^\s*root_folder\s*=\s*(.*?)\s*$')
    if ($matches.Count -ne 1) {
        return $null
    }
    try {
        return (ConvertTo-AbsolutePath -Path $matches[0].Groups[1].Value -Label "Configured replay output folder")
    } catch {
        return $null
    }
}

function Assert-WritableFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $probe = Join-Path $Path (".obs-game-replay-setup-{0}.tmp" -f [guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::WriteAllText($probe, "write test", [System.Text.UTF8Encoding]::new($false))
    } catch {
        $message = "$Label is not writable from this elevated session: $Path" +
            [Environment]::NewLine + $_.Exception.Message
        throw $message
    } finally {
        if (Test-Path -LiteralPath $probe -PathType Leaf) {
            Remove-Item -LiteralPath $probe -Force
        }
    }
}

function Select-OutputRoot {
    param([string]$ExistingConfigPath)

    if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
        $selected = ConvertTo-AbsolutePath -Path $OutputRoot -Label "Replay output folder"
        Assert-WritableFolder -Path $selected -Label "Replay output folder"
        return $selected
    }

    $defaultRoot = Get-ConfiguredOutputRoot -ConfigPath $ExistingConfigPath
    if ([string]::IsNullOrWhiteSpace($defaultRoot)) {
        $defaultRoot = Get-DefaultOutputRoot
    }
    if ($NonInteractive) {
        $selected = ConvertTo-AbsolutePath -Path $defaultRoot -Label "Replay output folder"
        Assert-WritableFolder -Path $selected -Label "Replay output folder"
        return $selected
    }

    Write-Host ""
    Write-Host "Choose where OBS replay clips should be saved."
    Write-Host "A folder for each detected game will be created inside this location."
    do {
        $entered = Read-Host "Replay output folder [$defaultRoot]"
        if ([string]::IsNullOrWhiteSpace($entered)) {
            $entered = $defaultRoot
        }
        try {
            $selected = ConvertTo-AbsolutePath -Path $entered -Label "Replay output folder"
            Assert-WritableFolder -Path $selected -Label "Replay output folder"
            $valid = $true
        } catch {
            Write-Warning $_.Exception.Message
            $valid = $false
        }
    } until ($valid)
    return $selected
}

function New-ConfigBackup {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $backupPath = "$ConfigPath.bak"
    if (Test-Path -LiteralPath $backupPath) {
        $backupBase = "{0}.bak.{1}" -f $ConfigPath, (Get-Date -Format "yyyyMMdd-HHmmss")
        $backupPath = $backupBase
        $suffix = 1
        while (Test-Path -LiteralPath $backupPath) {
            $backupPath = "$backupBase.$suffix"
            $suffix++
        }
    }
    Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
    return $backupPath
}

function Get-ResolvedObsConfigRoot {
    if (-not [string]::IsNullOrWhiteSpace($ObsConfigRoot)) {
        return (ConvertTo-AbsolutePath -Path $ObsConfigRoot -Label "OBS configuration folder")
    }
    return (Join-Path $env:APPDATA "obs-studio")
}

function Get-ConfiguredGameCaptureSourceName {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $content = [System.IO.File]::ReadAllText($ConfigPath)
    $matches = [regex]::Matches($content, '(?im)^\s*game_capture_source\s*=\s*(.*?)\s*$')
    if ($matches.Count -gt 1) {
        throw "Config contains more than one game_capture_source line: $ConfigPath"
    }
    if ($matches.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($matches[0].Groups[1].Value)) {
        return $matches[0].Groups[1].Value.Trim()
    }
    return "Game Capture"
}

function Set-SafeGameCaptureHookDefaults {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigRoot,
        [Parameter(Mandatory = $true)]
        [string]$GameCaptureSourceName
    )

    $sceneDirectory = Join-Path $ConfigRoot "basic\scenes"
    $backupPaths = [System.Collections.Generic.List[string]]::new()
    $filesUpdated = 0
    $sourcesUpdated = 0
    if (-not (Test-Path -LiteralPath $sceneDirectory -PathType Container)) {
        return [pscustomobject]@{
            SceneDirectory = $sceneDirectory
            FilesUpdated = 0
            SourcesUpdated = 0
            BackupPaths = @()
        }
    }

    foreach ($scenePath in Get-ChildItem -LiteralPath $sceneDirectory -Filter "*.json" -File) {
        try {
            $collection = [System.IO.File]::ReadAllText($scenePath.FullName) | ConvertFrom-Json
        } catch {
            Write-Warning "Skipping unreadable OBS scene collection '$($scenePath.FullName)': $($_.Exception.Message)"
            continue
        }

        $matchingSources = @($collection.sources | Where-Object {
            $_.name -eq $GameCaptureSourceName -and
            ($_.id -eq "game_capture" -or $_.unversioned_id -eq "game_capture")
        })
        $changedInFile = 0
        foreach ($source in $matchingSources) {
            $sourceChanged = $false
            if ($null -eq $source.PSObject.Properties["settings"]) {
                $source | Add-Member -MemberType NoteProperty -Name "settings" -Value ([pscustomobject]@{})
            }
            $hookProperty = $source.settings.PSObject.Properties["anti_cheat_hook"]
            if ($null -eq $hookProperty) {
                $source.settings | Add-Member -MemberType NoteProperty -Name "anti_cheat_hook" -Value $false
                $sourceChanged = $true
            } elseif ([bool]$hookProperty.Value) {
                $hookProperty.Value = $false
                $sourceChanged = $true
            }
            $windowProperty = $source.settings.PSObject.Properties["window"]
            if ($null -ne $windowProperty -and -not [string]::IsNullOrWhiteSpace([string]$windowProperty.Value)) {
                $windowProperty.Value = ""
                $sourceChanged = $true
            }
            if ($sourceChanged) {
                $changedInFile++
            }
        }
        if ($changedInFile -eq 0) {
            continue
        }

        $backupPath = New-ConfigBackup -ConfigPath $scenePath.FullName
        $backupPaths.Add($backupPath) | Out-Null
        try {
            $updatedJson = $collection | ConvertTo-Json -Depth 100
            [System.IO.File]::WriteAllText(
                $scenePath.FullName,
                $updatedJson + [Environment]::NewLine,
                [System.Text.UTF8Encoding]::new($false)
            )
            $verifiedCollection = [System.IO.File]::ReadAllText($scenePath.FullName) | ConvertFrom-Json
            $unsafeSources = @($verifiedCollection.sources | Where-Object {
                $_.name -eq $GameCaptureSourceName -and
                ($_.id -eq "game_capture" -or $_.unversioned_id -eq "game_capture") -and
                ($_.settings.anti_cheat_hook -ne $false -or
                    -not [string]::IsNullOrWhiteSpace([string]$_.settings.window))
            })
            if ($unsafeSources.Count -ne 0) {
                throw "The written scene collection did not retain the safe hook policy and cleared target."
            }
        } catch {
            Copy-Item -LiteralPath $backupPath -Destination $scenePath.FullName -Force
            throw "Could not safely migrate OBS scene collection '$($scenePath.FullName)'; the backup was restored. $($_.Exception.Message)"
        }

        $filesUpdated++
        $sourcesUpdated += $changedInFile
    }

    return [pscustomobject]@{
        SceneDirectory = $sceneDirectory
        FilesUpdated = $filesUpdated
        SourcesUpdated = $sourcesUpdated
        BackupPaths = @($backupPaths)
    }
}

function Copy-FileUnlessSamePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $sourcePath = [System.IO.Path]::GetFullPath($Source)
    $destinationPath = [System.IO.Path]::GetFullPath($Destination)
    if ([string]::Equals($sourcePath, $destinationPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
}

function Get-UpdateTask {
    $taskName = 'Daily Update Check'
    $taskPath = '\OBS Game Replay Automation\'
    return Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
}

function Select-UpdateCheckPreference {
    if ($EnableUpdateChecks -and $DisableUpdateChecks) {
        throw 'Use only one of -EnableUpdateChecks or -DisableUpdateChecks.'
    }
    if ($EnableUpdateChecks) {
        return $true
    }
    if ($DisableUpdateChecks) {
        return $false
    }
    if ($NonInteractive) {
        return $null
    }

    $existingTask = Get-UpdateTask
    $suffix = if ($null -ne $existingTask) { '[Y/n]' } else { '[Y/n]' }
    $answer = Read-Host "Enable a daily GitHub update notification $suffix"
    return -not ($answer -match '^(?i)n(?:o)?$')
}

function Set-UpdateCheckTask {
    param(
        [Parameter(Mandatory = $true)][string]$UpdateScriptPath,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    $taskName = 'Daily Update Check'
    $taskPath = '\OBS Game Replay Automation\'
    if (-not $Enabled) {
        if ($null -ne (Get-UpdateTask)) {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
            return 'disabled'
        }
        return 'disabled (no existing task)'
    }

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $quotedUpdatePath = '"' + $UpdateScriptPath + '"'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $quotedUpdatePath -CheckOnly -Notify -NonInteractive"
    $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments -WorkingDirectory (Split-Path $UpdateScriptPath -Parent)
    $trigger = New-ScheduledTaskTrigger -Daily -At '12:00 PM'
    $principal = New-ScheduledTaskPrincipal `
        -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive `
        -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask `
        -TaskName $taskName `
        -TaskPath $taskPath `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Checks GitHub for stable OBS Game Replay Automation updates and notifies the signed-in user.' `
        -Force | Out-Null
    return 'enabled (daily at 12:00 PM, runs later if missed)'
}

function Install-UpdateShortcut {
    param([Parameter(Mandatory = $true)][string]$LauncherPath)

    try {
        $programsDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
        if ([string]::IsNullOrWhiteSpace($programsDirectory)) {
            throw 'The current user Start Menu folder could not be resolved.'
        }
        $shortcutDirectory = Join-Path $programsDirectory 'OBS Game Replay Automation'
        New-Item -ItemType Directory -Path $shortcutDirectory -Force | Out-Null
        $shortcutPath = Join-Path $shortcutDirectory 'Check for Updates.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $LauncherPath
        $shortcut.WorkingDirectory = Split-Path $LauncherPath -Parent
        $shortcut.Description = 'Check for and install OBS Game Replay Automation updates'
        $shortcut.Save()
        return $shortcutPath
    } catch {
        Write-Warning "The Start Menu update shortcut could not be created: $($_.Exception.Message)"
        return $null
    }
}

function Set-ConfigOutputRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [Parameter(Mandatory = $true)]
        [string]$SelectedOutputRoot,
        [switch]$BackupBeforeWrite
    )

    $content = [System.IO.File]::ReadAllText($ConfigPath)
    $pattern = [regex]::new('(?im)^(?<prefix>[ \t]*root_folder[ \t]*=)[^\r\n]*')
    $matches = $pattern.Matches($content)
    if ($matches.Count -gt 1) {
        throw "Config contains more than one root_folder line: $ConfigPath"
    }

    if ($matches.Count -eq 0) {
        $newLine = [Environment]::NewLine
        $updated = "root_folder=$SelectedOutputRoot" + $newLine + $newLine + $content
    } else {
        $currentValueMatch = [regex]::Match(
            $matches[0].Value,
            '(?i)^[ \t]*root_folder[ \t]*=[ \t]*(?<value>[^\r\n]*)$'
        )
        if ($currentValueMatch.Success) {
            try {
                $currentRoot = ConvertTo-AbsolutePath `
                    -Path $currentValueMatch.Groups['value'].Value `
                    -Label 'Configured replay output folder'
                if ([string]::Equals(
                    $currentRoot.TrimEnd('\'),
                    $SelectedOutputRoot.TrimEnd('\'),
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                    return $null
                }
            } catch {
                # Replace an invalid existing value with the validated selection below.
            }
        }
        $updated = $pattern.Replace(
            $content,
            [System.Text.RegularExpressions.MatchEvaluator]{
                param($match)
                return $match.Groups["prefix"].Value + $SelectedOutputRoot
            },
            1
        )
    }

    if (-not [string]::Equals($content, $updated, [System.StringComparison]::Ordinal)) {
        $backupPath = $null
        if ($BackupBeforeWrite) {
            $backupPath = New-ConfigBackup -ConfigPath $ConfigPath
        }
        [System.IO.File]::WriteAllText($ConfigPath, $updated, [System.Text.UTF8Encoding]::new($false))
        return $backupPath
    }
    return $null
}

$sourceDir = $PSScriptRoot
$scriptSource = Join-Path $sourceDir "game-replay-auto.lua"
$configSource = Join-Path $sourceDir "game-replay-auto-config.txt"
$manifestSource = Join-Path $sourceDir 'manifest.json'
$versionSource = Join-Path $sourceDir 'VERSION'
$updaterSource = Join-Path $sourceDir 'update.ps1'
$updaterLauncherSource = Join-Path $sourceDir 'Update OBS Game Replay Automation.cmd'
foreach ($requiredFile in @(
    $scriptSource,
    $configSource,
    $manifestSource,
    $versionSource,
    $updaterSource,
    $updaterLauncherSource
)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Missing installer file: $requiredFile"
    }
}

Write-Host ""
Write-Host "OBS Game Replay Automation setup"
Write-Host ""

$resolvedScriptsDir = Get-InstallTarget
if ((Test-IsProgramFilesPath -Path $resolvedScriptsDir) -and -not (Test-IsAdministrator)) {
    Restart-Elevated -ResolvedScriptsDir $resolvedScriptsDir
}
if (Get-Process -Name "obs64" -ErrorAction SilentlyContinue) {
    throw "OBS Studio is running. Close OBS completely, then run setup again so the Game Capture hook policy can be migrated safely."
}

$scriptTarget = Join-Path $resolvedScriptsDir "game-replay-auto.lua"
$configTarget = Join-Path $resolvedScriptsDir "game-replay-auto-config.txt"
$manifestTarget = Join-Path $resolvedScriptsDir 'manifest.json'
$versionTarget = Join-Path $resolvedScriptsDir 'VERSION'
$updaterTarget = Join-Path $resolvedScriptsDir 'update.ps1'
$updaterLauncherTarget = Join-Path $resolvedScriptsDir 'Update OBS Game Replay Automation.cmd'
$configExisted = Test-Path -LiteralPath $configTarget -PathType Leaf
$preserveConfigExactly = $configExisted -and
    -not $OverwriteConfig -and
    $NonInteractive -and
    [string]::IsNullOrWhiteSpace($OutputRoot)
$existingConfigBytes = $null
$existingConfigHash = $null
if ($preserveConfigExactly) {
    $existingConfigBytes = [System.IO.File]::ReadAllBytes($configTarget)
    $existingConfigHash = (Get-FileHash -LiteralPath $configTarget -Algorithm SHA256).Hash
}
if ($configExisted -and -not $OverwriteConfig) {
    $existingConfig = [System.IO.File]::ReadAllText($configTarget)
    $existingRootLines = [regex]::Matches($existingConfig, '(?im)^\s*root_folder\s*=')
    if ($existingRootLines.Count -gt 1) {
        throw "Existing config contains more than one root_folder line: $configTarget"
    }
}
$selectedOutputRoot = Select-OutputRoot -ExistingConfigPath $configTarget
$updateCheckPreference = Select-UpdateCheckPreference

New-Item -ItemType Directory -Path $resolvedScriptsDir -Force | Out-Null
Copy-FileUnlessSamePath -Source $scriptSource -Destination $scriptTarget
Copy-FileUnlessSamePath -Source $manifestSource -Destination $manifestTarget
Copy-FileUnlessSamePath -Source $versionSource -Destination $versionTarget
Copy-FileUnlessSamePath -Source $updaterSource -Destination $updaterTarget
Copy-FileUnlessSamePath -Source $updaterLauncherSource -Destination $updaterLauncherTarget

$configBackup = $null
if ($OverwriteConfig -or -not $configExisted) {
    if ($configExisted) {
        $configBackup = New-ConfigBackup -ConfigPath $configTarget
    }
    Copy-FileUnlessSamePath -Source $configSource -Destination $configTarget
}

$setConfigParameters = @{
    ConfigPath = $configTarget
    SelectedOutputRoot = $selectedOutputRoot
    BackupBeforeWrite = ($configExisted -and -not $OverwriteConfig)
}
$rootBackup = Set-ConfigOutputRoot @setConfigParameters
if ([string]::IsNullOrWhiteSpace($configBackup)) {
    $configBackup = $rootBackup
}
if ($preserveConfigExactly) {
    $updatedConfigHash = (Get-FileHash -LiteralPath $configTarget -Algorithm SHA256).Hash
    if ($updatedConfigHash -ne $existingConfigHash) {
        [System.IO.File]::WriteAllBytes($configTarget, $existingConfigBytes)
        throw 'The upgrade attempted to change the existing user configuration. The exact pre-upgrade configuration was restored.'
    }
}

$resolvedObsConfigRoot = Get-ResolvedObsConfigRoot
$gameCaptureSourceName = Get-ConfiguredGameCaptureSourceName -ConfigPath $configTarget
$sceneMigration = Set-SafeGameCaptureHookDefaults `
    -ConfigRoot $resolvedObsConfigRoot `
    -GameCaptureSourceName $gameCaptureSourceName
$updateShortcut = $null
if (-not $NoStartMenuShortcut) {
    $updateShortcut = Install-UpdateShortcut -LauncherPath $updaterLauncherTarget
}
$updateTaskStatus = 'preserved'
if ($null -ne $updateCheckPreference) {
    try {
        $updateTaskStatus = Set-UpdateCheckTask `
            -UpdateScriptPath $updaterTarget `
            -Enabled ([bool]$updateCheckPreference)
    } catch {
        Write-Warning "The daily update notification could not be configured: $($_.Exception.Message)"
        $updateTaskStatus = 'not changed (configuration failed)'
    }
}

Write-Host ""
Write-Host "Installation complete."
Write-Host "  OBS script:    $scriptTarget"
Write-Host "  Config:        $configTarget"
Write-Host "  Version:       $([System.IO.File]::ReadAllText($versionTarget).Trim())"
Write-Host "  Updater:       $updaterLauncherTarget"
Write-Host "  Replay folder: $selectedOutputRoot"
if ($preserveConfigExactly) {
    Write-Host "  Settings:      preserved exactly"
}
Write-Host "  Update checks: $updateTaskStatus"
if (-not [string]::IsNullOrWhiteSpace($updateShortcut)) {
    Write-Host "  Start Menu:    $updateShortcut"
}
if (-not [string]::IsNullOrWhiteSpace($configBackup)) {
    Write-Host "  Config backup: $configBackup"
}
Write-Host "  Hook policy:   direct by default for '$gameCaptureSourceName'"
if ($sceneMigration.FilesUpdated -gt 0) {
    Write-Host "  Scene files:   $($sceneMigration.FilesUpdated) migrated ($($sceneMigration.SourcesUpdated) source(s))"
    foreach ($backupPath in $sceneMigration.BackupPaths) {
        Write-Host "  Scene backup:  $backupPath"
    }
} else {
    Write-Host "  Scene files:   no migration needed"
}
Write-Host ""
Write-Host "Final OBS step:"
Write-Host "  1. Open Tools > Scripts."
Write-Host "  2. Remove any older duplicate copy of game-replay-auto.lua."
Write-Host "  3. Click + and select: $scriptTarget"
