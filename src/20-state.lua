local default_output_root = [[%USERPROFILE%\Videos\OBS Replays]]
local default_game_capture_source = "Game Capture"
local default_game_audio_source = "Game Audio"
local default_anti_cheat_hook = false
local hook_policy_reset_delay_seconds = 5
local default_game_rules = [[hl2.exe|Team Fortress 2=Team Fortress 2
tf_win64.exe=Team Fortress 2
tf.exe=Team Fortress 2]]

local default_excluded_exes = {
	["applicationframehost.exe"] = true,
	["battle.net.exe"] = true,
	["chatgpt.exe"] = true,
	["chrome.exe"] = true,
	["cmd.exe"] = true,
	["codex.exe"] = true,
	["discord.exe"] = true,
	["dwm.exe"] = true,
	["eaapp.exe"] = true,
	["epicgameslauncher.exe"] = true,
	["explorer.exe"] = true,
	["firefox.exe"] = true,
	["galaxyclient.exe"] = true,
	["gog galaxy.exe"] = true,
	["lockapp.exe"] = true,
	["moonlight.exe"] = true,
	["mpc-hc.exe"] = true,
	["mpc-hc64.exe"] = true,
	["msedge.exe"] = true,
	["obs64.exe"] = true,
	["powershell.exe"] = true,
	["pwsh.exe"] = true,
	["searchhost.exe"] = true,
	["shellexperiencehost.exe"] = true,
	["snippingtool.exe"] = true,
	["steam.exe"] = true,
	["steamwebhelper.exe"] = true,
	["systemsettings.exe"] = true,
	["taskmgr.exe"] = true,
	["uplay.exe"] = true,
	["winstore.app.exe"] = true,
}

local game_capture_source = default_game_capture_source
local game_audio_source = default_game_audio_source
local output_root = default_output_root
local poll_interval_ms = 2000
local minimum_window_area_percent = 20
local fullscreen_only = true
local fullscreen_min_coverage_percent = 98
local stable_poll_count = 2
local match_priority = 2
local start_replay_buffer = true
local replay_seconds = nil
local restart_replay_buffer_on_game_change = true
local stop_replay_buffer_when_game_exits = true
local game_exit_stop_delay_seconds = 15
local game_rules = {}
local game_overrides = {}
local excluded_exes = {}
local base_settings = nil
local config_file_path = nil
local config_reload_interval_seconds = 5
local config_last_checked_at = 0
local config_last_raw = nil
local configuration_revision = 0
local profile_default_replay_seconds = nil

local candidate_key = nil
local candidate_count = 0
local active_process_key = nil
local active_window_key = nil
local active_game_name = nil
local active_game_match_title = nil
local active_game_override = nil
local active_identity_config_revision = 0
local active_game_pid = nil
local active_game_exe = nil
local active_game_stop_delay_seconds = nil
local active_window_id = nil
local active_output_root = nil
local active_output_folder = nil
local active_replay_seconds = nil
local active_match_priority = nil
local active_anti_cheat_hook = nil
local game_capture_reapply_not_before = 0
local active_game_capture_source = nil
local active_game_audio_source = nil
local active_game_exit_detected_at = nil
local pending_replay_start_at = 0
local pending_replay_start_until = 0
local replay_routing_base_directory = nil
local replay_routing_base_format = nil
local replay_routing_applied_format = nil
local missing_source_warnings = {}
local last_invalid_output_root = nil
local last_unavailable_output_root = nil
local output_settings_sections = { "SimpleOutput", "AdvOut" }
local process_identities = {}
local identity_last_pruned_at = 0
local config_pending_raw = nil
local config_last_error = nil
local replay_state = { owned = false, starting = false, stopping = false, expected_stop = false,
	paused_process = nil, ready = false, profile_changing = false }
local profile_changes = {}
local controls = { paused = false, ignored = {}, overrides = {}, hotkeys = {},
    message = "Waiting for a game", last_saved = "", notice = "", disk_cache = {},
    sound = false, low_space_gib = 5, fallback_root = "", settings = nil }
local user_store = { initialized = false, ready = false, disk_json = nil, error = nil, disabled = false }
