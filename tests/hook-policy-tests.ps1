#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$luaPath = Join-Path $ProjectRoot "game-replay-auto.lua"
$configPath = Join-Path $ProjectRoot "game-replay-auto-config.txt"
$readmePath = Join-Path $ProjectRoot "README.md"
$installerPath = Join-Path $ProjectRoot "install.ps1"

foreach ($path in @($luaPath, $configPath, $readmePath, $installerPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Hook-policy test input is missing: $path"
    }
}

$lua = [System.IO.File]::ReadAllText($luaPath)
$config = [System.IO.File]::ReadAllText($configPath)
$readme = [System.IO.File]::ReadAllText($readmePath)
$installer = [System.IO.File]::ReadAllText($installerPath)

$requiredLuaPatterns = [ordered]@{
    "safe hook default" = 'local\s+default_anti_cheat_hook\s*=\s*false'
    "optional per-game override" = 'anti_cheat_hook\s*=\s*optional_config_bool\(values,\s*"anti_cheat_hook",\s*nil\)'
    "effective default" = 'local\s+effective_anti_cheat_hook\s*=\s*default_anti_cheat_hook'
    "effective override" = 'effective_anti_cheat_hook\s*=\s*override\.anti_cheat_hook'
    "preserve existing source settings" = 'local\s+settings\s*=\s*obs\.obs_source_get_settings\(source\)'
    "explicit OBS setting" = 'obs\.obs_data_set_bool\(settings,\s*"anti_cheat_hook",\s*use_anti_cheat_hook\)'
    "same-target reset" = 'current_window_id\s*==\s*window_id\s+and\s+current_anti_cheat_hook\s*~=\s*use_anti_cheat_hook'
    "safe policy is saved during reset" = '(?s)obs\.obs_data_set_bool\(settings,\s*"anti_cheat_hook",\s*use_anti_cheat_hook\).*?obs\.obs_data_set_string\(settings,\s*"window",\s*""\)'
    "reset retry delay" = 'game_capture_reapply_not_before\s*=\s*now_seconds\(\)\s*\+\s*hook_policy_reset_delay_seconds'
    "reset retries later" = '(?s)game_capture_reapply_not_before\s*=\s*now_seconds\(\)\s*\+\s*hook_policy_reset_delay_seconds.*?return\s+false'
    "active policy comparison" = 'effective_anti_cheat_hook\s*~=\s*active_anti_cheat_hook'
    "false-safe active policy tracking" = 'if\s+game_capture_updated\s+then\s+active_anti_cheat_hook\s*=\s*effective_anti_cheat_hook'
    "completion-gated configuration log" = 'if\s+capture_configuration_complete\s+and\s+\(folder_changed'
    "saved-target policy preparation" = 'local\s+function\s+synchronize_saved_capture_hook_policy\(\)'
    "saved-target per-game override" = 'desired_anti_cheat_hook\s*=\s*override\.anti_cheat_hook'
    "active capture synchronization guard" = 'if\s+active_game_pid\s*~=\s*nil\s+or\s+game_capture_source'
    "poll-time saved policy synchronization" = '(?s)function\s+poll_foreground_game\(\).*?synchronize_saved_capture_hook_policy\(\)'
}

foreach ($entry in $requiredLuaPatterns.GetEnumerator()) {
    if ($lua -notmatch $entry.Value) {
        throw "Hook-policy test failed: missing $($entry.Key)."
    }
}

if ($config -notmatch '(?im)^\s*#\s*protectedgame\.exe=anti_cheat_hook=true\s*$') {
    throw "Hook-policy test failed: config lacks the per-game opt-in example."
}
if ($config -match '(?im)^\s*[^#;\r\n].*=\s*anti_cheat_hook=true\s*$') {
    throw "Hook-policy test failed: config enables the compatibility hook by default."
}
if ($readme -notmatch '(?s)protectedgame\.exe=anti_cheat_hook=true') {
    throw "Hook-policy test failed: README lacks per-game opt-in instructions."
}

$requiredInstallerPatterns = [ordered]@{
    "OBS-closed install gate" = '(?s)Get-Process\s+-Name\s+"obs64".*?Close OBS completely'
    "isolatable OBS config root" = '\[string\]\$ObsConfigRoot'
    "scene source name follows config" = 'Get-ConfiguredGameCaptureSourceName\s+-ConfigPath\s+\$configTarget'
    "scene migration uses a backup" = 'New-ConfigBackup\s+-ConfigPath\s+\$scenePath\.FullName'
    "scene migration safe value" = 'Add-Member\s+-MemberType\s+NoteProperty\s+-Name\s+"anti_cheat_hook"\s+-Value\s+\$false'
    "scene migration clears stale target" = '\$windowProperty\.Value\s*=\s*""'
    "scene migration restores on failure" = 'Copy-Item\s+-LiteralPath\s+\$backupPath\s+-Destination\s+\$scenePath\.FullName\s+-Force'
}
foreach ($entry in $requiredInstallerPatterns.GetEnumerator()) {
    if ($installer -notmatch $entry.Value) {
        throw "Hook-policy test failed: installer is missing $($entry.Key)."
    }
}

Write-Host "Hook-policy source tests passed."
