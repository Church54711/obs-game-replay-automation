function script_description()
	return "Automatically points the Game Capture and Application Audio Capture sources at the foreground game, routes each saved replay into a per-game folder, and manages the replay buffer. Empty folders are not created merely by detecting a fullscreen app."
end

function script_defaults(settings)
    obs.obs_data_set_default_int(settings, "default_replay_seconds", 0)
    obs.obs_data_set_default_string(settings, "game_overrides", "")
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
    user_store.initialize(settings)
	obs.obs_data_addref(settings)
	if controls.settings then obs.obs_data_release(controls.settings) end
	controls.settings = settings
    if user_store.error then controls.notice = user_store.error; return end
    if user_store.ready then
        local candidate = user_store.snapshot(settings)
        local valid, problem = user_store.validate(candidate)
        obs.obs_data_release(candidate)
        if not valid then controls.notice = "Settings not applied: " .. problem; return end
    end
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
    local configured_seconds = obs.obs_data_get_int(settings, "default_replay_seconds")
    replay_seconds = configured_seconds > 0 and configured_seconds or nil
    game_overrides = parse_game_overrides(obs.obs_data_get_string(settings, "game_overrides"))
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
		replay_seconds = replay_seconds,
		restart_replay_buffer_on_game_change = restart_replay_buffer_on_game_change,
		stop_replay_buffer_when_game_exits = stop_replay_buffer_when_game_exits,
		game_exit_stop_delay_seconds = game_exit_stop_delay_seconds,
		game_rules = game_rules,
		game_overrides = game_overrides,
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
    user_store.save(settings)
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
    obs.timer_add(controls.live_status_tick, 1000)
end

function script_save(settings)
	for name, hotkey in pairs(controls.hotkeys) do
		local data = obs.obs_hotkey_save(hotkey.id)
		obs.obs_data_set_array(settings, "hotkey_" .. name, data)
		obs.obs_data_array_release(data)
	end
    user_store.save(settings)
end

function script_unload()
    obs.timer_remove(controls.live_status_tick)
    if user_store.directory and user_store.ready then
        user_store.write_text(user_store.directory .. "\\status.html",
            '<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="2"><title>Replay automation</title><p>OBS replay automation is offline. Open OBS to resume live status.</p>')
    end
	obs.timer_remove(poll_foreground_game)
	obs.obs_frontend_remove_event_callback(on_frontend_event)
	restore_active_replay_routing()
	restore_profile_settings()
	prune_game_identities(true)
	for _, hotkey in pairs(controls.hotkeys) do obs.obs_hotkey_unregister(hotkey.callback) end
	controls.hotkeys = {}
	if controls.settings then obs.obs_data_release(controls.settings); controls.settings = nil end
end
