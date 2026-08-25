obs = obslua

local ffi = require("ffi")
local bit = require("bit")

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

local function load_text_config(force)
	local now = now_seconds()
	if not force and now - config_last_checked_at < config_reload_interval_seconds then
		return false
	end
	config_last_checked_at = now

	local raw = read_file(get_config_file_path())
	if raw == nil then
		if force or config_last_raw ~= nil then
			config_last_raw = nil
			apply_base_settings()
			configuration_revision = configuration_revision + 1
			return true
		end
		return false
	end

	if not force and raw == config_last_raw then
		return false
	end

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

	local simple_seconds = tonumber(obs.config_get_int(config, "SimpleOutput", "RecRBTime")) or 0
	local advanced_seconds = tonumber(obs.config_get_int(config, "AdvOut", "RecRBTime")) or 0
	if simple_seconds > 0 then
		profile_default_replay_seconds = simple_seconds
	elseif advanced_seconds > 0 then
		profile_default_replay_seconds = advanced_seconds
	end
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
	for _, override in ipairs(game_overrides) do
		if info.exe:lower() == override.exe and (override.title == "" or title_lower:find(override.title, 1, true) ~= nil) then
			return override
		end
	end

	return nil
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
	if process_key == active_process_key
		and active_game_name ~= nil
		and active_identity_config_revision == configuration_revision
	then
		return active_game_name, active_game_override, process_key
	end

	-- Keep the title used for folder/rule matching stable for the lifetime of
	-- a process. A config reload may deliberately remap the active game, but it
	-- is evaluated against the original title instead of a transient new one.
	local match_info = info
	if process_key == active_process_key and active_game_match_title ~= nil then
		match_info = {
			exe = info.exe,
			title = active_game_match_title,
		}
	end

	local override = find_game_override(match_info)
	return resolve_game_name(match_info, override), override, process_key
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
	if source == nil then
		warn_source_once("missing:" .. source_name, "Source '" .. source_name .. "' was not found; the script will keep retrying.")
		return false
	end

	local source_id = obs.obs_source_get_unversioned_id(source) or ""
	local expected_id = is_game_capture and "game_capture" or "wasapi_process_output_capture"
	if source_id ~= expected_id then
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

local function set_obs_output_settings(path, replay_seconds)
	local config = obs.obs_frontend_get_profile_config()
	if config == nil then
		obs.script_log(obs.LOG_WARNING, "Could not access the current OBS profile config.")
		return false
	end

	obs.config_set_string(config, "SimpleOutput", "FilePath", path)
	obs.config_set_string(config, "AdvOut", "RecFilePath", path)
	obs.config_set_string(config, "AdvOut", "FFFilePath", path)

	for _, section in ipairs(output_settings_sections) do
		obs.config_set_bool(config, section, "RecRB", true)
		if replay_seconds ~= nil then
			obs.config_set_int(config, section, "RecRBTime", replay_seconds)
		end
	end

	obs.config_save(config)
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

local function on_frontend_event(event)
	if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED then
		clear_replay_routing_state()
		update_active_replay_routing()
	elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED then
		clear_replay_routing_state()
	end
end

local function maybe_start_pending_replay_buffer()
	if pending_replay_start_at <= 0 then
		return
	end
	if stop_replay_buffer_when_game_exits and active_game_pid ~= nil and not active_game_process_is_running() then
		pending_replay_start_at = 0
		pending_replay_start_until = 0
		return
	end

	local now = now_seconds()
	if now < pending_replay_start_at then
		return
	end

	if obs.obs_frontend_replay_buffer_active() or now > pending_replay_start_until then
		pending_replay_start_at = 0
		pending_replay_start_until = 0
		return
	end

	obs.obs_frontend_replay_buffer_start()
	pending_replay_start_at = now + 2
end

local function ensure_replay_buffer_running(folder_changed)
	if not start_replay_buffer then
		return
	end

	local active = obs.obs_frontend_replay_buffer_active()
	if active and folder_changed and restart_replay_buffer_on_game_change then
		local now = now_seconds()
		obs.obs_frontend_replay_buffer_stop()
		pending_replay_start_at = now + 2
		pending_replay_start_until = now + 15
		return
	end

	if not active then
		obs.obs_frontend_replay_buffer_start()
	end
end

local function clear_active_game_state()
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
	pending_replay_start_until = 0
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
		if obs.obs_frontend_replay_buffer_active() then
			obs.obs_frontend_replay_buffer_stop()
			obs.script_log(obs.LOG_INFO, "Stopped replay buffer because the tracked game process exited.")
		end
		clear_active_game_state()
	end
end

local function configure_for_game(info, game_name, override, process_key, window_key)
	local effective_output_root = output_root
	if override ~= nil and override.root_folder ~= nil and clean_root_path(override.root_folder) ~= "" then
		effective_output_root = clean_root_path(override.root_folder)
	end

	if effective_output_root == nil or effective_output_root == "" or not is_absolute_windows_path(effective_output_root) then
		obs.script_log(obs.LOG_WARNING, "Output root must be an absolute Windows path; cannot route replay buffer clips: '" .. (effective_output_root or "") .. "'.")
		return
	end
	if not directory_exists(effective_output_root) then
		if effective_output_root ~= last_unavailable_output_root then
			last_unavailable_output_root = effective_output_root
			obs.script_log(obs.LOG_WARNING, "Replay root is unavailable; it must already exist before the replay buffer can save: '" .. effective_output_root .. "'.")
		end
		return
	end
	last_unavailable_output_root = nil

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
	if effective_replay_seconds == nil and active_replay_seconds ~= nil then
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

	if output_root_changed or replay_seconds_changed then
		if not set_obs_output_settings(effective_output_root, effective_replay_seconds) then
			return
		end
	end

	local game_capture_updated = true
	local game_audio_updated = true
	if capture_settings_changed then
		game_capture_updated = update_capture_source(
			game_capture_source,
			window_id,
			true,
			effective_match_priority,
			effective_anti_cheat_hook
		)
		game_audio_updated = update_capture_source(game_audio_source, window_id, false, effective_match_priority, false)
	end

	local capture_configuration_complete = not capture_settings_changed
		or (game_capture_updated and game_audio_updated)
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

	if process_changed or active_game_match_title == nil then
		active_game_match_title = info.title
	end
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
	ensure_replay_buffer_running(folder_changed or output_root_changed or replay_seconds_changed)
	if obs.obs_frontend_replay_buffer_active() then
		update_active_replay_routing()
	end
end

function poll_foreground_game()
	load_text_config()
	synchronize_saved_capture_hook_policy()
	maybe_start_pending_replay_buffer()

	local info = get_foreground_game_window()
	local now = now_seconds()
	if info == nil then
		candidate_key = nil
		candidate_count = 0
		maybe_stop_replay_buffer_after_game_exit(now)
		return
	end

	local game_name, override, process_key = resolve_game_identity(info)
	if not game_window_is_eligible(info, override) then
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

function script_description()
	return "Automatically points the Game Capture and Application Audio Capture sources at the foreground game, routes each saved replay into a per-game folder, and manages the replay buffer. Empty folders are not created merely by detecting a fullscreen app."
end

function script_defaults(settings)
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
	if directory_exists(output_root) then
		set_obs_output_settings(output_root, replay_seconds)
	elseif output_root ~= last_unavailable_output_root then
		last_unavailable_output_root = output_root
		obs.script_log(obs.LOG_WARNING, "Replay root is unavailable; it must already exist before the replay buffer can save: '" .. output_root .. "'.")
	end

	obs.timer_remove(poll_foreground_game)
	obs.timer_add(poll_foreground_game, poll_interval_ms)
end

function script_load(settings)
	script_update(settings)
	obs.obs_frontend_add_event_callback(on_frontend_event)
end

function script_unload()
	obs.timer_remove(poll_foreground_game)
	obs.obs_frontend_remove_event_callback(on_frontend_event)
	restore_active_replay_routing()
end
