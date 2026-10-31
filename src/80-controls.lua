-- OBS controls backed by shared user preferences; legacy sidecar stays intact.
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
    local setup = obs.obs_properties_get(props, "setup_status")
    if setup then obs.obs_property_set_description(setup, controls.setup_text()) end
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
    if not user_store.disabled and not user_store.save(settings) then
        controls.notice = user_store.error or "Game settings could not be saved"; return true
    end
	controls.overrides = parse_game_overrides(raw)
	configuration_revision = configuration_revision + 1
	controls.notice = remove and "Editor rule removed; advanced rules apply again" or ("Saved settings for " .. key)
	return true
end

function controls.add_properties(props)
    controls.add_setup_properties(props)
	obs.obs_properties_add_text(props, "automation_status", controls.status_text(), obs.OBS_TEXT_INFO)
	obs.obs_properties_add_button(props, "refresh_status", "Refresh status", controls.refresh)
    obs.obs_properties_add_text(props, "settings_location", "Preferences: " .. (user_store.path or "initializing"), obs.OBS_TEXT_INFO)
    obs.obs_properties_add_path(props, "settings_transfer_path", "Settings import/export file", obs.OBS_PATH_FILE_SAVE, "JSON (*.json)", nil)
    obs.obs_properties_add_button(props, "export_settings", "Export settings", function(p) user_store.transfer(false); return controls.refresh(p) end)
    obs.obs_properties_add_button(props, "import_settings", "Import settings (backs up current file)", function(p) user_store.transfer(true); return controls.refresh(p) end)
    obs.obs_properties_add_int(props, "default_replay_seconds", "Replay length (seconds; 0 uses OBS profile)", 0, 86400, 1)
    obs.obs_properties_add_text(props, "game_overrides", "Advanced per-game rules", obs.OBS_TEXT_MULTILINE)
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
