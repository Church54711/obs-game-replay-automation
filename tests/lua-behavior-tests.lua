-- This file is appended to the production chunk to exercise its local functions
-- without adding test-only exports or hooks to the recipient script.
kernel32 = {
    GetTickCount64 = function() return fixture.now * 1000 end,
    OpenProcess = function(_, _, pid) if fixture.alive[pid] then return { pid = pid } end end,
    GetExitCodeProcess = function(handle, code) code[0] = fixture.alive[handle.pid] and 259 or 0; return 1 end,
    CloseHandle = function() fixture.closed = fixture.closed + 1; return 1 end,
}
directory_exists = function(path) return path == [[C:\Replays]] or path == [[D:\Replays]] end
get_foreground_game_window = function() return fixture.foreground end
read_file = function() return fixture.raw end
controls.free_bytes = function() return 100 * 1073741824 end
-- Environment expansion is covered by the real Win32 conversion code during
-- normal load; test inputs below use explicit absolute paths.
expand_environment_strings = function(value) return value end

function fixture.reset()
    controls.paused = false; controls.ignored = {}; controls.overrides = {}; controls.disk_cache = {}
    controls.last_saved = ""; controls.save_requested_at = nil; controls.notice = ""; controls.fallback_root = ""
    controls.active_info = nil; controls.last_detected = nil; controls.settings = {}; controls.storage_warning = nil
    controls.low_space_gib = 5; controls.sound = false; controls.last_storage_warning = nil
    controls.free_bytes = function() return 100 * 1073741824 end
    fixture.saves = 0; fixture.saved_path = ""
    if fixture.closed then prune_game_identities(true) end
    clear_active_game_state(); clear_replay_routing_state()
    fixture.now = 100; fixture.closed = 0; fixture.alive = { [1] = true, [2] = true }
    fixture.active = false; fixture.starts = 0; fixture.stops = 0; fixture.updates = 0
    fixture.defer_start = false; fixture.defer_stop = false; fixture.logs = {}
    fixture.profile_name = "Original"
    fixture.profile = { ["Output.Mode"] = "Simple", ["SimpleOutput.FilePath"] = [[C:\Recordings]],
        ["SimpleOutput.RecRBTime"] = 30, ["SimpleOutput.RecRB"] = false, ["AdvOut.RecRBTime"] = 45 }
    fixture.sources = {
        ["Game Capture"] = { id = "game_capture", settings = { window = "", anti_cheat_hook = false } },
        ["Game Audio"] = { id = "wasapi_process_output_capture", settings = { window = "" } },
    }
    fixture.output = { directory = [[C:\Recordings]], format = "%CCYY-%MM/%DD %hh-%mm-%ss" }
    fixture.info = { pid = 1, exe = "game.exe", title = "Game Alpha", class_name = "Fixture", hwnd = 10, is_fullscreen = true, is_excluded = false }
    fixture.foreground = fixture.info
    fixture.callback = on_frontend_event
    fixture.raw = "root_folder=C:\\Replays\ndefault_replay_seconds=120\n"
    output_root = [[C:\Replays]]; replay_seconds = 120
    game_capture_source = "Game Capture"; game_audio_source = "Game Audio"
    game_rules = {}; game_overrides = {}; excluded_exes = {}
    configuration_revision = 0; process_identities = {}; identity_last_pruned_at = 0
    profile_default_replay_seconds = nil; profile_changes = {}
    replay_state = { owned = false, starting = false, stopping = false, expected_stop = false,
        paused_process = nil, ready = false, profile_changing = false }
    config_last_raw = nil; config_last_checked_at = 0; config_pending_raw = nil; config_last_error = nil
    base_settings = nil; stable_poll_count = 1; fullscreen_only = true
    start_replay_buffer = true; restart_replay_buffer_on_game_change = true
    stop_replay_buffer_when_game_exits = true; game_exit_stop_delay_seconds = 0
    missing_source_warnings = {}
end
function fixture.select(info)
    info = info or fixture.info
    local name, override, key = resolve_game_identity(info)
    configure_for_game(info, name, override, key, build_window_identity_key(info))
end
function fixture.test(name, run)
    fixture.reset()
    local ok, err = pcall(run)
    if not ok then error(name .. ": " .. tostring(err)) end
    table.insert(fixture.results, "PASS " .. name)
end

fixture.test("missing and wrong-type sources do not start; late sources recover", function()
    local sources = fixture.sources; fixture.sources = {}
    fixture.select(); assert(fixture.starts == 0)
    fixture.sources = sources; fixture.sources["Game Audio"].id = "wrong"
    fixture.select(); assert(fixture.starts == 0)
    fixture.sources["Game Audio"].id = "wasapi_process_output_capture"
    fixture.select(); assert(fixture.starts == 1 and replay_state.owned)
end)
fixture.test("manual stop stays stopped; manual restart is user owned", function()
    fixture.select()
    obs.obs_frontend_replay_buffer_stop()
    fixture.select(); fixture.select()
    assert(fixture.starts == 1 and not fixture.active)
    obs.obs_frontend_replay_buffer_start()
    assert(not replay_state.owned)
    fixture.alive[1] = false; maybe_stop_replay_buffer_after_game_exit(fixture.now)
    assert(fixture.active)
end)
fixture.test("already-running user buffer is not restarted or stopped on exit", function()
    fixture.active = true
    fixture.select()
    assert(fixture.stops == 0 and fixture.starts == 0)
    fixture.alive[1] = false; maybe_stop_replay_buffer_after_game_exit(fixture.now)
    assert(fixture.active and fixture.stops == 0)
end)
fixture.test("active exclusion applies while the game is in the background", function()
	assert(load_text_config(true))
    fixture.select()
    fixture.raw = "root_folder=C:\\Replays\n[game_overrides]\ngame.exe=enabled=false\n"
    fixture.foreground = nil; fixture.now = fixture.now + 10
    poll_foreground_game()
    assert(fixture.active)
    fixture.now = fixture.now + 6; poll_foreground_game()
    assert(not fixture.active and active_game_pid == nil)
    assert(fixture.sources["Game Capture"].settings.window == "")
end)
fixture.test("recreated sources are retargeted without repeated updates", function()
    fixture.select(); local before = fixture.updates
    fixture.select(); assert(fixture.updates == before)
    fixture.sources["Game Capture"].settings = { window = "", anti_cheat_hook = false }
    fixture.sources["Game Audio"].settings = { window = "" }
    fixture.select(); assert(fixture.updates == before + 2)
    assert(fixture.sources["Game Capture"].settings.window ~= "")
end)
fixture.test("profile changes refresh defaults and preserve recording paths", function()
    fixture.select()
    on_frontend_event(obs.OBS_FRONTEND_EVENT_PROFILE_CHANGING)
    fixture.profile_name = "Advanced"
    fixture.profile = { ["Output.Mode"] = "Advanced", ["SimpleOutput.RecRBTime"] = 30,
        ["AdvOut.RecRBTime"] = 90, ["SimpleOutput.FilePath"] = [[D:\Recordings]] }
    on_frontend_event(obs.OBS_FRONTEND_EVENT_PROFILE_CHANGED)
    replay_seconds = nil; fixture.select()
    assert(active_replay_seconds == 90)
    assert(fixture.profile["SimpleOutput.FilePath"] == [[D:\Recordings]])
    assert(fixture.profile["AdvOut.RecRBTime"] == 90)
end)
fixture.test("A to B to A retains the original game folder", function()
    fixture.select()
    fixture.select({ pid = 2, exe = "other.exe", title = "Other", class_name = "Other", hwnd = 20 })
    fixture.info.title = "Changed title"
    fixture.select()
    assert(active_game_name == "Game Alpha")
    fixture.alive[1] = false; fixture.now = fixture.now + 20; prune_game_identities(false)
    assert(process_identities["1|game.exe"] == nil)
    fixture.alive[1] = true
    assert(resolve_game_identity(fixture.info) == "Changed title")
end)
fixture.test("profile changes are temporary and do not overwrite user edits", function()
    fixture.defer_start = true; fixture.select()
    assert(fixture.profile["SimpleOutput.FilePath"] == [[C:\Replays]])
    fixture.profile["SimpleOutput.FilePath"] = [[D:\User Edit]]
    fixture.active = true; on_frontend_event(obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED)
    assert(fixture.profile["SimpleOutput.FilePath"] == [[D:\User Edit]])
    assert(fixture.profile["SimpleOutput.RecRB"] == false)
    assert(fixture.profile["SimpleOutput.RecRBTime"] == 30)
    assert(fixture.profile["AdvOut.RecFilePath"] == nil)
end)
fixture.test("restart waits for asynchronous stop completion", function()
    fixture.select(); fixture.defer_stop = true
    fixture.select({ pid = 2, exe = "other.exe", title = "Other", class_name = "Other", hwnd = 20 })
    fixture.now = fixture.now + 3; maybe_start_pending_replay_buffer()
    assert(fixture.starts == 1)
    fixture.active = false; on_frontend_event(obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED)
    maybe_start_pending_replay_buffer()
    assert(fixture.starts == 2 and replay_state.owned)
end)
fixture.test("failed start times out without repeated dialogs or changed profile", function()
    fixture.defer_start = true; fixture.select()
    fixture.now = fixture.now + 16; maybe_start_pending_replay_buffer(); fixture.select()
    assert(fixture.starts == 1 and replay_state.paused_process ~= nil)
    assert(fixture.profile["SimpleOutput.FilePath"] == [[C:\Recordings]])
end)
fixture.test("invalid and unreadable config retains the last valid settings", function()
    assert(load_text_config(true))
    fixture.raw = "root_folder=C:\\Replays\ndefault_replay_seconds=oops\n"
    fixture.now = fixture.now + 6; assert(not load_text_config())
    assert(replay_seconds == 120)
    fixture.raw = nil; fixture.now = fixture.now + 6; assert(not load_text_config())
    assert(replay_seconds == 120)
    fixture.raw = ""; fixture.now = fixture.now + 6; assert(not load_text_config())
    assert(replay_seconds == 120)
end)
fixture.test("valid config edits require two stable reads", function()
    assert(load_text_config(true))
    fixture.raw = "root_folder=D:\\Replays\ndefault_replay_seconds=240\n"
    fixture.now = fixture.now + 6; assert(not load_text_config())
    assert(replay_seconds == 120)
    fixture.now = fixture.now + 6; assert(load_text_config())
    assert(replay_seconds == 240 and output_root == [[D:\Replays]])
end)
fixture.test("config rejects typos, invalid paths, duplicate and unbounded values", function()
    for _, text in ipairs({
        "root_folder=C:relative", "fullscreen_only=maybe", "default_replay_seconds=1e309",
        "default_replay_seconds=-1", "[unexpected]\nroot_folder=C:\\Replays",
        "root_folder=C:\\Replays\noutput_root=D:\\Replays", "[game_overrides]\ngame.exe=replay_seconds=oops",
        "[game_overrides]\ngame.exe=unknwon=true"
    }) do assert(not validate_text_config(text), text) end
end)
fixture.test("lazy replay routing preserves date format without repeated prefixes", function()
    fixture.select(); fixture.select()
    assert(fixture.output.format == "Game Alpha/%CCYY-%MM/%DD %hh-%mm-%ss")
    assert(fixture.output.directory == [[C:\Replays]])
    assert(fixture.profile["SimpleOutput.FilePath"] == [[C:\Recordings]])
end)
fixture.test("disabled OBS replay output waits without changing the profile", function()
    fixture.output = nil
    fixture.select(); fixture.select()
    assert(fixture.starts == 0 and fixture.profile["SimpleOutput.FilePath"] == [[C:\Recordings]])
    fixture.output = { directory = [[C:\Recordings]], format = "%CCYY" }
    fixture.select(); assert(fixture.starts == 1)
end)
fixture.test("excluded game cancels a start already in flight", function()
    fixture.defer_start = true; fixture.select()
    deactivate_active_game()
    assert(replay_state.starting and pending_replay_start_until > fixture.now)
    fixture.active = true; on_frontend_event(obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED)
    assert(not fixture.active and fixture.stops == 1)
    assert(fixture.profile["SimpleOutput.FilePath"] == [[C:\Recordings]])
end)
fixture.test("unavailable destination stops an owned buffer and later recovers", function()
    fixture.select(); output_root = [[E:\Missing]]; fixture.select()
    assert(not fixture.active and active_game_pid == nil)
    output_root = [[C:\Replays]]; fixture.select()
    assert(fixture.active and fixture.starts == 2)
end)
fixture.test("pause and resume stop only an owned buffer", function()
    fixture.select(); controls.pause(); poll_foreground_game()
    assert(not fixture.active and controls.paused and fixture.starts == 1)
    controls.resume(); poll_foreground_game()
    assert(fixture.active and fixture.starts == 2)
    fixture.reset(); fixture.active = true; fixture.select(); controls.pause()
    assert(fixture.active and fixture.stops == 0)
    assert(fixture.output.format == "%CCYY-%MM/%DD %hh-%mm-%ss")
end)
fixture.test("session ignore persists through polls and resume clears it", function()
    fixture.select(); controls.ignore(); poll_foreground_game(); poll_foreground_game()
    assert(not fixture.active and controls.ignored["1|game.exe"])
    controls.resume(); poll_foreground_game(); assert(fixture.active)
end)
fixture.test("background source loss stops buffer and source replacement recovers", function()
    fixture.select(); local audio = fixture.sources["Game Audio"]
    fixture.foreground = nil; fixture.sources["Game Audio"] = nil
    poll_foreground_game(); assert(not fixture.active)
    fixture.sources["Game Audio"] = audio; poll_foreground_game(); assert(fixture.active)
end)
fixture.test("removed sources retained by OBS are not treated as ready", function()
    fixture.select(); fixture.sources["Game Audio"].removed = true
    fixture.select(); assert(not fixture.active and controls.source_warning:find("Game Audio"))
    fixture.sources["Game Audio"].removed = false
    fixture.select(); assert(fixture.active)
end)
fixture.test("fallback requires explicit configuration and returns to primary", function()
    output_root = [[E:\Missing]]; fixture.select(); assert(not fixture.active)
    controls.fallback_root = [[D:\Replays]]; fixture.select()
    assert(fixture.active and active_output_root == [[D:\Replays]])
    output_root = [[C:\Replays]]; fixture.select(); fixture.now = fixture.now + 3; fixture.select()
    assert(active_output_root == [[C:\Replays]])
end)
fixture.test("low-space warning is cached and clears after recovery", function()
    controls.free_bytes = function() return 1073741824 end
    controls.check_storage([[C:\Replays]])
    assert(controls.storage_warning:find("Low space"))
    local logs = #fixture.logs; controls.check_storage([[C:\Replays]]); assert(#fixture.logs == logs)
    controls.free_bytes = function() return 100 * 1073741824 end
    fixture.now = fixture.now + 16; controls.check_storage([[C:\Replays]])
    assert(controls.storage_warning == nil)
end)
fixture.test("save confirmation uses actual output path; unconfirmed save warns", function()
    controls.save_replay(); assert(fixture.saves == 0)
    fixture.select(); controls.save_replay(); controls.save_replay(); assert(fixture.saves == 1)
    fixture.saved_path = [[C:\Replays\Game Alpha\clip.mkv]]
    on_frontend_event(obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED)
    assert(controls.last_saved == fixture.saved_path and controls.save_requested_at == nil)
    controls.save_replay(); fixture.now = fixture.now + 31; controls.check_save_timeout()
    assert(controls.notice:find("not confirmed") and controls.save_requested_at == nil)
end)
fixture.test("editor persists overrides without rewriting sidecar and can remove them", function()
    fixture.select(); controls.use_current()
    local settings, raw = controls.settings, fixture.raw
    settings.editor_folder = "Edited Game"; settings.editor_seconds = 77
    settings.editor_fullscreen = false; settings.editor_enabled = true
    controls.apply_editor(false)
    assert(settings.ui_game_overrides:find("replay_seconds=77", 1, true))
    assert(fixture.raw == raw)
    local name, rule = resolve_game_identity(fixture.info)
    assert(name == "Edited Game" and rule.replay_seconds == 77 and rule.fullscreen_only == false)
    controls.apply_editor(true)
    assert(resolve_game_identity(fixture.info) == "Game Alpha")
end)
fixture.test("editor validates input and merges sidecar-only options", function()
    fixture.select(); controls.use_current()
    local s = controls.settings
    s.editor_exe = "bad\n.exe"; controls.apply_editor(false)
    assert(s.ui_game_overrides == nil)
    s.editor_exe = "game.exe"; s.editor_seconds = 120; s.editor_folder = "Good"
    game_overrides = parse_game_overrides("game.exe=anti_cheat_hook=true;root_folder=D:\\Replays")
    controls.apply_editor(false)
    local rule = find_game_override(fixture.info)
    assert(rule.anti_cheat_hook == true and rule.root_folder == [[D:\Replays]])
    s.editor_enabled = false; controls.apply_editor(false); poll_foreground_game()
    assert(not fixture.active)
end)
fixture.test("Use current game preserves false fullscreen defaults", function()
    fullscreen_only = false; fixture.select(); controls.use_current()
    assert(controls.settings.editor_fullscreen == false)
end)
fixture.test("status displays state, destination, and confirmed clip", function()
    fixture.select(); controls.last_saved = [[C:\Replays\last.mkv]]
    local props = { automation_status = {} }; controls.refresh(props)
    assert(props.automation_status.text:find("Game Alpha", 1, true))
    assert(props.automation_status.text:find(controls.last_saved, 1, true))
    controls.pause(); controls.refresh(props)
    assert(props.automation_status.text:find("paused"))
end)
prune_game_identities(true)
return table.concat(fixture.results, "\n") .. "\nLua behavioral tests passed: " .. #fixture.results
