obs = obslua

-- Check capabilities rather than rejecting newer OBS version numbers.
-- If an API disappears, leave profiles, sources and replay buffers untouched.
local compatibility_error = nil
local required_obs_functions = {
	"calldata_create",
	"calldata_destroy",
	"calldata_string",
	"config_get_bool",
	"config_get_int",
	"config_get_string",
	"config_has_user_value",
	"config_remove_value",
	"config_save",
	"config_set_bool",
	"config_set_int",
	"config_set_string",
	"obs_data_addref",
	"obs_data_array_release",
	"obs_data_get_array",
	"obs_data_get_bool",
	"obs_data_get_int",
	"obs_data_get_string",
	"obs_data_release",
	"obs_data_set_array",
	"obs_data_set_bool",
	"obs_data_set_default_bool",
	"obs_data_set_default_int",
	"obs_data_set_default_string",
	"obs_data_set_int",
	"obs_data_set_string",
	"obs_enum_sources",
	"obs_frontend_add_event_callback",
	"obs_frontend_get_current_profile",
	"obs_frontend_get_profile_config",
	"obs_frontend_get_replay_buffer_output",
	"obs_frontend_remove_event_callback",
	"obs_frontend_replay_buffer_active",
	"obs_frontend_replay_buffer_save",
	"obs_frontend_replay_buffer_start",
	"obs_frontend_replay_buffer_stop",
	"obs_get_source_by_name",
	"obs_hotkey_load",
	"obs_hotkey_register_frontend",
	"obs_hotkey_save",
	"obs_hotkey_unregister",
	"obs_output_get_proc_handler",
	"obs_output_get_settings",
	"obs_output_release",
	"obs_output_update",
	"obs_properties_add_bool",
	"obs_properties_add_button",
	"obs_properties_add_int",
	"obs_properties_add_list",
	"obs_properties_add_path",
	"obs_properties_add_text",
	"obs_properties_create",
	"obs_properties_get",
	"obs_property_list_add_string",
	"obs_property_set_description",
	"obs_source_get_name",
	"obs_source_get_settings",
	"obs_source_get_unversioned_id",
	"obs_source_release",
	"obs_source_removed",
	"obs_source_update",
	"proc_handler_call",
	"script_log",
	"source_list_release",
	"timer_add",
	"timer_remove",
}
for _, name in ipairs(required_obs_functions) do
	if type(obslua[name]) ~= "function" then
		compatibility_error = "Missing OBS Lua API: " .. name
		break
	end
end
for _, name in ipairs({"OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED", "OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED"}) do
	if type(obslua[name]) ~= "number" then compatibility_error = "Missing OBS event: " .. name end
end
local ffi_ok, ffi = pcall(require, "ffi")
local bit_ok, bit = pcall(require, "bit")
if not ffi_ok or not bit_ok or ffi.os ~= "Windows" or ffi.arch ~= "x64" then
	compatibility_error = "Windows x64 OBS with LuaJIT is required"
end
if compatibility_error then
	local message = "Replay automation disabled: " .. compatibility_error .. ". Update the script or use a supported OBS build."
	function script_description() return message end
	if type(obslua.script_log) == "function" then obslua.script_log(obslua.LOG_WARNING, message) end
	return
end


local cdef_ok, cdef_error = pcall(ffi.cdef, [[
typedef void *HWND;
typedef void *HANDLE;
typedef void *HMONITOR;
typedef int BOOL;
typedef unsigned int UINT;
typedef unsigned long DWORD;
typedef long LONG;
typedef struct tagRECT {
	long left;
	long top;
	long right;
	long bottom;
} RECT;
typedef struct tagMONITORINFO {
	DWORD cbSize;
	RECT rcMonitor;
	RECT rcWork;
	DWORD dwFlags;
} MONITORINFO;

HWND GetForegroundWindow(void);
BOOL IsWindowVisible(HWND hWnd);
BOOL IsIconic(HWND hWnd);
int GetWindowTextLengthW(HWND hWnd);
int GetWindowTextW(HWND hWnd, wchar_t *lpString, int nMaxCount);
int GetClassNameW(HWND hWnd, wchar_t *lpClassName, int nMaxCount);
DWORD GetWindowThreadProcessId(HWND hWnd, DWORD *lpdwProcessId);
BOOL GetWindowRect(HWND hWnd, RECT *lpRect);
int GetSystemMetrics(int nIndex);
HMONITOR MonitorFromWindow(HWND hwnd, DWORD dwFlags);
BOOL GetMonitorInfoW(HMONITOR hMonitor, MONITORINFO *lpmi);

HANDLE OpenProcess(DWORD dwDesiredAccess, BOOL bInheritHandle, DWORD dwProcessId);
BOOL CloseHandle(HANDLE hObject);
BOOL QueryFullProcessImageNameW(HANDLE hProcess, DWORD dwFlags, wchar_t *lpExeName, DWORD *lpdwSize);
BOOL GetExitCodeProcess(HANDLE hProcess, DWORD *lpExitCode);
DWORD GetLastError(void);
unsigned long long GetTickCount64(void);
DWORD GetFileAttributesW(const wchar_t *lpFileName);
DWORD ExpandEnvironmentStringsW(const wchar_t *lpSrc, wchar_t *lpDst, DWORD nSize);
int MultiByteToWideChar(UINT CodePage, DWORD dwFlags, const char *lpMultiByteStr, int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
int WideCharToMultiByte(UINT CodePage, DWORD dwFlags, const wchar_t *lpWideCharStr, int cchWideChar, char *lpMultiByteStr, int cbMultiByte, const char *lpDefaultChar, BOOL *lpUsedDefaultChar);
]])

if not cdef_ok and not tostring(cdef_error):find("attempt to redefine", 1, true) then
	error(cdef_error)
end

local user32 = ffi.load("user32")
local kernel32 = ffi.load("kernel32")
local null = ffi.cast("void *", 0)

local CP_UTF8 = 65001
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
local FILE_ATTRIBUTE_DIRECTORY = 0x10
local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
local STILL_ACTIVE = 259
local MONITOR_DEFAULTTONEAREST = 2
local SM_CXSCREEN = 0
local SM_CYSCREEN = 1

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

local function trim(value)
	return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local expand_environment_strings = nil

local function clean_root_path(value)
	value = trim(value)
	if #value >= 2 and value:sub(1, 1) == '"' and value:sub(-1) == '"' then
		value = trim(value:sub(2, -2))
	end
	if expand_environment_strings ~= nil then
		value = expand_environment_strings(value)
	end
	value = value:gsub("/", "\\")
	while #value > 3 and value:match("[\\/]$") do
		value = value:sub(1, -2)
	end
	return value
end

local function is_absolute_windows_path(value)
	value = (value or ""):gsub("/", "\\")
	if value:match("^%a:\\") then
		return true
	end
	return value:match("^\\\\[^\\]+\\[^\\]+") ~= nil
end

local function now_seconds()
	return tonumber(kernel32.GetTickCount64()) / 1000
end

local function config_bool(value)
	value = trim(value):lower()
	if value == "1" or value == "true" or value == "yes" or value == "on" then
		return true
	end
	if value == "0" or value == "false" or value == "no" or value == "off" then
		return false
	end
	return nil
end

local function number_or(value, fallback)
	local number = tonumber(value)
	if number == nil then
		return fallback
	end
	return number
end

local function is_null(value)
	return value == nil or value == null
end

local function copy_default_excluded_exes()
	local values = {}
	for exe, enabled in pairs(default_excluded_exes) do
		values[exe] = enabled
	end
	return values
end

local function sorted_default_excluded_text()
	local values = {}
	for exe, _ in pairs(default_excluded_exes) do
		table.insert(values, exe)
	end
	table.sort(values)
	return table.concat(values, "\n")
end

local function get_config_file_path()
	if config_file_path == nil then
		config_file_path = script_path() .. "game-replay-auto-config.txt"
	end
	return config_file_path
end

local function read_file(path)
	local file = io.open(path, "r")
	if file == nil then
		return nil
	end

	local contents = file:read("*a")
	file:close()
	return contents
end

local function apply_base_settings()
	if base_settings == nil then
		return
	end

	game_capture_source = base_settings.game_capture_source
	game_audio_source = base_settings.game_audio_source
	output_root = base_settings.output_root
	poll_interval_ms = base_settings.poll_interval_ms
	minimum_window_area_percent = base_settings.minimum_window_area_percent
	fullscreen_only = base_settings.fullscreen_only
	fullscreen_min_coverage_percent = base_settings.fullscreen_min_coverage_percent
	stable_poll_count = base_settings.stable_poll_count
	match_priority = base_settings.match_priority
	start_replay_buffer = base_settings.start_replay_buffer
	replay_seconds = base_settings.replay_seconds
	restart_replay_buffer_on_game_change = base_settings.restart_replay_buffer_on_game_change
	stop_replay_buffer_when_game_exits = base_settings.stop_replay_buffer_when_game_exits
	game_exit_stop_delay_seconds = base_settings.game_exit_stop_delay_seconds
	game_rules = base_settings.game_rules
	game_overrides = base_settings.game_overrides
	excluded_exes = base_settings.excluded_exes
end

local function parse_match_expression(value)
	local exe = trim(value or "")
	local title = ""
	local pipe_at = exe:find("|", 1, true)
	if pipe_at ~= nil then
		title = trim(exe:sub(pipe_at + 1)):lower()
		exe = trim(exe:sub(1, pipe_at - 1))
	end
	return exe:lower(), title
end

local function parse_key_values(raw)
	local values = {}
	for part in (raw or ""):gmatch("[^;]+") do
		part = trim(part)
		if part ~= "" then
			local key, value = part:match("^([%w_]+)%s*=%s*(.-)%s*$")
			if key ~= nil then
				values[key:lower()] = trim(value)
			elseif values.folder == nil then
				values.folder = part
			end
		end
	end
	return values
end

local function optional_config_bool(values, key, fallback)
	if values[key] == nil then
		return fallback
	end
	local parsed = config_bool(values[key])
	if parsed == nil then
		return fallback
	end
	return parsed
end

local function parse_game_rules(raw)
	local rules = {}
	for line in (raw or ""):gmatch("[^\r\n]+") do
		line = trim(line)
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local left, name = line:match("^([^=]+)=(.+)$")
			if left ~= nil and name ~= nil then
				left = trim(left)
				name = trim(name)
				local exe, title = parse_match_expression(left)
				if exe ~= "" and name ~= "" then
					table.insert(rules, { exe = exe, title = title, name = name })
				end
			end
		end
	end
	return rules
end

local function parse_game_overrides(raw)
	local overrides = {}
	for line in (raw or ""):gmatch("[^\r\n]+") do
		line = trim(line)
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local left, right = line:match("^([^=]+)=(.+)$")
			if left ~= nil and right ~= nil then
				local exe, title = parse_match_expression(left)
				local values = parse_key_values(right)
				if exe ~= "" then
					table.insert(overrides, {
						exe = exe,
						title = title,
						folder = values.folder,
						root_folder = values.root_folder or values.output_root,
						replay_seconds = tonumber(values.replay_seconds),
						stop_delay_seconds = tonumber(values.stop_delay_seconds),
						match_priority = tonumber(values.match_priority),
						anti_cheat_hook = optional_config_bool(values, "anti_cheat_hook", nil),
						fullscreen_only = optional_config_bool(values, "fullscreen_only", nil),
						enabled = optional_config_bool(values, "enabled", nil),
					})
				end
			end
		end
	end
	return overrides
end

local function parse_excluded_exes(raw, inherited_values)
	local values = copy_default_excluded_exes()
	for exe, enabled in pairs(inherited_values or {}) do
		if enabled then
			values[exe] = true
		end
	end
	for part in (raw or ""):gmatch("[^\r\n,;]+") do
		local exe = trim(part):lower()
		if exe ~= "" then
			values[exe] = true
		end
	end
	return values
end

local function parse_text_config(raw)
	local parsed = {
		game_rules_text = nil,
		game_overrides_text = nil,
		excluded_exes_text = nil,
	}
	local section = ""
	local game_rule_lines = {}
	local game_override_lines = {}
	local excluded_lines = {}
	local saw_game_folders = false
	local saw_game_overrides = false
	local saw_ignored_exes = false

	for line in (raw or ""):gmatch("[^\r\n]+") do
		line = line:gsub("^\239\187\191", "")
		line = trim(line)
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local new_section = line:match("^%[([^%]]+)%]$")
			if new_section ~= nil then
				section = trim(new_section):lower()
				if section == "game_folders" then
					saw_game_folders = true
				elseif section == "game_overrides" then
					saw_game_overrides = true
				elseif section == "ignored_exes" then
					saw_ignored_exes = true
				end
			elseif section == "game_folders" then
				table.insert(game_rule_lines, line)
			elseif section == "game_overrides" then
				table.insert(game_override_lines, line)
			elseif section == "ignored_exes" then
				table.insert(excluded_lines, line)
			else
				local key, value = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
				if key ~= nil then
					key = key:lower()
					value = trim(value)
					if key == "root_folder" or key == "output_root" then
						parsed.output_root = value
					elseif key == "game_capture_source" then
						parsed.game_capture_source = value
					elseif key == "game_audio_source" then
						parsed.game_audio_source = value
					elseif key == "fullscreen_only" then
						parsed.fullscreen_only = config_bool(value)
					elseif key == "fullscreen_min_coverage_percent" then
						parsed.fullscreen_min_coverage_percent = tonumber(value)
					elseif key == "match_priority" then
						parsed.match_priority = tonumber(value)
					elseif key == "replay_seconds" or key == "default_replay_seconds" then
						parsed.replay_seconds = tonumber(value)
					elseif key == "stop_replay_buffer_when_game_exits" then
						parsed.stop_replay_buffer_when_game_exits = config_bool(value)
					elseif key == "game_exit_stop_delay_seconds" then
						parsed.game_exit_stop_delay_seconds = tonumber(value)
					end
				end
			end
		end
	end

	if saw_game_folders then
		parsed.game_rules_text = table.concat(game_rule_lines, "\n")
	end
	if saw_game_overrides then
		parsed.game_overrides_text = table.concat(game_override_lines, "\n")
	end
	if saw_ignored_exes then
		parsed.excluded_exes_text = table.concat(excluded_lines, "\n")
	end

	return parsed
end

local function validate_text_config(raw)
	local section, line_number, meaningful = "", 0, false
	local seen = {}
	local booleans = { fullscreen_only = true, stop_replay_buffer_when_game_exits = true,
		anti_cheat_hook = true, enabled = true }
	local numbers = { fullscreen_min_coverage_percent = {1, 100}, match_priority = {0, 2},
		replay_seconds = {1, 86400}, default_replay_seconds = {1, 86400},
		game_exit_stop_delay_seconds = {0, 86400}, stop_delay_seconds = {0, 86400} }
	local globals = { root_folder = true, output_root = true, game_capture_source = true,
		game_audio_source = true, fullscreen_only = true, fullscreen_min_coverage_percent = true,
		match_priority = true, replay_seconds = true, default_replay_seconds = true,
		stop_replay_buffer_when_game_exits = true, game_exit_stop_delay_seconds = true }
	local overrides = { folder = true, root_folder = true, output_root = true, fullscreen_only = true,
		match_priority = true, replay_seconds = true, stop_delay_seconds = true,
		anti_cheat_hook = true, enabled = true }
	local function valid_value(key, value)
		if booleans[key] then return config_bool(value) ~= nil end
		if numbers[key] then
			local n, bounds = tonumber(value), numbers[key]
			return n ~= nil and n == math.floor(n) and n >= bounds[1] and n <= bounds[2]
		end
		if key == "root_folder" or key == "output_root" then
			return is_absolute_windows_path(clean_root_path(value))
		end
		return trim(value) ~= ""
	end
	for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
		line_number = line_number + 1
		line = trim(line:gsub("^\239\187\191", ""))
		if line ~= "" and line:sub(1, 1) ~= "#" then
			meaningful = true
			local next_section = line:match("^%[([^%]]+)%]$")
			local valid = true
			if next_section then
				section = trim(next_section):lower()
				valid = section == "game_folders" or section == "game_overrides" or section == "ignored_exes"
			elseif section == "ignored_exes" then
				valid = line:lower():match("^[^=|/\\]+%.exe$") ~= nil
			elseif section == "game_folders" or section == "game_overrides" then
				local left, right = line:match("^([^=]+)=(.+)$")
				valid = left ~= nil and trim(right or "") ~= ""
				if valid then
					local exe = parse_match_expression(left)
					valid = exe:match("%.exe$") ~= nil
				end
				if valid and section == "game_overrides" then
					local keys = {}
					for part in right:gmatch("[^;]+") do
						local key, value = trim(part):match("^([%w_]+)%s*=%s*(.-)%s*$")
						if key then
							key = key:lower()
							if not overrides[key] or keys[key] or not valid_value(key, value) then valid = false end
							keys[key] = true
						elseif keys.folder or part:find("=", 1, true) then
							valid = false
						else keys.folder = true end
					end
				end
			else
				local key, value = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
				key = key and key:lower()
				local canonical = key == "output_root" and "root_folder" or key
				if key == "default_replay_seconds" then canonical = "replay_seconds" end
				valid = key ~= nil and globals[key] and not seen[canonical] and valid_value(key, value)
				if canonical then seen[canonical] = true end
			end
			if not valid then return false, "Invalid configuration at line " .. line_number .. ": " .. line end
		end
	end
	return meaningful, meaningful and nil or "Configuration is empty"
end

local function load_text_config(force)
	local now = now_seconds()
	if not force and now - config_last_checked_at < config_reload_interval_seconds then
		return false
	end
	config_last_checked_at = now

	local raw = read_file(get_config_file_path())
	local valid, problem = false, "Cannot read configuration; retaining the last valid settings"
	if raw ~= nil then valid, problem = validate_text_config(raw) end
	if not valid then
		config_pending_raw = nil
		if problem ~= config_last_error then
			obs.script_log(obs.LOG_WARNING, problem .. "; configuration was not replaced.")
			config_last_error = problem
		end
		if not force then return false end
		raw = config_last_raw
		if raw == nil then apply_base_settings(); return false end
	elseif config_last_raw ~= nil and raw ~= config_last_raw and raw ~= config_pending_raw then
		-- Editors may truncate/rewrite the file. Require two identical reads.
		config_pending_raw = raw
		if not force then return false end
		raw = config_last_raw
	else
		config_pending_raw = nil
		config_last_error = nil
	end
	if not force and raw == config_last_raw then return false end

	config_last_raw = raw
	apply_base_settings()

	local parsed = parse_text_config(raw)
	if parsed.output_root ~= nil and clean_root_path(parsed.output_root) ~= "" then
		local parsed_output_root = clean_root_path(parsed.output_root)
		if is_absolute_windows_path(parsed_output_root) then
			output_root = parsed_output_root
			last_invalid_output_root = nil
		elseif parsed_output_root ~= last_invalid_output_root then
			last_invalid_output_root = parsed_output_root
			obs.script_log(obs.LOG_WARNING, "Ignoring non-absolute root_folder path: " .. parsed_output_root)
		end
	end
	if parsed.game_capture_source ~= nil and trim(parsed.game_capture_source) ~= "" then
		game_capture_source = trim(parsed.game_capture_source)
	end
	if parsed.game_audio_source ~= nil and trim(parsed.game_audio_source) ~= "" then
		game_audio_source = trim(parsed.game_audio_source)
	end
	if parsed.fullscreen_only ~= nil then
		fullscreen_only = parsed.fullscreen_only
	end
	if parsed.fullscreen_min_coverage_percent ~= nil then
		fullscreen_min_coverage_percent = math.max(1, math.min(100, parsed.fullscreen_min_coverage_percent))
	end
	if parsed.match_priority ~= nil then
		match_priority = math.max(0, math.min(2, parsed.match_priority))
	end
	if parsed.replay_seconds ~= nil then
		replay_seconds = math.max(1, parsed.replay_seconds)
	end
	if parsed.stop_replay_buffer_when_game_exits ~= nil then
		stop_replay_buffer_when_game_exits = parsed.stop_replay_buffer_when_game_exits
	end
	if parsed.game_exit_stop_delay_seconds ~= nil then
		game_exit_stop_delay_seconds = math.max(0, parsed.game_exit_stop_delay_seconds)
	end
	if parsed.game_rules_text ~= nil then
		game_rules = parse_game_rules(parsed.game_rules_text)
	end
	if parsed.game_overrides_text ~= nil then
		game_overrides = parse_game_overrides(parsed.game_overrides_text)
	end
	if parsed.excluded_exes_text ~= nil then
		-- The sidecar section is documented as extra ignored executables. Keep
		-- exclusions saved in OBS's script settings instead of replacing them.
		excluded_exes = parse_excluded_exes(parsed.excluded_exes_text, excluded_exes)
	end

	configuration_revision = configuration_revision + 1
	return true
end

local function wide_to_utf8(wide)
	if wide == nil then
		return ""
	end

	local needed = kernel32.WideCharToMultiByte(CP_UTF8, 0, wide, -1, nil, 0, nil, nil)
	if needed <= 0 then
		return ""
	end

	local buffer = ffi.new("char[?]", needed)
	kernel32.WideCharToMultiByte(CP_UTF8, 0, wide, -1, buffer, needed, nil, nil)
	return ffi.string(buffer)
end

local function utf8_to_wide(text)
	text = text or ""
	local needed = kernel32.MultiByteToWideChar(CP_UTF8, 0, text, -1, nil, 0)
	if needed <= 0 then
		return nil
	end

	local buffer = ffi.new("wchar_t[?]", needed)
	kernel32.MultiByteToWideChar(CP_UTF8, 0, text, -1, buffer, needed)
	return buffer
end

expand_environment_strings = function(text)
	local wide = utf8_to_wide(text)
	if wide == nil then
		return text or ""
	end

	local needed = tonumber(kernel32.ExpandEnvironmentStringsW(wide, nil, 0))
	if needed <= 0 then
		return text or ""
	end

	local buffer = ffi.new("wchar_t[?]", needed)
	if kernel32.ExpandEnvironmentStringsW(wide, buffer, needed) == 0 then
		return text or ""
	end
	return wide_to_utf8(buffer)
end

default_output_root = clean_root_path(default_output_root)
output_root = default_output_root

local function get_window_title(hwnd)
	local length = tonumber(user32.GetWindowTextLengthW(hwnd))
	if length <= 0 then
		return ""
	end

	local buffer = ffi.new("wchar_t[?]", length + 1)
	user32.GetWindowTextW(hwnd, buffer, length + 1)
	return trim(wide_to_utf8(buffer))
end

local function get_window_class(hwnd)
	local buffer = ffi.new("wchar_t[?]", 256)
	user32.GetClassNameW(hwnd, buffer, 256)
	return trim(wide_to_utf8(buffer))
end

local function get_process_path(pid)
	local handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
	if is_null(handle) then
		return ""
	end

	local path = ""
	local size = ffi.new("DWORD[1]", 32768)
	local buffer = ffi.new("wchar_t[?]", size[0])
	if kernel32.QueryFullProcessImageNameW(handle, 0, buffer, size) ~= 0 then
		path = wide_to_utf8(buffer)
	end
	kernel32.CloseHandle(handle)
	return path
end

local function is_process_still_active(pid)
	if pid == nil then
		return false
	end

	local handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
	if is_null(handle) then
		return false
	end

	local exit_code = ffi.new("DWORD[1]", 0)
	local ok = kernel32.GetExitCodeProcess(handle, exit_code)
	kernel32.CloseHandle(handle)
	return ok ~= 0 and tonumber(exit_code[0]) == STILL_ACTIVE
end

local function basename(path)
	return (path or ""):match("[^\\]+$") or (path or "")
end

local function build_process_identity_key(info)
	return tostring(info.pid) .. "|" .. info.exe:lower()
end

local function build_window_identity_key(info)
	return build_process_identity_key(info) .. "|" .. tostring(info.hwnd)
end

local function active_game_process_is_running()
	if active_game_pid == nil or active_game_exe == nil then
		return false
	end
	if replay_state.identity ~= nil then
		local handle = replay_state.identity.handle
		if handle == nil then return false end
		local code = ffi.new("DWORD[1]", 0)
		return kernel32.GetExitCodeProcess(handle, code) ~= 0 and tonumber(code[0]) == STILL_ACTIVE
	end
	if not is_process_still_active(active_game_pid) then
		return false
	end

	local path = get_process_path(active_game_pid)
	return basename(path):lower() == active_game_exe
end

local function read_profile_replay_seconds_default()
	if profile_default_replay_seconds ~= nil then
		return profile_default_replay_seconds
	end
	if obs.config_get_int == nil then
		return nil
	end

	local config = obs.obs_frontend_get_profile_config()
	if config == nil then
		return nil
	end

	local mode = obs.config_get_string(config, "Output", "Mode")
	local section = mode == "Advanced" and "AdvOut" or "SimpleOutput"
	local seconds = tonumber(obs.config_get_int(config, section, "RecRBTime")) or 0
	if seconds > 0 then profile_default_replay_seconds = seconds end
	return profile_default_replay_seconds
end

local function get_window_rect(hwnd)
	local rect = ffi.new("RECT[1]")
	if user32.GetWindowRect(hwnd, rect) == 0 then
		return nil
	end

	return {
		left = tonumber(rect[0].left),
		top = tonumber(rect[0].top),
		right = tonumber(rect[0].right),
		bottom = tonumber(rect[0].bottom),
	}
end

local function get_monitor_rect(hwnd)
	local monitor = user32.MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)
	if not is_null(monitor) then
		local info = ffi.new("MONITORINFO[1]")
		info[0].cbSize = ffi.sizeof("MONITORINFO")
		if user32.GetMonitorInfoW(monitor, info) ~= 0 then
			return {
				left = tonumber(info[0].rcMonitor.left),
				top = tonumber(info[0].rcMonitor.top),
				right = tonumber(info[0].rcMonitor.right),
				bottom = tonumber(info[0].rcMonitor.bottom),
			}
		end
	end

	local screen_width = math.max(1, tonumber(user32.GetSystemMetrics(SM_CXSCREEN)))
	local screen_height = math.max(1, tonumber(user32.GetSystemMetrics(SM_CYSCREEN)))
	return { left = 0, top = 0, right = screen_width, bottom = screen_height }
end

local function rect_area(rect)
	if rect == nil then
		return 0
	end
	return math.max(0, rect.right - rect.left) * math.max(0, rect.bottom - rect.top)
end

local function intersect_area(a, b)
	if a == nil or b == nil then
		return 0
	end
	local left = math.max(a.left, b.left)
	local top = math.max(a.top, b.top)
	local right = math.min(a.right, b.right)
	local bottom = math.min(a.bottom, b.bottom)
	return math.max(0, right - left) * math.max(0, bottom - top)
end

local function get_window_monitor_coverage_percent(hwnd)
	local window_rect = get_window_rect(hwnd)
	local monitor_rect = get_monitor_rect(hwnd)
	local monitor_area = math.max(1, rect_area(monitor_rect))
	return math.min(100, math.floor((intersect_area(window_rect, monitor_rect) * 100) / monitor_area))
end

local function find_game_override(info)
	if info == nil then
		return nil
	end

	local title_lower = info.title:lower()
	local result = nil
	for _, override in ipairs(game_overrides) do
		if info.exe:lower() == override.exe and (override.title == "" or title_lower:find(override.title, 1, true) ~= nil) then
			result = override
			break
		end
	end
	for _, override in ipairs(controls.overrides) do
		if info.exe:lower() == override.exe and (override.title == "" or title_lower:find(override.title, 1, true)) then
			local merged = {}
			for k, v in pairs(result or {}) do merged[k] = v end
			for k, v in pairs(override) do merged[k] = v end
			return merged
		end
	end
	return result
end

local function get_foreground_game_window()
	local hwnd = user32.GetForegroundWindow()
	if is_null(hwnd) or user32.IsWindowVisible(hwnd) == 0 or user32.IsIconic(hwnd) ~= 0 then
		return nil
	end

	local title = get_window_title(hwnd)
	if title == "" then
		return nil
	end

	local pid = ffi.new("DWORD[1]", 0)
	user32.GetWindowThreadProcessId(hwnd, pid)
	if tonumber(pid[0]) == 0 then
		return nil
	end

	local exe_path = get_process_path(tonumber(pid[0]))
	local exe = basename(exe_path):lower()
	if exe == "" then
		return nil
	end

	local monitor_coverage_percent = get_window_monitor_coverage_percent(hwnd)
	if monitor_coverage_percent < minimum_window_area_percent then
		return nil
	end

	local info = {
		hwnd = hwnd,
		pid = tonumber(pid[0]),
		title = title,
		class_name = get_window_class(hwnd),
		exe = exe,
		exe_path = exe_path,
		is_excluded = excluded_exes[exe] == true,
		area_percent = monitor_coverage_percent,
		is_fullscreen = monitor_coverage_percent >= fullscreen_min_coverage_percent,
	}

	return info
end

local function game_window_is_eligible(info, override)
	if override ~= nil and override.enabled == false then
		return false
	end
	if info.is_excluded and not (override ~= nil and override.enabled == true) then
		return false
	end

	local requires_fullscreen = fullscreen_only
	if override ~= nil and override.fullscreen_only ~= nil then
		requires_fullscreen = override.fullscreen_only
	end
	return not requires_fullscreen or info.is_fullscreen
end

local function strip_title_noise(title)
	title = trim((title or ""):gsub("%s+", " "))
	title = title:gsub("%s+%-%s+[Dd]irect3[Dd].*$", "")
	title = title:gsub("%s+%-%s+[Dd]irect[Xx].*$", "")
	title = title:gsub("%s+%-%s+[Dd][Xx]%d+.*$", "")
	title = title:gsub("%s+%-%s+[Oo]pen[Gg][Ll].*$", "")
	title = title:gsub("%s+%-%s+[Vv]ulkan.*$", "")
	return trim(title)
end

local function truncate_utf8_bytes(value, maximum_bytes)
	if #value <= maximum_bytes then
		return value
	end

	local character_start = maximum_bytes
	while character_start > 0 do
		local byte = value:byte(character_start)
		if byte == nil or byte < 0x80 or byte >= 0xC0 then
			break
		end
		character_start = character_start - 1
	end

	local lead = value:byte(character_start) or 0
	local character_bytes = 1
	if lead >= 0xF0 then
		character_bytes = 4
	elseif lead >= 0xE0 then
		character_bytes = 3
	elseif lead >= 0xC0 then
		character_bytes = 2
	end

	if character_start + character_bytes - 1 > maximum_bytes then
		return value:sub(1, character_start - 1)
	end
	return value:sub(1, maximum_bytes)
end

local function safe_folder_name(value)
	value = trim(value or "")
	value = value:gsub('[<>:"/\\|%?%*]', " ")
	value = value:gsub("[%c]", "")
	value = value:gsub("%s+", " ")
	value = value:gsub("^[%.%s]+", ""):gsub("[%.%s]+$", "")
	local reserved_stem = value:upper():match("^([^%.]+)") or value:upper()
	if reserved_stem == "CON"
		or reserved_stem == "PRN"
		or reserved_stem == "AUX"
		or reserved_stem == "NUL"
		or reserved_stem:match("^COM[1-9]$") ~= nil
		or reserved_stem:match("^LPT[1-9]$") ~= nil
	then
		value = "_" .. value
	end
	return truncate_utf8_bytes(value, 120)
end

local function resolve_game_name(info, override)
	if override ~= nil and override.folder ~= nil then
		local folder = safe_folder_name(override.folder)
		if folder ~= "" then
			return folder
		end
	end

	local title_lower = info.title:lower()
	for _, rule in ipairs(game_rules) do
		if info.exe:lower() == rule.exe and (rule.title == "" or title_lower:find(rule.title, 1, true) ~= nil) then
			local folder = safe_folder_name(rule.name)
			if folder ~= "" then
				return folder
			end
		end
	end

	local folder = safe_folder_name(strip_title_noise(info.title))
	if folder ~= "" then
		return folder
	end

	folder = safe_folder_name((info.exe:gsub("%.[Ee][Xx][Ee]$", "")))
	if folder ~= "" then
		return folder
	end

	return "Unknown Game"
end

local function resolve_game_identity(info)
	local process_key = build_process_identity_key(info)
	local identity = process_identities[process_key]
	if identity ~= nil then
		local code = ffi.new("DWORD[1]", 0)
		if identity.handle == nil or kernel32.GetExitCodeProcess(identity.handle, code) == 0
			or tonumber(code[0]) ~= STILL_ACTIVE then
			if identity.handle ~= nil then kernel32.CloseHandle(identity.handle); identity.handle = nil end
			process_identities[process_key] = nil
			identity = nil
		end
	end
	local match_info = identity or info
	if identity ~= nil and identity.revision == configuration_revision then
		return identity.name, identity.override, process_key
	end
	local override = find_game_override(match_info)
	local name = resolve_game_name(match_info, override)
	if identity ~= nil then
		identity.name, identity.override, identity.revision = name, override, configuration_revision
	end
	return name, override, process_key
end

local function remember_game_identity(info, name, override, process_key)
	local identity = process_identities[process_key]
	if identity == nil then
		local handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, info.pid)
		if is_null(handle) then return nil end
		identity = { title = info.title, exe = info.exe, handle = handle }
		process_identities[process_key] = identity
	end
	identity.name, identity.override, identity.revision = name, override, configuration_revision
	return identity
end

local function prune_game_identities(all)
	if not all and now_seconds() - identity_last_pruned_at < 10 then return end
	identity_last_pruned_at = now_seconds()
	for key, identity in pairs(process_identities) do
		local code = ffi.new("DWORD[1]", 0)
		if all or kernel32.GetExitCodeProcess(identity.handle, code) == 0 or tonumber(code[0]) ~= STILL_ACTIVE then
			kernel32.CloseHandle(identity.handle)
			identity.handle = nil
			process_identities[key] = nil
		end
	end
end

local function directory_exists(path)
	local wide = utf8_to_wide(path)
	if wide == nil then
		return false
	end

	local attributes = tonumber(kernel32.GetFileAttributesW(wide))
	return attributes ~= INVALID_FILE_ATTRIBUTES and bit.band(attributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0
end

local function obs_window_escape(value)
	return (value or ""):gsub("#", "##"):gsub(":", "#3A"):gsub('"', "#22")
end

local function obs_window_unescape(value)
	value = (value or ""):gsub("##", "\1")
	return value:gsub("#3A", ":"):gsub("#22", '"'):gsub("\1", "#")
end

local function build_obs_window_id(info)
	return obs_window_escape(info.title) .. ":" .. obs_window_escape(info.class_name) .. ":" .. obs_window_escape(info.exe)
end

local function warn_source_once(key, message)
	if missing_source_warnings[key] then
		return
	end
	missing_source_warnings[key] = true
	obs.script_log(obs.LOG_WARNING, message)
end

local function synchronize_saved_capture_hook_policy()
	-- A loaded Game Capture source can begin hooking its saved target before
	-- the normal foreground poll. Prepare that saved target while no game is
	-- actively tracked so the first injection uses the correct per-game policy.
	if active_game_pid ~= nil or game_capture_source == nil or game_capture_source == "" then
		return false
	end

	local source = obs.obs_get_source_by_name(game_capture_source)
	if source == nil then
		return false
	end
	if (obs.obs_source_get_unversioned_id(source) or "") ~= "game_capture" then
		obs.obs_source_release(source)
		return false
	end

	local settings = obs.obs_source_get_settings(source)
	local window_id = obs.obs_data_get_string(settings, "window")
	local title, _, exe = window_id:match("^([^:]*):([^:]*):([^:]*)$")
	exe = obs_window_unescape(exe):lower()
	if exe == "" then
		obs.obs_data_release(settings)
		obs.obs_source_release(source)
		return false
	end

	local override = find_game_override({
		exe = exe,
		title = obs_window_unescape(title),
	})
	local desired_anti_cheat_hook = default_anti_cheat_hook
	if override ~= nil and override.anti_cheat_hook ~= nil then
		desired_anti_cheat_hook = override.anti_cheat_hook
	end

	local current_anti_cheat_hook = obs.obs_data_get_bool(settings, "anti_cheat_hook")
	if current_anti_cheat_hook ~= desired_anti_cheat_hook then
		obs.obs_data_set_bool(settings, "anti_cheat_hook", desired_anti_cheat_hook)
		obs.obs_source_update(source, settings)
		obs.script_log(
			obs.LOG_INFO,
			"Prepared saved Game Capture target '"
				.. exe
				.. "' with compatibility hook="
				.. (desired_anti_cheat_hook and "enabled" or "disabled")
		)
	end

	obs.obs_data_release(settings)
	obs.obs_source_release(source)
	return true
end

local function update_capture_source(source_name, window_id, is_game_capture, priority, use_anti_cheat_hook)
	if source_name == nil or source_name == "" then
		return true
	end

	local source = obs.obs_get_source_by_name(source_name)
	if source ~= nil and obs.obs_source_removed(source) then
		obs.obs_source_release(source)
		source = nil
	end
	if source == nil then
		controls.source_warning = "Source '" .. source_name .. "' is missing; waiting for it to return"
		warn_source_once("missing:" .. source_name, "Source '" .. source_name .. "' was not found; the script will keep retrying.")
		return false
	end

	local source_id = obs.obs_source_get_unversioned_id(source) or ""
	local expected_id = is_game_capture and "game_capture" or "wasapi_process_output_capture"
	if source_id ~= expected_id then
		controls.source_warning = "Wrong source type for '" .. source_name .. "': expected " .. expected_id
		warn_source_once(
			"type:" .. source_name,
			"'" .. source_name .. "' is '" .. source_id .. "' instead of the expected '" .. expected_id .. "' source; the script will keep retrying."
		)
		obs.obs_source_release(source)
		return false
	end
	missing_source_warnings["missing:" .. source_name] = nil
	missing_source_warnings["type:" .. source_name] = nil

	local settings = obs.obs_source_get_settings(source)
	local already_matches = obs.obs_data_get_string(settings, "window") == window_id
		and obs.obs_data_get_int(settings, "priority") == priority
		and (not is_game_capture or (obs.obs_data_get_string(settings, "capture_mode") == "window"
			and obs.obs_data_get_bool(settings, "anti_cheat_hook") == use_anti_cheat_hook))
	if already_matches then
		obs.obs_data_release(settings)
		obs.obs_source_release(source)
		return true
	end
	if is_game_capture then
		if game_capture_reapply_not_before > now_seconds() then
			obs.obs_data_release(settings)
			obs.obs_source_release(source)
			return false
		end

		local current_window_id = obs.obs_data_get_string(settings, "window")
		local current_anti_cheat_hook = obs.obs_data_get_bool(settings, "anti_cheat_hook")

		-- OBS does not currently reset an active capture when only
		-- anti_cheat_hook changes. Save the safe policy while clearing the same
		-- target, then wait for OBS's in-flight hook attempt to finish before
		-- the normal retry path reapplies the target.
		if current_window_id == window_id and current_anti_cheat_hook ~= use_anti_cheat_hook then
			obs.obs_data_set_bool(settings, "anti_cheat_hook", use_anti_cheat_hook)
			obs.obs_data_set_string(settings, "window", "")
			obs.obs_source_update(source, settings)
			game_capture_reapply_not_before = now_seconds() + hook_policy_reset_delay_seconds
			obs.obs_data_release(settings)
			obs.obs_source_release(source)
			return false
		end

		game_capture_reapply_not_before = 0
	end

	obs.obs_data_set_string(settings, "window", window_id)
	obs.obs_data_set_int(settings, "priority", priority)
	if is_game_capture then
		obs.obs_data_set_string(settings, "capture_mode", "window")
		obs.obs_data_set_bool(settings, "anti_cheat_hook", use_anti_cheat_hook)
	end
	obs.obs_source_update(source, settings)
	obs.obs_data_release(settings)
	obs.obs_source_release(source)
	return true
end

local function restore_profile_settings()
	if #profile_changes == 0 then return end
	local config = obs.obs_frontend_get_profile_config()
	for _, change in ipairs(profile_changes) do
		if config ~= nil and change.profile == obs.obs_frontend_get_current_profile() then
			local getter, setter = obs["config_get_" .. change.kind], obs["config_set_" .. change.kind]
			if getter(config, change.section, change.key) == change.applied then
				if change.had_user_value == false and obs.config_remove_value ~= nil then
					obs.config_remove_value(config, change.section, change.key)
				else setter(config, change.section, change.key, change.original) end
			end
		end
	end
	profile_changes = {}
	if config ~= nil then obs.config_save(config) end
end

local function set_obs_output_settings(path, replay_seconds)
	local config = obs.obs_frontend_get_profile_config()
	if config == nil then
		obs.script_log(obs.LOG_WARNING, "Could not access the current OBS profile config.")
		return false
	end

	-- OBS reads these shared settings asynchronously when starting a buffer.
	-- Restore them as soon as start finishes; routing lives on the replay output.
	local function set_value(section, key, kind, value)
		local getter, setter = obs["config_get_" .. kind], obs["config_set_" .. kind]
		local original = getter(config, section, key)
		if original == value then return end
		table.insert(profile_changes, { profile = obs.obs_frontend_get_current_profile(),
			section = section, key = key, kind = kind, original = original, applied = value,
			had_user_value = obs.config_has_user_value == nil or obs.config_has_user_value(config, section, key) })
		setter(config, section, key, value)
	end
	set_value("SimpleOutput", "FilePath", "string", path)
	set_value("AdvOut", "RecFilePath", "string", path)
	set_value("AdvOut", "FFFilePath", "string", path)
	for _, section in ipairs(output_settings_sections) do
		set_value(section, "RecRB", "bool", true)
		if replay_seconds ~= nil then
			set_value(section, "RecRBTime", "int", replay_seconds)
		end
	end
	return true
end

local function clear_replay_routing_state()
	replay_routing_base_directory = nil
	replay_routing_base_format = nil
	replay_routing_applied_format = nil
end

local function update_active_replay_routing()
	if active_output_root == nil or active_output_root == "" or active_game_name == nil then
		return false
	end

	local replay_buffer = obs.obs_frontend_get_replay_buffer_output()
	if replay_buffer == nil then
		return false
	end

	local settings = obs.obs_output_get_settings(replay_buffer)
	local current_directory = clean_root_path(obs.obs_data_get_string(settings, "directory"))
	local current_format = obs.obs_data_get_string(settings, "format") or ""

	-- OBS rebuilds these settings whenever the replay buffer starts. A format
	-- different from the one we last applied is therefore the user's clean
	-- filename format and becomes the base for this buffer lifetime.
	if replay_routing_applied_format == nil or current_format ~= replay_routing_applied_format then
		replay_routing_base_directory = current_directory
		replay_routing_base_format = current_format
	end

	local base_format = replay_routing_base_format or ""
	if base_format == "" then
		obs.script_log(obs.LOG_WARNING, "Could not read OBS's replay filename format; per-game replay routing was not applied.")
		obs.obs_data_release(settings)
		obs.obs_output_release(replay_buffer)
		return false
	end

	local routed_format = active_game_name .. "/" .. base_format
	if current_directory ~= active_output_root or current_format ~= routed_format then
		obs.obs_data_set_string(settings, "directory", active_output_root)
		obs.obs_data_set_string(settings, "format", routed_format)
		obs.obs_output_update(replay_buffer, settings)
	end

	replay_routing_applied_format = routed_format
	obs.obs_data_release(settings)
	obs.obs_output_release(replay_buffer)
	return true
end

local function restore_active_replay_routing()
	if replay_routing_applied_format == nil or replay_routing_base_format == nil then
		clear_replay_routing_state()
		return
	end

	local replay_buffer = obs.obs_frontend_get_replay_buffer_output()
	if replay_buffer ~= nil then
		local settings = obs.obs_output_get_settings(replay_buffer)
		local current_format = obs.obs_data_get_string(settings, "format") or ""
		if current_format == replay_routing_applied_format then
			obs.obs_data_set_string(settings, "directory", replay_routing_base_directory or active_output_root or output_root)
			obs.obs_data_set_string(settings, "format", replay_routing_base_format)
			obs.obs_output_update(replay_buffer, settings)
		end
		obs.obs_data_release(settings)
		obs.obs_output_release(replay_buffer)
	end

	clear_replay_routing_state()
end

local clear_active_game_state
local deactivate_active_game

local function stop_owned_replay_buffer()
	if replay_state.owned and obs.obs_frontend_replay_buffer_active() and not replay_state.stopping then
		replay_state.expected_stop = true
		replay_state.stopping = true
		obs.obs_frontend_replay_buffer_stop()
	end
end

local function on_frontend_event(event)
	if controls.on_event then controls.on_event(event) end
	if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED then
		replay_state.owned = replay_state.starting or replay_state.start_requested_for ~= nil
		local requested_for = replay_state.start_requested_for
		replay_state.start_requested_for = nil
		replay_state.starting = false
		replay_state.paused_process = nil
		pending_replay_start_at, pending_replay_start_until = 0, 0
		clear_replay_routing_state()
		if replay_state.ready and active_output_root ~= nil
			and (requested_for == nil or requested_for == active_process_key) then update_active_replay_routing()
		else stop_owned_replay_buffer() end
		restore_profile_settings()
	elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPING then
		if not replay_state.expected_stop then
			replay_state.paused_process = active_process_key
			pending_replay_start_at, pending_replay_start_until = 0, 0
		end
		replay_state.stopping = true
	elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED then
		if not replay_state.expected_stop then replay_state.paused_process = active_process_key end
		replay_state.owned, replay_state.starting, replay_state.stopping, replay_state.expected_stop = false, false, false, false
		replay_state.start_requested_for = nil
		restore_profile_settings()
		clear_replay_routing_state()
	elseif event == obs.OBS_FRONTEND_EVENT_PROFILE_CHANGING then
		replay_state.profile_changing = true
		deactivate_active_game()
		restore_profile_settings()
	elseif event == obs.OBS_FRONTEND_EVENT_PROFILE_CHANGED then
		clear_active_game_state()
		clear_replay_routing_state()
		profile_changes = {}
		profile_default_replay_seconds = nil
		replay_state.paused_process = nil
		replay_state.profile_changing = false
		read_profile_replay_seconds_default()
	end
end

local function maybe_start_pending_replay_buffer()
	local now = now_seconds()
	if replay_state.starting then
		if now > pending_replay_start_until then
			restore_profile_settings()
			replay_state.starting = false
			replay_state.start_requested_for = nil
			replay_state.paused_process = active_process_key
			pending_replay_start_at, pending_replay_start_until = 0, 0
			obs.script_log(obs.LOG_WARNING, "Replay buffer did not start; automatic retries are paused for this game. Start it manually to retry.")
		end
		return
	end
	if pending_replay_start_at <= 0 or now < pending_replay_start_at or replay_state.stopping then return end
	if controls.paused or controls.ignored[active_process_key] then return end
	if not replay_state.ready or replay_state.profile_changing or not start_replay_buffer
		or replay_state.paused_process == active_process_key or not active_game_process_is_running() then return end
	if obs.obs_frontend_replay_buffer_active() then
		pending_replay_start_at, pending_replay_start_until = 0, 0
		return
	end
	local replay_output = obs.obs_frontend_get_replay_buffer_output()
	if replay_output == nil then
		controls.replay_warning = "Enable Replay Buffer in OBS Settings > Output and click Apply"
		warn_source_once("replay-disabled", "Replay output is unavailable. Enable Replay Buffer in OBS Settings > Output and click Apply.")
		return
	end
	obs.obs_output_release(replay_output)
	missing_source_warnings["replay-disabled"] = nil
	controls.replay_warning = nil
	if not set_obs_output_settings(active_output_root, active_replay_seconds) then return end
	-- Set state before the API call: tests and some callbacks can be synchronous.
	replay_state.starting = true
	replay_state.start_requested_for = active_process_key
	pending_replay_start_at, pending_replay_start_until = 0, now + 15
	obs.obs_frontend_replay_buffer_start()
end

local function ensure_replay_buffer_running(folder_changed)
	local active = obs.obs_frontend_replay_buffer_active()
	if replay_state.owned and not active and not replay_state.starting and not replay_state.stopping then
		replay_state.owned = false
		replay_state.paused_process = active_process_key
	end
	if not start_replay_buffer or not replay_state.ready or replay_state.profile_changing then return end
	if replay_state.paused_process == active_process_key then return end
	if active and replay_state.owned and folder_changed and restart_replay_buffer_on_game_change then
		local now = now_seconds()
		pending_replay_start_at = now + 2
		pending_replay_start_until = now + 15
		stop_owned_replay_buffer()
		return
	end
	if not active and not replay_state.starting and pending_replay_start_at <= 0 then
		pending_replay_start_at = now_seconds()
	end
	maybe_start_pending_replay_buffer()
end

clear_active_game_state = function()
	active_process_key = nil
	active_window_key = nil
	active_game_name = nil
	active_game_match_title = nil
	active_game_override = nil
	active_identity_config_revision = 0
	active_game_pid = nil
	active_game_exe = nil
	active_game_stop_delay_seconds = nil
	active_game_exit_detected_at = nil
	active_window_id = nil
	active_output_root = nil
	active_output_folder = nil
	active_replay_seconds = nil
	active_match_priority = nil
	active_anti_cheat_hook = nil
	game_capture_reapply_not_before = 0
	active_game_capture_source = nil
	active_game_audio_source = nil
	pending_replay_start_at = 0
	if not replay_state.starting then pending_replay_start_until = 0 end
	replay_state.ready = false
	replay_state.identity = nil
end

deactivate_active_game = function()
	pending_replay_start_at = 0
	replay_state.ready = false
	stop_owned_replay_buffer()
	for _, name in ipairs({ active_game_capture_source or "", active_game_audio_source or "" }) do
		local source = obs.obs_get_source_by_name(name)
		if source ~= nil then
			local settings = obs.obs_source_get_settings(source)
			if obs.obs_data_get_string(settings, "window") == active_window_id then
				obs.obs_data_set_string(settings, "window", "")
				obs.obs_source_update(source, settings)
			end
			obs.obs_data_release(settings)
			obs.obs_source_release(source)
		end
	end
	restore_active_replay_routing()
	restore_profile_settings()
	clear_active_game_state()
end

local function active_game_is_disabled()
	if active_game_pid == nil then return false end
	local override = find_game_override({ exe = active_game_exe, title = active_game_match_title })
	return (override ~= nil and override.enabled == false)
		or (excluded_exes[active_game_exe] == true and not (override ~= nil and override.enabled == true))
end

local function maybe_stop_replay_buffer_after_game_exit(now)
	if not stop_replay_buffer_when_game_exits then
		return
	end
	if active_game_pid == nil then
		return
	end

	if active_game_process_is_running() then
		active_game_exit_detected_at = nil
		return
	end

	if active_game_exit_detected_at == nil then
		active_game_exit_detected_at = now
	end
	local delay_seconds = active_game_stop_delay_seconds or game_exit_stop_delay_seconds
	if now - active_game_exit_detected_at >= delay_seconds then
		if replay_state.owned and obs.obs_frontend_replay_buffer_active() then
			obs.script_log(obs.LOG_INFO, "Stopped replay buffer because the tracked game process exited.")
		end
		deactivate_active_game()
	end
end

local function configure_for_game(info, game_name, override, process_key, window_key)
	if controls.paused or controls.ignored[process_key] then return end
	local effective_output_root = output_root
	if override ~= nil and override.root_folder ~= nil and clean_root_path(override.root_folder) ~= "" then
		effective_output_root = clean_root_path(override.root_folder)
	end

	if effective_output_root == nil or effective_output_root == "" or not is_absolute_windows_path(effective_output_root) then
		obs.script_log(obs.LOG_WARNING, "Output root must be an absolute Windows path; cannot route replay buffer clips: '" .. (effective_output_root or "") .. "'.")
		deactivate_active_game()
		return
	end
	if not directory_exists(effective_output_root) and controls.fallback_root ~= ""
		and directory_exists(controls.fallback_root) then
		controls.fallback_warning = "Primary destination unavailable; using configured fallback"
		effective_output_root = controls.fallback_root
	else
		controls.fallback_warning = nil
	end
	if not directory_exists(effective_output_root) then
		controls.message = "Replay destination unavailable: " .. effective_output_root
		if effective_output_root ~= last_unavailable_output_root then
			last_unavailable_output_root = effective_output_root
			obs.script_log(obs.LOG_WARNING, "Replay root is unavailable; it must already exist before the replay buffer can save: '" .. effective_output_root .. "'.")
		end
		deactivate_active_game()
		return
	end
	last_unavailable_output_root = nil
	controls.check_storage(effective_output_root)

	local effective_match_priority = match_priority
	if override ~= nil and override.match_priority ~= nil then
		effective_match_priority = math.max(0, math.min(2, override.match_priority))
	end

	local effective_anti_cheat_hook = default_anti_cheat_hook
	if override ~= nil and override.anti_cheat_hook ~= nil then
		effective_anti_cheat_hook = override.anti_cheat_hook
	end

	local effective_stop_delay_seconds = game_exit_stop_delay_seconds
	if override ~= nil and override.stop_delay_seconds ~= nil then
		effective_stop_delay_seconds = math.max(0, override.stop_delay_seconds)
	end

	local effective_replay_seconds = replay_seconds
	if override ~= nil and override.replay_seconds ~= nil then
		effective_replay_seconds = math.max(1, override.replay_seconds)
	end
	if effective_replay_seconds == nil then
		effective_replay_seconds = read_profile_replay_seconds_default()
	end

	local output_folder = effective_output_root .. "\\" .. game_name
	local process_changed = process_key ~= active_process_key
	local window_changed = process_changed or window_key ~= active_window_key
	local window_id = active_window_id
	if window_changed or window_id == nil then
		window_id = build_obs_window_id(info)
	end
	local folder_changed = output_folder ~= active_output_folder
	local output_root_changed = effective_output_root ~= active_output_root
	local replay_seconds_changed = effective_replay_seconds ~= active_replay_seconds
	local capture_settings_changed = window_changed
		or effective_match_priority ~= active_match_priority
		or effective_anti_cheat_hook ~= active_anti_cheat_hook
		or game_capture_source ~= active_game_capture_source
		or game_audio_source ~= active_game_audio_source
	local game_changed = process_changed or game_name ~= active_game_name

	local game_capture_updated = true
	local game_audio_updated = true
	controls.source_warning = nil
	do
		game_capture_updated = update_capture_source(
			game_capture_source,
			window_id,
			true,
			effective_match_priority,
			effective_anti_cheat_hook
		)
		game_audio_updated = update_capture_source(game_audio_source, window_id, false, effective_match_priority, false)
	end

	local capture_configuration_complete = game_capture_updated and game_audio_updated
	if capture_configuration_complete and (folder_changed
		or replay_seconds_changed
		or game_changed
		or capture_settings_changed)
	then
		obs.script_log(
			obs.LOG_INFO,
			"Configured game replay automation for '"
				.. game_name
				.. "': "
				.. info.title
				.. " ["
				.. info.exe
				.. "] -> "
				.. output_folder
				.. "; compatibility hook="
				.. (effective_anti_cheat_hook and "enabled" or "disabled")
		)
	end

	replay_state.identity = remember_game_identity(info, game_name, override, process_key)
	active_game_match_title = replay_state.identity and replay_state.identity.title or info.title
	active_process_key = process_key
	active_window_key = window_key
	active_game_name = game_name
	active_game_override = override
	active_identity_config_revision = configuration_revision
	active_game_pid = info.pid
	active_game_exe = info.exe:lower()
	active_game_stop_delay_seconds = effective_stop_delay_seconds
	active_game_exit_detected_at = nil
	active_window_id = window_id
	active_output_root = effective_output_root
	active_output_folder = output_folder
	active_replay_seconds = effective_replay_seconds
	active_match_priority = effective_match_priority
	if game_capture_updated then
		active_anti_cheat_hook = effective_anti_cheat_hook
	else
		active_anti_cheat_hook = nil
	end
	active_game_capture_source = game_capture_updated and game_capture_source or nil
	active_game_audio_source = game_audio_updated and game_audio_source or nil
	replay_state.ready = capture_configuration_complete
	if not capture_configuration_complete then
		controls.message = "Waiting for Game Capture / Game Audio sources or hook reset"
		pending_replay_start_at = 0
		stop_owned_replay_buffer()
		return
	end
	ensure_replay_buffer_running(folder_changed or output_root_changed or replay_seconds_changed)
	controls.active_info = info
	controls.message = replay_state.paused_process == active_process_key and "Stopped manually - Resume to restart"
		or (obs.obs_frontend_replay_buffer_active() and "Replay buffer active"
		or (start_replay_buffer and "Waiting for replay buffer to start" or "Automatic buffer start disabled"))
	if obs.obs_frontend_replay_buffer_active() then
		update_active_replay_routing()
	end
end

function poll_foreground_game()
	load_text_config()
	prune_game_identities(false)
	controls.check_save_timeout()
	if controls.paused then controls.message = "Automation paused"; return end
	if replay_state.profile_changing then return end
	if active_game_is_disabled() then deactivate_active_game() end
	synchronize_saved_capture_hook_policy()
	if replay_state.starting then maybe_start_pending_replay_buffer() end

	local info = get_foreground_game_window()
	if info and not info.is_excluded and info.exe ~= "obs64.exe" then controls.last_detected = info end
	local now = now_seconds()
	maybe_stop_replay_buffer_after_game_exit(now)
	-- Continue validating the tracked game's sources and storage while the
	-- user is in OBS or another application. No new foreground game is selected.
	if active_game_pid and active_game_process_is_running() and controls.active_info
		and (not info or build_process_identity_key(info) ~= active_process_key) then
		local tracked = controls.active_info
		local name, rule, key = resolve_game_identity(tracked)
		configure_for_game(tracked, name, rule, key, build_window_identity_key(tracked))
	end
	if info == nil then
		candidate_key = nil
		candidate_count = 0
		maybe_stop_replay_buffer_after_game_exit(now)
		return
	end

	local game_name, override, process_key = resolve_game_identity(info)
	if controls.ignored[process_key] then controls.message = "Ignored for this session: " .. info.exe; return end
	if not game_window_is_eligible(info, override) then
		if active_game_pid == nil then
			controls.message = (info.is_excluded or (override and override.enabled == false))
				and ("Excluded: " .. info.exe) or ("Window is not fullscreen: " .. info.exe)
		end
		candidate_key = nil
		candidate_count = 0
		maybe_stop_replay_buffer_after_game_exit(now)
		return
	end

	local new_candidate_key = build_window_identity_key(info)
	if new_candidate_key ~= candidate_key then
		candidate_key = new_candidate_key
		candidate_count = 1
	else
		candidate_count = candidate_count + 1
	end

	if candidate_count < stable_poll_count then
		return
	end

	configure_for_game(info, game_name, override, process_key, new_candidate_key)
end

-- Controls live in OBS script settings; the protected sidecar is never edited.
pcall(ffi.cdef, [[
BOOL GetDiskFreeSpaceExW(const wchar_t *, unsigned long long *, unsigned long long *, unsigned long long *);
BOOL MessageBeep(UINT);
void *ShellExecuteW(void *, const wchar_t *, const wchar_t *, const wchar_t *, const wchar_t *, int);
]])
controls.shell = ffi.load("shell32")

function controls.free_bytes(path)
	local bytes = ffi.new("unsigned long long[1]")
	if kernel32.GetDiskFreeSpaceExW(utf8_to_wide(path), bytes, nil, nil) == 0 then return nil end
	return tonumber(bytes[0])
end

function controls.check_storage(path)
	local cached, now = controls.disk_cache[path], now_seconds()
	if not cached or now - cached.at >= 15 then
		cached = { at = now, bytes = controls.free_bytes(path) }
		controls.disk_cache = { [path] = cached }
		local warning = nil
		if cached.bytes == nil then warning = "Cannot check free space: " .. path
		elseif controls.low_space_gib > 0 and cached.bytes < controls.low_space_gib * 1073741824 then
			warning = string.format("Low space: %.1f GiB free in %s", cached.bytes / 1073741824, path)
		end
		controls.storage_warning = warning
		if warning and warning ~= controls.last_storage_warning then obs.script_log(obs.LOG_WARNING, warning) end
		controls.last_storage_warning = warning
	end
end

function controls.check_save_timeout()
	if controls.save_requested_at and now_seconds() - controls.save_requested_at > 30 then
		controls.save_requested_at = nil
		controls.notice = "Replay save was not confirmed within 30 seconds. Check the destination and OBS log."
		obs.script_log(obs.LOG_WARNING, controls.notice)
	end
end

function controls.on_event(event)
	if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVING then
		controls.save_requested_at = now_seconds()
	elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
		controls.save_requested_at = nil
		local output = obs.obs_frontend_get_replay_buffer_output()
		if output then
			local data = obs.calldata_create()
			local ok = obs.proc_handler_call(obs.obs_output_get_proc_handler(output), "get_last_replay", data)
			local path = ok and obs.calldata_string(data, "path") or ""
			obs.calldata_destroy(data)
			obs.obs_output_release(output)
			if path and path ~= "" then
				controls.last_saved = path
				controls.notice = "Replay saved: " .. path
				obs.script_log(obs.LOG_INFO, controls.notice)
				if controls.sound then user32.MessageBeep(0x40) end
			else
				controls.notice = "OBS confirmed a replay save, but did not supply its path."
			end
		end
	end
end

function controls.pause()
	controls.paused = true
	deactivate_active_game()
	controls.message = "Automation paused"
	return true
end
function controls.resume()
	controls.paused = false
	replay_state.paused_process = nil
	-- Resume also clears session-only ignores; permanent exclusions remain.
	controls.ignored = {}
	candidate_key, candidate_count = nil, 0
	controls.message = "Automation resumed - waiting for a game"
	return true
end
function controls.ignore()
	local info = active_game_pid and controls.active_info or controls.last_detected
	if info then
		controls.ignored[build_process_identity_key(info)] = true
		deactivate_active_game()
		controls.message = "Ignored for this session: " .. info.exe
	else controls.notice = "No game detected yet" end
	return true
end
function controls.save_replay()
	if obs.obs_frontend_replay_buffer_active() then
		if not controls.save_requested_at then
			controls.save_requested_at = now_seconds()
			obs.obs_frontend_replay_buffer_save()
		end
	else controls.notice = "Cannot save: replay buffer is inactive" end
	return true
end
function controls.open_last()
	if controls.last_saved == "" then controls.notice = "No replay has been saved in this session"; return true end
	local attributes = kernel32.GetFileAttributesW(utf8_to_wide(controls.last_saved))
	if attributes == INVALID_FILE_ATTRIBUTES then controls.notice = "Last clip is no longer available"; return true end
	local result = controls.shell.ShellExecuteW(nil, utf8_to_wide("open"), utf8_to_wide(controls.last_saved), nil, nil, 1)
	if tonumber(ffi.cast("intptr_t", result)) <= 32 then controls.notice = "Windows could not open the last clip" end
	return true
end

function controls.status_text()
	local status = controls.paused and "Automation paused" or controls.message
	return status .. "\nGame: " .. (active_game_name or "None")
		.. "\nDestination: " .. (active_output_folder or output_root)
		.. "\nBuffer: " .. (obs.obs_frontend_replay_buffer_active() and "Active" or "Inactive")
		.. "\nLast save: " .. (controls.last_saved ~= "" and controls.last_saved or "None this session")
		.. (controls.storage_warning and ("\n" .. controls.storage_warning) or "")
		.. (controls.fallback_warning and ("\n" .. controls.fallback_warning) or "")
		.. (controls.source_warning and ("\n" .. controls.source_warning) or "")
		.. (controls.replay_warning and ("\n" .. controls.replay_warning) or "")
		.. (config_last_error and ("\n" .. config_last_error) or "")
		.. (controls.notice ~= "" and ("\n" .. controls.notice) or "")
end
function controls.refresh(props)
	local property = obs.obs_properties_get(props, "automation_status")
	if property then obs.obs_property_set_description(property, controls.status_text()) end
	return true
end

function controls.use_current()
	if not controls.settings then return false end
	local info = active_game_pid and controls.active_info or controls.last_detected
	if not info then controls.notice = "Focus a game first, then return to Scripts"; return true end
	local rule = find_game_override(info) or {}
	obs.obs_data_set_string(controls.settings, "editor_exe", info.exe)
	obs.obs_data_set_string(controls.settings, "editor_title", rule.title or ((info.exe == "javaw.exe" or info.exe == "java.exe") and info.title or ""))
	obs.obs_data_set_string(controls.settings, "editor_folder", resolve_game_name(info, rule))
	obs.obs_data_set_int(controls.settings, "editor_seconds", rule.replay_seconds or replay_seconds or 120)
	local require_fullscreen = rule.fullscreen_only
	if require_fullscreen == nil then require_fullscreen = fullscreen_only end
	obs.obs_data_set_bool(controls.settings, "editor_fullscreen", require_fullscreen)
	obs.obs_data_set_bool(controls.settings, "editor_enabled", rule.enabled ~= false)
	return true
end

function controls.apply_editor(remove)
	local settings = controls.settings
	if not settings then return false end
	local exe = trim(obs.obs_data_get_string(settings, "editor_exe")):lower()
	local title = trim(obs.obs_data_get_string(settings, "editor_title")):lower()
	local folder = trim(obs.obs_data_get_string(settings, "editor_folder"))
	local seconds = tonumber(obs.obs_data_get_int(settings, "editor_seconds")) or 0
	if not exe:match("^[%w_ .%-]+%.exe$") or title:find("[\r\n|=;]") then
		controls.notice = "Enter an executable name (game.exe) and a title without |, =, ; or newlines"; return true
	end
	if not remove and (folder == "" or folder:find("[\r\n;=]") or seconds < 1 or seconds > 86400) then
		controls.notice = "Enter a folder name and a replay length from 1 to 86400 seconds"; return true
	end
	local key = exe .. (title ~= "" and ("|" .. title) or "")
	local lines = {}
	for line in (obs.obs_data_get_string(settings, "ui_game_overrides") .. "\n"):gmatch("([^\n]*)\n") do
		local existing = line:match("^([^=]+)=")
		if existing and trim(existing):lower() ~= key then lines[#lines + 1] = line end
	end
	if not remove then
		-- Put specific rules before executable-wide rules. A title match is
		-- especially useful when different games share javaw.exe.
		local line = key .. "=folder=" .. safe_folder_name(folder) .. ";replay_seconds=" .. seconds
			.. ";fullscreen_only=" .. tostring(obs.obs_data_get_bool(settings, "editor_fullscreen"))
			.. ";enabled=" .. tostring(obs.obs_data_get_bool(settings, "editor_enabled"))
		table.insert(lines, title ~= "" and 1 or (#lines + 1), line)
	end
	local raw = table.concat(lines, "\n")
	obs.obs_data_set_string(settings, "ui_game_overrides", raw)
	controls.overrides = parse_game_overrides(raw)
	configuration_revision = configuration_revision + 1
	controls.notice = remove and "Editor rule removed; sidecar rules apply again" or ("Saved settings for " .. key)
	return true
end

function controls.add_properties(props)
	obs.obs_properties_add_text(props, "automation_status", controls.status_text(), obs.OBS_TEXT_INFO)
	obs.obs_properties_add_button(props, "refresh_status", "Refresh status", controls.refresh)
	for _, action in ipairs({{"pause", "Pause automation", controls.pause}, {"resume", "Resume / clear session ignores", controls.resume},
		{"ignore", "Ignore current game for this session", controls.ignore}, {"save", "Save replay now", controls.save_replay},
		{"open", "Open last saved clip", controls.open_last}}) do
		local fn = action[3]
		obs.obs_properties_add_button(props, action[1], action[2], function(p) fn(); return controls.refresh(p) end)
	end
	obs.obs_properties_add_bool(props, "save_sound", "Play a sound after a confirmed replay save")
	obs.obs_properties_add_int(props, "low_space_gib", "Warn below free space (GiB; 0 disables warning)", 0, 10000, 1)
	obs.obs_properties_add_path(props, "fallback_root", "Optional fallback replay folder (blank disables)", obs.OBS_PATH_DIRECTORY, "", nil)
	obs.obs_properties_add_text(props, "editor_help", "Per-game editor (takes priority over matching sidecar values). Focus a game, return here, then choose Use current game. Changes take effect only with Apply.", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_button(props, "use_current", "Use current game", controls.use_current)
	obs.obs_properties_add_text(props, "editor_exe", "Executable", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_text(props, "editor_title", "Optional title contains (for shared executables)", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_text(props, "editor_folder", "Game folder name", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_int(props, "editor_seconds", "Replay length (seconds)", 1, 86400, 1)
	obs.obs_properties_add_bool(props, "editor_fullscreen", "Require fullscreen for this game")
	obs.obs_properties_add_bool(props, "editor_enabled", "Allow this game (overrides exclusions)")
	obs.obs_properties_add_button(props, "apply_game", "Apply game settings", function(p) controls.apply_editor(false); return controls.refresh(p) end)
	obs.obs_properties_add_button(props, "remove_game", "Remove this editor rule", function(p) controls.apply_editor(true); return controls.refresh(p) end)
end

function script_description()
	return "Automatically points the Game Capture and Application Audio Capture sources at the foreground game, routes each saved replay into a per-game folder, and manages the replay buffer. Empty folders are not created merely by detecting a fullscreen app."
end

function script_defaults(settings)
	obs.obs_data_set_default_int(settings, "low_space_gib", 5)
	obs.obs_data_set_default_int(settings, "editor_seconds", 120)
	obs.obs_data_set_default_bool(settings, "editor_fullscreen", true)
	obs.obs_data_set_default_bool(settings, "editor_enabled", true)
	obs.obs_data_set_default_string(settings, "game_capture_source", default_game_capture_source)
	obs.obs_data_set_default_string(settings, "game_audio_source", default_game_audio_source)
	obs.obs_data_set_default_string(settings, "output_root", default_output_root)
	obs.obs_data_set_default_int(settings, "poll_interval_ms", 2000)
	obs.obs_data_set_default_int(settings, "minimum_window_area_percent", 20)
	obs.obs_data_set_default_bool(settings, "fullscreen_only", true)
	obs.obs_data_set_default_int(settings, "fullscreen_min_coverage_percent", 98)
	obs.obs_data_set_default_int(settings, "stable_poll_count", 2)
	obs.obs_data_set_default_int(settings, "match_priority", 2)
	obs.obs_data_set_default_bool(settings, "start_replay_buffer", true)
	obs.obs_data_set_default_bool(settings, "restart_replay_buffer_on_game_change", true)
	obs.obs_data_set_default_bool(settings, "stop_replay_buffer_when_game_exits", true)
	obs.obs_data_set_default_int(settings, "game_exit_stop_delay_seconds", 15)
	obs.obs_data_set_default_string(settings, "game_rules", default_game_rules)
	obs.obs_data_set_default_string(settings, "excluded_exes", sorted_default_excluded_text())
end

function script_properties()
	local props = obs.obs_properties_create()
	controls.add_properties(props)

	local game_capture_prop = obs.obs_properties_add_list(
		props,
		"game_capture_source",
		"Game Capture source",
		obs.OBS_COMBO_TYPE_EDITABLE,
		obs.OBS_COMBO_FORMAT_STRING
	)
	local game_audio_prop = obs.obs_properties_add_list(
		props,
		"game_audio_source",
		"Application Audio Capture source",
		obs.OBS_COMBO_TYPE_EDITABLE,
		obs.OBS_COMBO_FORMAT_STRING
	)

	local sources = obs.obs_enum_sources()
	if sources ~= nil then
		for _, source in ipairs(sources) do
			local source_id = obs.obs_source_get_unversioned_id(source) or ""
			local name = obs.obs_source_get_name(source)
			if source_id == "game_capture" then
				obs.obs_property_list_add_string(game_capture_prop, name, name)
			elseif source_id == "wasapi_process_output_capture" then
				obs.obs_property_list_add_string(game_audio_prop, name, name)
			end
		end
		obs.source_list_release(sources)
	end

	obs.obs_properties_add_path(props, "output_root", "Root clip folder", obs.OBS_PATH_DIRECTORY, "", default_output_root)
	obs.obs_properties_add_int(props, "poll_interval_ms", "Poll interval (ms)", 500, 10000, 100)
	obs.obs_properties_add_int(props, "minimum_window_area_percent", "Minimum foreground window size (%)", 0, 100, 1)
	obs.obs_properties_add_bool(props, "fullscreen_only", "Only activate for fullscreen games")
	obs.obs_properties_add_int(props, "fullscreen_min_coverage_percent", "Fullscreen monitor coverage (%)", 1, 100, 1)
	obs.obs_properties_add_int(props, "stable_poll_count", "Stable polls before switching", 1, 10, 1)
	obs.obs_properties_add_int(props, "match_priority", "OBS window match priority (0 title, 1 class, 2 exe)", 0, 2, 1)
	obs.obs_properties_add_bool(props, "start_replay_buffer", "Start replay buffer when a game is detected")
	obs.obs_properties_add_bool(props, "restart_replay_buffer_on_game_change", "Restart replay buffer when switching game folders")
	obs.obs_properties_add_bool(props, "stop_replay_buffer_when_game_exits", "Stop replay buffer when tracked game exits")
	obs.obs_properties_add_int(props, "game_exit_stop_delay_seconds", "Game-exit stop delay (seconds)", 0, 3600, 1)
	obs.obs_properties_add_text(props, "game_rules", "Game folder overrides: exe.exe|optional title text=Folder Name", obs.OBS_TEXT_MULTILINE)
	obs.obs_properties_add_text(props, "excluded_exes", "Ignored executable names", obs.OBS_TEXT_MULTILINE)

	return props
end

function script_update(settings)
	obs.obs_data_addref(settings)
	if controls.settings then obs.obs_data_release(controls.settings) end
	controls.settings = settings
	controls.overrides = parse_game_overrides(obs.obs_data_get_string(settings, "ui_game_overrides"))
	configuration_revision = configuration_revision + 1
	controls.sound = obs.obs_data_get_bool(settings, "save_sound")
	controls.low_space_gib = math.max(0, obs.obs_data_get_int(settings, "low_space_gib"))
	controls.disk_cache = {}
	local fallback = clean_root_path(obs.obs_data_get_string(settings, "fallback_root"))
	controls.fallback_root = is_absolute_windows_path(fallback) and fallback or ""
	if fallback ~= "" and controls.fallback_root == "" then controls.notice = "Fallback must be an absolute path; fallback disabled" end
	game_capture_source = trim(obs.obs_data_get_string(settings, "game_capture_source"))
	game_audio_source = trim(obs.obs_data_get_string(settings, "game_audio_source"))
	output_root = clean_root_path(obs.obs_data_get_string(settings, "output_root"))
	if output_root == "" or not is_absolute_windows_path(output_root) then
		if output_root ~= "" then
			obs.script_log(obs.LOG_WARNING, "Root clip folder must be an absolute Windows path; using the default.")
		end
		output_root = default_output_root
	end

	poll_interval_ms = math.max(500, number_or(obs.obs_data_get_int(settings, "poll_interval_ms"), 2000))
	minimum_window_area_percent = math.max(0, math.min(100, number_or(obs.obs_data_get_int(settings, "minimum_window_area_percent"), 20)))
	fullscreen_only = obs.obs_data_get_bool(settings, "fullscreen_only")
	fullscreen_min_coverage_percent = math.max(1, math.min(100, number_or(obs.obs_data_get_int(settings, "fullscreen_min_coverage_percent"), 98)))
	stable_poll_count = math.max(1, number_or(obs.obs_data_get_int(settings, "stable_poll_count"), 2))
	match_priority = math.max(0, math.min(2, number_or(obs.obs_data_get_int(settings, "match_priority"), 2)))
	start_replay_buffer = obs.obs_data_get_bool(settings, "start_replay_buffer")
	restart_replay_buffer_on_game_change = obs.obs_data_get_bool(settings, "restart_replay_buffer_on_game_change")
	stop_replay_buffer_when_game_exits = obs.obs_data_get_bool(settings, "stop_replay_buffer_when_game_exits")
	game_exit_stop_delay_seconds = math.max(0, number_or(obs.obs_data_get_int(settings, "game_exit_stop_delay_seconds"), 15))
	game_rules = parse_game_rules(obs.obs_data_get_string(settings, "game_rules"))
	excluded_exes = parse_excluded_exes(obs.obs_data_get_string(settings, "excluded_exes"))
	base_settings = {
		game_capture_source = game_capture_source,
		game_audio_source = game_audio_source,
		output_root = output_root,
		poll_interval_ms = poll_interval_ms,
		minimum_window_area_percent = minimum_window_area_percent,
		fullscreen_only = fullscreen_only,
		fullscreen_min_coverage_percent = fullscreen_min_coverage_percent,
		stable_poll_count = stable_poll_count,
		match_priority = match_priority,
		start_replay_buffer = start_replay_buffer,
		replay_seconds = nil,
		restart_replay_buffer_on_game_change = restart_replay_buffer_on_game_change,
		stop_replay_buffer_when_game_exits = stop_replay_buffer_when_game_exits,
		game_exit_stop_delay_seconds = game_exit_stop_delay_seconds,
		game_rules = game_rules,
		game_overrides = {},
		excluded_exes = excluded_exes,
	}
	read_profile_replay_seconds_default()
	load_text_config(true)
	if not directory_exists(output_root) and output_root ~= last_unavailable_output_root then
		last_unavailable_output_root = output_root
		obs.script_log(obs.LOG_WARNING, "Replay root is unavailable; it must already exist before the replay buffer can save: '" .. output_root .. "'.")
	end

	obs.timer_remove(poll_foreground_game)
	obs.timer_add(poll_foreground_game, poll_interval_ms)
end

function script_load(settings)
	script_update(settings)
	obs.obs_frontend_add_event_callback(on_frontend_event)
	for _, action in ipairs({{"pause", "Pause replay automation", controls.pause}, {"resume", "Resume replay automation", controls.resume},
		{"ignore", "Ignore current game for this session", controls.ignore}, {"save", "Save replay with confirmation", controls.save_replay},
		{"open", "Open last saved replay", controls.open_last}}) do
		local fn = action[3]
		local callback = function(pressed) if pressed then fn() end end
		local id = obs.obs_hotkey_register_frontend("game_replay_auto_" .. action[1], action[2], callback)
		controls.hotkeys[action[1]] = { id = id, callback = callback }
		local data = obs.obs_data_get_array(settings, "hotkey_" .. action[1])
		obs.obs_hotkey_load(id, data)
		obs.obs_data_array_release(data)
	end
end

function script_save(settings)
	for name, hotkey in pairs(controls.hotkeys) do
		local data = obs.obs_hotkey_save(hotkey.id)
		obs.obs_data_set_array(settings, "hotkey_" .. name, data)
		obs.obs_data_array_release(data)
	end
end

function script_unload()
	obs.timer_remove(poll_foreground_game)
	obs.obs_frontend_remove_event_callback(on_frontend_event)
	restore_active_replay_routing()
	restore_profile_settings()
	prune_game_identities(true)
	for _, hotkey in pairs(controls.hotkeys) do obs.obs_hotkey_unregister(hotkey.callback) end
	controls.hotkeys = {}
	if controls.settings then obs.obs_data_release(controls.settings); controls.settings = nil end
end
