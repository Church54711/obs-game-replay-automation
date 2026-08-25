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

foreach ($path in @($luaPath, $configPath, $readmePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Replay-routing test input is missing: $path"
    }
}

$lua = [System.IO.File]::ReadAllText($luaPath)
$config = [System.IO.File]::ReadAllText($configPath)
$readme = [System.IO.File]::ReadAllText($readmePath)

$requiredLuaPatterns = [ordered]@{
    "root-only profile path" = 'set_obs_output_settings\(effective_output_root,\s*effective_replay_seconds\)'
    "active replay output access" = 'obs\.obs_frontend_get_replay_buffer_output\(\)'
    "game-prefixed replay format" = 'local\s+routed_format\s*=\s*active_game_name\s*\.\.\s*"/"\s*\.\.\s*base_format'
    "replay directory stays at root" = 'obs\.obs_data_set_string\(settings,\s*"directory",\s*active_output_root\)'
    "replay format update" = 'obs\.obs_data_set_string\(settings,\s*"format",\s*routed_format\)'
    "replay output update" = 'obs\.obs_output_update\(replay_buffer,\s*settings\)'
    "replay-start callback" = 'event\s*==\s*obs\.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED'
    "frontend callback registration" = 'obs\.obs_frontend_add_event_callback\(on_frontend_event\)'
    "sidecar exclusion inheritance" = 'parse_excluded_exes\(parsed\.excluded_exes_text,\s*excluded_exes\)'
    "ignored executable state" = 'is_excluded\s*=\s*excluded_exes\[exe\]\s*==\s*true'
    "explicit ignored-app opt-in" = 'info\.is_excluded\s+and\s+not\s+\(override\s*~=\s*nil\s+and\s+override\.enabled\s*==\s*true\)'
}

foreach ($entry in $requiredLuaPatterns.GetEnumerator()) {
    if ($lua -notmatch $entry.Value) {
        throw "Replay-routing test failed: missing $($entry.Key)."
    }
}

if ($lua -match 'CreateDirectoryW|ensure_folder\s*\(') {
    throw "Replay-routing test failed: detection-time directory creation is still present."
}
if ($lua -match 'set_obs_output_settings\(output_folder') {
    throw "Replay-routing test failed: OBS profile output is still pointed at a detection-created game folder."
}

foreach ($exe in @('chatgpt.exe', 'moonlight.exe', 'mpc-hc.exe', 'mpc-hc64.exe', 'snippingtool.exe')) {
    $escaped = [regex]::Escape($exe)
    if ($lua -notmatch ('(?m)^\s*\["{0}"\]\s*=\s*true,?\s*$' -f $escaped)) {
        throw "Replay-routing test failed: Lua defaults do not ignore $exe."
    }
    if ($config -notmatch ('(?im)^\s*{0}\s*$' -f $escaped)) {
        throw "Replay-routing test failed: config defaults do not ignore $exe."
    }
}

if ($readme -notmatch '(?is)folder.*only\s+when\s+a\s+replay\s+is\s+actually\s+saved') {
    throw "Replay-routing test failed: README does not explain lazy folder creation."
}
if ($readme -notmatch '(?is)Tools\s*>\s*Scripts.*sidecar\s+config\s+are\s+merged') {
    throw "Replay-routing test failed: README does not explain merged exclusions."
}

Write-Host "Replay-routing source tests passed."
