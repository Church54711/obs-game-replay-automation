-- Appended ONLY to the disposable copy by obs-compatibility-test.ps1.
-- Substitute foreground discovery, but exercise actual OBS sources/outputs.
-- No real application, desktop, microphone or system audio is captured.
pcall(ffi.cdef, "DWORD GetCurrentProcessId(void);")
get_foreground_game_window = function()
    if acceptance_fixture then
        local hwnd = ffi.cast("void *", acceptance_fixture.handle)
        return {pid=acceptance_fixture.pid, exe=acceptance_fixture.exe, title=get_window_title(hwnd),
            class_name=get_window_class(hwnd), hwnd=hwnd, is_fullscreen=true, is_excluded=false}
    end
    return { pid = tonumber(kernel32.GetCurrentProcessId()), exe = "obs64.exe",
        title = "Compatibility Fixture", class_name = "NoSuchFixtureWindow",
        hwnd = ffi.cast("void *", 1), is_fullscreen = true, is_excluded = false }
end
local fixture_started, fixture_saved, fixture_requested = nil, false, false
local fixture_stage, fixture_mark = 0, 0
local fixture_profile_before = {}
local fixture_original_event = on_frontend_event
on_frontend_event = function(event)
    fixture_original_event(event)
    if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then fixture_saved = true end
end
local function fixture_tick()
	if fixture_stage > 0 then
		local now = os.time()
		if fixture_stage == 1 and not obs.obs_frontend_replay_buffer_active() then
			local source = obs.obs_source_create("wasapi_process_output_capture", "Game Audio", nil, nil)
			assert(source, "Audio source recreation failed")
			local scene_source = obs.obs_frontend_get_current_scene()
			local item = obs.obs_scene_add(obs.obs_scene_from_source(scene_source), source)
			obs.obs_sceneitem_set_visible(item, false)
			obs.obs_source_release(scene_source); obs.obs_source_release(source)
			fixture_stage, fixture_mark = 2, now
		elseif fixture_stage == 2 and obs.obs_frontend_replay_buffer_active() then
			obs.obs_frontend_replay_buffer_stop()
			fixture_stage, fixture_mark = 3, now
		elseif fixture_stage == 3 and now - fixture_mark >= 4 then
			assert(not obs.obs_frontend_replay_buffer_active(), "Manual stop was undone")
			controls.resume()
			fixture_stage, fixture_mark = 4, now
		elseif fixture_stage == 4 and obs.obs_frontend_replay_buffer_active() then
			controls.pause()
			fixture_stage, fixture_mark = 5, now
		elseif fixture_stage == 5 and now - fixture_mark >= 4 then
			assert(not obs.obs_frontend_replay_buffer_active(), "Pause was undone")
			obs.timer_remove(fixture_tick)
			obs.script_log(obs.LOG_INFO, "COMPATIBILITY PASSED: " .. obs.obs_get_version_string())
		elseif fixture_stage < 5 and now - fixture_mark > 20 then error("Lifecycle timeout stage " .. fixture_stage) end
		return
	end
    if not obs.obs_frontend_replay_buffer_active() then return end
    if fixture_started == nil then
        assert(not directory_exists(output_root .. "\\Compatibility Fixture"), "Folder exists before save")
        for _, name in ipairs({"Game Capture", "Game Audio"}) do
            local source = obs.obs_get_source_by_name(name)
            assert(source, "Missing source: " .. name)
            local settings = obs.obs_source_get_settings(source)
            assert(obs.obs_data_get_string(settings, "window"):find(acceptance_fixture and acceptance_fixture.exe or "NoSuchFixtureWindow", 1, true), "Source not retargeted")
            obs.obs_data_release(settings); obs.obs_source_release(source)
        end
        fixture_started = os.time()
        obs.script_log(obs.LOG_INFO, "COMPATIBILITY: sources retargeted; game folder absent before save")
    elseif not fixture_requested and os.time() - fixture_started >= (acceptance_fixture and 12 or 4) then
        fixture_requested = true
        controls.save_replay()
    elseif fixture_saved then
        assert(controls.last_saved:find("Compatibility Fixture", 1, true), "Save confirmation path missing")
        for _, previous in ipairs(fixture_profile_before) do
            assert(obs.config_get_string(obs.obs_frontend_get_profile_config(), previous.section, previous.key) == previous.value,
                "Profile value not restored: " .. previous.section .. "." .. previous.key)
        end
        -- Exercise actual properties, editor callbacks, and serialized settings.
        local props = script_properties()
        assert(obs.obs_properties_get(props, "automation_status"), "Status property missing")
        controls.refresh(props)
        controls.use_current()
        obs.obs_data_set_string(controls.settings, "editor_folder", "Compatibility Fixture")
        obs.obs_data_set_int(controls.settings, "editor_seconds", 3)
        controls.apply_editor(false)
        script_save(controls.settings)
        local restored = obs.obs_data_create_from_json(obs.obs_data_get_json(controls.settings))
        script_defaults(restored)
        script_update(restored)
        assert(#controls.overrides == 1 and controls.overrides[1].replay_seconds == 3, "Editor settings did not persist")
        obs.obs_data_release(restored)
        obs.obs_properties_destroy(props)
        -- Unload cleanup must restore the unprefixed output filename format.
        restore_active_replay_routing()
        local output = obs.obs_frontend_get_replay_buffer_output()
        local settings = obs.obs_output_get_settings(output)
        assert(not obs.obs_data_get_string(settings, "format"):find("Compatibility Fixture", 1, true), "Routing not restored")
        obs.obs_data_release(settings); obs.obs_output_release(output)
        local source = obs.obs_get_source_by_name("Game Audio")
        obs.obs_source_remove(source); obs.obs_source_release(source)
        fixture_stage, fixture_mark = 1, os.time()
    end
end
local function fixture_preferences()
    assert(user_store.ready and not user_store.error, "Settings migration failed: " .. tostring(user_store.error))
    local keys = obs.obs_data_array_create()
    local key = obs.obs_data_create_from_json('{"key":"OBS_KEY_F13"}')
    obs.obs_data_array_push_back(keys, key)
    obs.obs_data_set_array(controls.settings, "hotkey_save", keys)
    obs.obs_hotkey_load(controls.hotkeys.save.id, keys)
    obs.obs_data_release(key); obs.obs_data_array_release(keys)
    script_save(controls.settings)
    local export_path = user_store.directory .. "\\fixture-export.json"
    obs.obs_data_set_string(controls.settings, "settings_transfer_path", export_path)
    user_store.transfer(false)
    assert(user_store.exists(export_path), "Settings export missing")
    obs.obs_data_set_int(controls.settings, "low_space_gib", 13)
    script_update(controls.settings)
    user_store.transfer(true)
    assert(controls.low_space_gib == 5, "Settings import did not restore values")

    -- A new scene's default settings must defer to the canonical user file.
    local fresh = obs.obs_data_create()
    script_defaults(fresh)
    user_store.initialized = false; user_store.ready = false
    script_update(fresh)
    obs.obs_data_release(fresh)
    assert(replay_seconds == 3 and not fullscreen_only, "New scene lost migrated preferences")
    keys = obs.obs_data_get_array(controls.settings, "hotkey_save")
    assert(keys and obs.obs_data_array_count(keys) == 1, "New scene lost migrated hotkey")
    obs.obs_data_array_release(keys)
    assert(obs.obs_data_get_string(controls.settings, "output_root"):find("replays",1,true), "New scene replaced the replay folder")

    local invalid_path = user_store.directory .. "\\invalid-import.json"
    local invalid = user_store.snapshot(controls.settings)
    obs.obs_data_set_int(invalid, "schemaVersion", 99)
    obs.obs_data_save_json_safe(invalid, invalid_path, "tmp", "bak")
    obs.obs_data_release(invalid)
    local prior = obs.obs_data_create_from_json_file(user_store.path)
    local prior_json = obs.obs_data_get_json(prior)
    obs.obs_data_release(prior)

    -- Reject wrong types, fractional/out-of-range numbers, and malformed rules.
    for _, json in ipairs({
        '{"schemaVersion":1.5,"settings":{}}',
        '{"schemaVersion":"1","settings":{}}',
        '{"schemaVersion":1,"settings":{"output_root":"C:/clips","game_capture_source":"Game Capture","game_audio_source":"Game Audio","low_space_gib":1.5}}',
        '{"schemaVersion":1,"settings":{"output_root":"C:/clips","game_capture_source":"Game Capture","game_audio_source":"Game Audio","poll_interval_ms":1}}',
        '{"schemaVersion":1,"settings":{"output_root":"C:/clips","game_capture_source":"Game Capture","game_audio_source":"Game Audio","fullscreen_only":"false"}}',
        '{"schemaVersion":1,"settings":{"output_root":"C:/clips","game_capture_source":"Game Capture","game_audio_source":"Game Audio","game_overrides":"game.exe=misspelled=true"}}',
    }) do
        local data = obs.obs_data_create_from_json(json)
        assert(not user_store.validate(data), "Invalid typed preferences were accepted")
        obs.obs_data_release(data)
    end
    obs.obs_data_set_string(controls.settings, "settings_transfer_path", invalid_path)
    user_store.transfer(true)
    prior = obs.obs_data_create_from_json_file(user_store.path)
    assert(obs.obs_data_get_json(prior) == prior_json, "Invalid import changed stored preferences")
    obs.obs_data_release(prior)

    -- Corruption must not silently reset or overwrite the user's file.
    assert(user_store.write_text(user_store.path, "{malformed"))
    user_store.initialized = false; user_store.ready = false
    user_store.initialize(controls.settings)
    assert(user_store.error and not user_store.ready, "Malformed settings were accepted")
    assert(not obs.obs_data_create_from_json_file(user_store.path), "Malformed file was silently replaced")
    obs.obs_data_set_string(controls.settings, "settings_transfer_path", export_path)
    user_store.transfer(true)
    assert(not user_store.error and user_store.ready, "Explicit import could not recover corrupted settings: " .. controls.notice)

    -- A second writer must not be overwritten by a stale OBS instance.
    local changed = user_store.snapshot(controls.settings)
    local values = obs.obs_data_get_obj(changed, "settings")
    obs.obs_data_set_int(values, "low_space_gib", 17)
    obs.obs_data_set_obj(changed, "settings", values)
    obs.obs_data_release(values)
    obs.obs_data_save_json_safe(changed, user_store.path, "tmp", "bak")
    obs.obs_data_release(changed)
    obs.obs_data_set_int(controls.settings, "low_space_gib", 19)
    assert(not user_store.save(controls.settings) and user_store.error, "Conflicting settings write was not refused")
    changed = obs.obs_data_create_from_json_file(user_store.path)
    values = obs.obs_data_get_obj(changed, "settings")
    assert(obs.obs_data_get_int(values,"low_space_gib") == 17, "Concurrent writer's settings were lost")
    obs.obs_data_release(values); obs.obs_data_release(changed)
    user_store.transfer(true)
    assert(not user_store.error, "Settings did not recover after explicit import")
    controls.notice = ""
    obs.script_log(obs.LOG_INFO, "COMPATIBILITY: settings migration, scene reuse, export/import, corruption and write conflict checks passed")
end
local function fixture_setup()
    local scene_source = obs.obs_frontend_get_current_scene()
    if not scene_source then return end
    obs.timer_remove(fixture_setup)
    fixture_preferences()
    for _, pair in ipairs({{"SimpleOutput", "FilePath"}, {"AdvOut", "RecFilePath"},
        {"SimpleOutput", "RecRBTime"}, {"AdvOut", "RecRBTime"}}) do
        fixture_profile_before[#fixture_profile_before + 1] = {section=pair[1], key=pair[2],
            value=obs.config_get_string(obs.obs_frontend_get_profile_config(), pair[1], pair[2])}
    end
    local scene = obs.obs_scene_from_source(scene_source)
    controls.create_sources()
    controls.create_sources() -- repeated setup must reuse existing sources
    local health = controls.health()
    assert(health.capture and health.audio and health.capture_in_scene and health.audio_in_scene, "Setup assistant did not prepare capture sources")
    controls.check_setup()
    assert(controls.write_probe, "Setup folder write check failed")
    controls.live_status_tick()
    assert(user_store.exists(user_store.directory .. "\\status.html"), "Live status page was not created")
    local saved, notice = controls.last_saved, controls.notice
    controls.last_saved = [[C:\Users\Private Person\Secret Game\clip.mkv]]
    controls.notice = [[private C:\Users\Private Person]]
    controls.export_diagnostics()
    controls.last_saved, controls.notice = saved, notice
    for _, name in ipairs({"Game Capture", "Game Audio"}) do
        obs.obs_sceneitem_set_visible(obs.obs_scene_find_source_recursive(scene, name), acceptance_fixture ~= nil)
    end
    for _, item in ipairs(acceptance_fixture and {} or { {"color_source_v3", "Test Color"} }) do
        local data = obs.obs_data_create()
        obs.obs_data_set_int(data, "color", 0xFF40A040)
        obs.obs_data_set_int(data, "width", 320)
        obs.obs_data_set_int(data, "height", 180)
        local source = obs.obs_source_create(item[1], item[2], data, nil)
        obs.obs_data_release(data)
        assert(source, "Source type unavailable: " .. item[1])
        local scene_item = obs.obs_scene_add(scene, source)
        obs.obs_sceneitem_set_visible(scene_item, item[2] == "Test Color")
        obs.obs_source_release(source)
    end
    obs.obs_source_release(scene_source)
    obs.timer_add(poll_foreground_game, 500)
    obs.timer_add(fixture_tick, 250)
end
local fixture_original_load = script_load
function script_load(settings)
    fixture_original_load(settings)
    obs.timer_remove(poll_foreground_game)
    obs.timer_add(fixture_setup, 250)
end
