-- Appended ONLY to the disposable copy by obs-compatibility-test.ps1.
-- Substitute foreground discovery, but exercise actual OBS sources/outputs.
-- No real application, desktop, microphone or system audio is captured.
pcall(ffi.cdef, "DWORD GetCurrentProcessId(void);")
get_foreground_game_window = function()
    return { pid = tonumber(kernel32.GetCurrentProcessId()), exe = "obs64.exe",
        title = "Compatibility Fixture", class_name = "NoSuchFixtureWindow",
        hwnd = ffi.cast("void *", 1), is_fullscreen = true, is_excluded = false }
end
local fixture_started, fixture_saved, fixture_requested = nil, false, false
local fixture_original_event = on_frontend_event
on_frontend_event = function(event)
    fixture_original_event(event)
    if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then fixture_saved = true end
end
local function fixture_tick()
    if not obs.obs_frontend_replay_buffer_active() then return end
    if fixture_started == nil then
        assert(not directory_exists(output_root .. "\\Compatibility Fixture"), "Folder exists before save")
        for _, name in ipairs({"Game Capture", "Game Audio"}) do
            local source = obs.obs_get_source_by_name(name)
            assert(source, "Missing source: " .. name)
            local settings = obs.obs_source_get_settings(source)
            assert(obs.obs_data_get_string(settings, "window"):find("NoSuchFixtureWindow", 1, true), "Source not retargeted")
            obs.obs_data_release(settings); obs.obs_source_release(source)
        end
        fixture_started = os.time()
        obs.script_log(obs.LOG_INFO, "COMPATIBILITY: sources retargeted; game folder absent before save")
    elseif not fixture_requested and os.time() - fixture_started >= 4 then
        fixture_requested = true
        obs.obs_frontend_replay_buffer_save()
    elseif fixture_saved then
        obs.timer_remove(fixture_tick)
        get_foreground_game_window = function() return nil end
        start_replay_buffer = false
        -- Unload cleanup must restore the unprefixed output filename format.
        restore_active_replay_routing()
        local output = obs.obs_frontend_get_replay_buffer_output()
        local settings = obs.obs_output_get_settings(output)
        assert(not obs.obs_data_get_string(settings, "format"):find("Compatibility Fixture", 1, true), "Routing not restored")
        obs.obs_data_release(settings); obs.obs_output_release(output)
        obs.timer_remove(poll_foreground_game)
        obs.obs_frontend_replay_buffer_stop()
        obs.script_log(obs.LOG_INFO, "COMPATIBILITY PASSED: " .. obs.obs_get_version_string())
    end
end
local function fixture_setup()
    local scene_source = obs.obs_frontend_get_current_scene()
    if not scene_source then return end
    obs.timer_remove(fixture_setup)
    local scene = obs.obs_scene_from_source(scene_source)
    for _, item in ipairs({ {"game_capture", "Game Capture"},
        {"wasapi_process_output_capture", "Game Audio"}, {"color_source_v3", "Test Color"} }) do
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
