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
