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
