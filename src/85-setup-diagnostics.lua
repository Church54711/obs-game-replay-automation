-- User-triggered setup actions and a local, continuously refreshed status page.
-- No server, network listener, desktop capture, or retained property pointers.
function controls.health()
    local result = {capture=false, audio=false, capture_in_scene=false, audio_in_scene=false,
        destination=directory_exists(output_root), save_hotkey=false}
    local scene_source = obs.obs_frontend_get_current_scene()
    local scene = scene_source and obs.obs_scene_from_source(scene_source) or nil
    for _, entry in ipairs({{"capture",game_capture_source,"game_capture"}, {"audio",game_audio_source,"wasapi_process_output_capture"}}) do
        local source = obs.obs_get_source_by_name(entry[2])
        if source then
            result[entry[1]] = not obs.obs_source_removed(source) and obs.obs_source_get_unversioned_id(source) == entry[3]
            result[entry[1] .. "_in_scene"] = scene ~= nil and obs.obs_scene_find_source_recursive(scene, entry[2]) ~= nil
            obs.obs_source_release(source)
        end
    end
    if scene_source then obs.obs_source_release(scene_source) end
    if controls.hotkeys.save then
        local keys = obs.obs_hotkey_save(controls.hotkeys.save.id)
        result.save_hotkey = keys ~= nil and obs.obs_data_array_count(keys) > 0
        if keys then obs.obs_data_array_release(keys) end
    end
    local profile = obs.obs_frontend_get_profile_config()
    local section = profile and (obs.config_get_string(profile,"Output","Mode") == "Advanced" and "AdvOut" or "SimpleOutput") or nil
    result.buffer_enabled = section ~= nil and obs.config_get_bool(profile, section, "RecRB")
    result.profile_seconds = section and obs.config_get_int(profile, section, "RecRBTime") or 0
    return result
end
function controls.setup_text()
    local health = controls.health()
    local function status(ready) return ready and "OK" or "Needs setup" end
    return "First-run checks\nGame Capture: " .. status(health.capture and health.capture_in_scene)
        .. "\nApplication audio: " .. status(health.audio and health.audio_in_scene)
        .. "\nReplay folder exists: " .. status(health.destination)
        .. "\nReplay buffer enabled in OBS: " .. tostring(health.buffer_enabled)
        .. "\nOBS profile replay length: " .. health.profile_seconds .. " seconds"
        .. "\nSave replay hotkey: " .. (health.save_hotkey and "Assigned" or "Choose one in OBS Settings > Hotkeys")
        .. "\n" .. (controls.write_probe == true and "Replay folder write check passed"
            or (controls.write_probe == false and "Replay folder write check failed" or "Use Check setup to test writing"))
end
function controls.check_setup()
    controls.write_probe = false
    if directory_exists(output_root) then
        local path = output_root .. "\\.obs-replay-write-check-" .. tostring(math.floor(now_seconds()*1000))
        controls.write_probe = user_store.write_text(path, "OBS replay write check")
        if controls.write_probe then kernel32.DeleteFileW(utf8_to_wide(path)) end
    end
    controls.notice = controls.setup_text()
end
function controls.prepare_folder()
    if not is_absolute_windows_path(output_root) then controls.notice = "Choose an absolute replay folder first"; return end
    if not user_store.mkdir(output_root) then controls.notice = "Could not create the selected replay folder"; return end
    controls.check_setup()
end
function controls.create_sources()
    if obs.obs_frontend_recording_active() or obs.obs_frontend_streaming_active() then
        controls.notice = "Finish recording or streaming before adding sources"; return
    end
    local scene_source = obs.obs_frontend_get_current_scene()
    local scene = scene_source and obs.obs_scene_from_source(scene_source) or nil
    if not scene then
        if scene_source then obs.obs_source_release(scene_source) end
        controls.notice = "Select a scene in OBS first"; return
    end
    -- Validate both names before adding either source. Never replace a source
    -- belonging to the user or silently rename their scene content.
    for _, entry in ipairs({{game_capture_source,"game_capture"}, {game_audio_source,"wasapi_process_output_capture"}}) do
        local source = obs.obs_get_source_by_name(entry[1])
        if source then
            local valid = obs.obs_source_get_unversioned_id(source) == entry[2] and not obs.obs_source_removed(source)
            obs.obs_source_release(source)
            if not valid then obs.obs_source_release(scene_source); controls.notice = "A selected source name is already used by another source type"; return end
        end
    end
    local complete = true
    for _, entry in ipairs({{game_capture_source,"game_capture"}, {game_audio_source,"wasapi_process_output_capture"}}) do
        local source = obs.obs_get_source_by_name(entry[1])
        if not source then
            local settings = obs.obs_data_create()
            obs.obs_data_set_string(settings, "window", "")
            obs.obs_data_set_string(settings, "capture_mode", "window")
            obs.obs_data_set_bool(settings, "anti_cheat_hook", false)
            source = obs.obs_source_create(entry[2], entry[1], settings, nil)
            obs.obs_data_release(settings)
        end
        if source then
            if not obs.obs_scene_find_source_recursive(scene, entry[1]) then
                if not obs.obs_scene_add(scene, source) then complete = false end
            end
            obs.obs_source_release(source)
        else complete = false end
    end
    obs.obs_source_release(scene_source)
    obs.obs_frontend_save()
    controls.notice = complete and "Capture sources are ready in the current scene" or "A source could not be created; check the OBS log"
end
function controls.html_escape(text)
    return tostring(text):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;")
end
function controls.live_status_tick()
    if user_store.disabled or not user_store.ready or not user_store.directory then return end
    local text = controls.status_text() .. "\n\n" .. controls.setup_text()
    local timestamp = os.time()
    if text == controls.last_status_text and controls.last_status_time and timestamp - controls.last_status_time < 5 then return end
    local html = '<!doctype html><html lang="en"><meta charset="utf-8"><meta http-equiv="refresh" content="1">'
        .. '<meta name="viewport" content="width=device-width,initial-scale=1"><title>Replay automation status</title>'
        .. '<style>body{margin:0;padding:24px;background:#151a22;color:#e6edf3;font:16px/1.6 system-ui}'
        .. 'h1{font-size:22px;margin:0 0 16px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}'
        .. 'small{color:#aab7c4}</style><h1>Replay automation</h1><pre>' .. controls.html_escape(text)
        .. '</pre><small id="heartbeat">Live while OBS is running. Use OBS Tools &gt; Scripts for controls.</small>'
        .. '<script>if(Date.now()/1000-' .. timestamp .. '>15){document.getElementById("heartbeat").textContent="Status is stale. OBS may have stopped.";document.querySelector("pre").style.opacity=".5"}</script></html>'
    if user_store.write_text(user_store.directory .. "\\status.html", html) then controls.last_status_text, controls.last_status_time = text, timestamp end
end
function controls.open_status()
    controls.last_status_text = nil; controls.live_status_tick()
    if not user_store.directory then controls.notice = "Settings folder is unavailable"; return end
    local path = user_store.directory .. "\\status.html"
    if not user_store.exists(path) then controls.notice = "Could not write the live status page"; return end
    controls.shell.ShellExecuteW(nil, utf8_to_wide("open"), utf8_to_wide(path), nil, nil, 1)
end
function controls.export_diagnostics()
    if not user_store.directory then controls.notice = "Settings folder is unavailable"; return end
    local health = controls.health()
    local report = obs.obs_data_create()
    obs.obs_data_set_int(report, "schemaVersion", 1)
    obs.obs_data_set_string(report, "scriptVersion", "@PACKAGE_VERSION@")
    obs.obs_data_set_string(report, "obsVersion", obs.obs_get_version_string())
    obs.obs_data_set_string(report, "platform", "windows-x64")
    obs.obs_data_set_bool(report, "settingsLoaded", user_store.ready)
    obs.obs_data_set_bool(report, "settingsError", user_store.error ~= nil)
    obs.obs_data_set_bool(report, "paused", controls.paused)
    obs.obs_data_set_bool(report, "bufferActive", obs.obs_frontend_replay_buffer_active())
    obs.obs_data_set_bool(report, "bufferOwned", replay_state.owned)
    obs.obs_data_set_bool(report, "waitingForStart", replay_state.starting)
    obs.obs_data_set_bool(report, "gameDetected", controls.last_detected ~= nil)
    obs.obs_data_set_bool(report, "clipConfirmed", controls.last_saved ~= "")
    obs.obs_data_set_bool(report, "lowSpaceWarning", controls.storage_warning ~= nil)
    obs.obs_data_set_bool(report, "fallbackActive", controls.fallback_warning ~= nil)
    for key,value in pairs(health) do
        if type(value) == "boolean" then obs.obs_data_set_bool(report, key, value)
        else obs.obs_data_set_int(report, key, value) end
    end
    -- Deliberate allowlist: no paths, process/window/source names, raw log
    -- messages, OBS credentials, game rules, or scene/profile contents.
    local path = user_store.directory .. "\\diagnostics.json"
    local ok = obs.obs_data_save_json_safe(report, path, "tmp", "bak")
    obs.obs_data_release(report)
    controls.notice = ok and ("Diagnostic report saved: " .. path .. " (no personal paths or game names inside)") or "Could not save diagnostic report"
end
function controls.add_setup_properties(props)
    obs.obs_properties_add_text(props, "setup_status", controls.setup_text(), obs.OBS_TEXT_INFO)
    for _, action in ipairs({
        {"check_setup","Check setup and folder writing",controls.check_setup},
        {"prepare_folder","Create the selected replay folder",controls.prepare_folder},
        {"create_sources","Add missing capture sources to current scene",controls.create_sources},
        {"live_status","Open live status",controls.open_status},
        {"diagnostics","Export diagnostic report",controls.export_diagnostics},
    }) do
        local fn = action[3]
        obs.obs_properties_add_button(props, action[1], action[2], function(p) fn(); return controls.refresh(p) end)
    end
end
