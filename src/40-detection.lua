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
