-- Versioned preferences under the chosen OBS configuration root.
pcall(ffi.cdef, [[
HANDLE CreateFileW(const wchar_t *, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
BOOL WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
BOOL ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
DWORD GetFileSize(HANDLE, DWORD *);
BOOL MoveFileExW(const wchar_t *, const wchar_t *, DWORD);
BOOL CopyFileW(const wchar_t *, const wchar_t *, BOOL);
BOOL DeleteFileW(const wchar_t *);
int SHCreateDirectoryExW(HWND, const wchar_t *, void *);
]])
user_store.fields = {
    game_capture_source="string", game_audio_source="string", output_root="string",
    poll_interval_ms="int", minimum_window_area_percent="int", fullscreen_only="bool",
    fullscreen_min_coverage_percent="int", stable_poll_count="int", match_priority="int",
    start_replay_buffer="bool", restart_replay_buffer_on_game_change="bool",
    stop_replay_buffer_when_game_exits="bool", game_exit_stop_delay_seconds="int",
    default_replay_seconds="int", game_rules="string", game_overrides="string",
    excluded_exes="string", ui_game_overrides="string", save_sound="bool",
    low_space_gib="int", fallback_root="string",
}
user_store.bounds = {
    poll_interval_ms={500,10000}, minimum_window_area_percent={0,100},
    fullscreen_min_coverage_percent={1,100}, stable_poll_count={1,10}, match_priority={0,2},
    game_exit_stop_delay_seconds={0,86400}, default_replay_seconds={0,86400}, low_space_gib={0,10000},
}
user_store.hotkey_names = {"pause", "resume", "ignore", "save", "open"}
function user_store.exists(path)
    return kernel32.GetFileAttributesW(utf8_to_wide(path)) ~= INVALID_FILE_ATTRIBUTES
end
function user_store.mkdir(path)
    local result = controls.shell.SHCreateDirectoryExW(nil, utf8_to_wide(path), nil)
    return result == 0 or result == 183
end
function user_store.write_text(path, text)
    local temporary = path .. ".tmp"
    local handle = kernel32.CreateFileW(utf8_to_wide(temporary), 0x40000000, 0, nil, 2, 0x80, nil)
    if is_null(handle) or handle == ffi.cast("void *", -1) then return false end
    local written = ffi.new("DWORD[1]")
    local ok = kernel32.WriteFile(handle, text, #text, written, nil) ~= 0 and tonumber(written[0]) == #text
    kernel32.CloseHandle(handle)
    if ok then ok = kernel32.MoveFileExW(utf8_to_wide(temporary), utf8_to_wide(path), 9) ~= 0 end
    if not ok then kernel32.DeleteFileW(utf8_to_wide(temporary)) end
    return ok
end
function user_store.read_text(path)
    local handle = kernel32.CreateFileW(utf8_to_wide(path), 0x80000000, 1, nil, 3, 0x80, nil)
    if is_null(handle) or handle == ffi.cast("void *", -1) then return nil end
    local high = ffi.new("DWORD[1]")
    local size = tonumber(kernel32.GetFileSize(handle, high))
    local text = nil
    if high[0] == 0 and size <= 1048576 then
        local buffer, count = ffi.new("char[?]", math.max(1,size)), ffi.new("DWORD[1]")
        if kernel32.ReadFile(handle, buffer, size, count, nil) ~= 0 and tonumber(count[0]) == size then text = ffi.string(buffer,size) end
    end
    kernel32.CloseHandle(handle)
    return text
end
function user_store.copy_values(source, target)
    for key, kind in pairs(user_store.fields) do
        if obs.obs_data_has_user_value(source, key) then
            obs["obs_data_set_" .. kind](target, key, obs["obs_data_get_" .. kind](source, key))
        end
    end
    for _, name in ipairs(user_store.hotkey_names) do
        local key = "hotkey_" .. name
        if obs.obs_data_has_user_value(source, key) then
            local data = obs.obs_data_get_array(source, key)
            if data then obs.obs_data_set_array(target, key, data); obs.obs_data_array_release(data) end
        end
    end
end
function user_store.snapshot(settings)
    local document = obs.obs_data_create()
    local values = obs.obs_data_create_from_json(obs.obs_data_get_json_with_defaults(settings))
    local selected = obs.obs_data_create()
    user_store.copy_values(values, selected)
    obs.obs_data_set_int(document, "schemaVersion", 1)
    obs.obs_data_set_obj(document, "settings", selected)
    obs.obs_data_release(values); obs.obs_data_release(selected)
    return document
end
function user_store.json_types(json)
    -- OBS has already parsed the JSON. Inspect only top-level value types;
    -- obs_data_item_release takes a pointer-to-pointer that SWIG cannot accept
    -- from Lua, so borrowing data items here would leak references.
    local types, numbers, index = {}, {}, 2
    local function whitespace()
        while json:sub(index,index):match("%s") do index = index + 1 end
    end
    local function string_end(start)
        local pos = start + 1
        while pos <= #json do
            local char = json:sub(pos,pos)
            if char == "\\" then pos = pos + 2
            elseif char == '"' then return pos + 1
            else pos = pos + 1 end
        end
        return #json + 1
    end
    while index <= #json do
        whitespace()
        if json:sub(index,index) ~= '"' then break end
        local ending = string_end(index)
        local key = json:sub(index+1, ending-2)
        index = ending; whitespace()
        if json:sub(index,index) ~= ":" then break end
        index = index + 1; whitespace()
        local first = json:sub(index,index)
        if first:match("[%d%-]") then numbers[key] = tonumber(json:sub(index):match("^[^,%}%]%s]+")) end
        types[key] = first == '"' and "string" or ((first == "t" or first == "f") and "bool"
            or (first:match("[%d%-]") and "int" or (first == "[" and "array" or "other")))
        local depth = 0
        while index <= #json do
            local char = json:sub(index,index)
            if char == '"' then index = string_end(index)
            elseif (char == "," or char == "}") and depth == 0 then break
            else
                if char == "{" or char == "[" then depth = depth + 1 end
                if char == "}" or char == "]" then depth = depth - 1 end
                index = index + 1
            end
        end
        if json:sub(index,index) == "}" then break end
        index = index + 1
    end
    return types, numbers
end
function user_store.validate(document)
    if not document then return false, "Cannot read settings JSON" end
    local _, versions = user_store.json_types(obs.obs_data_get_json(document))
    if versions.schemaVersion ~= 1 then return false, "Unsupported settings schema" end
    local values = obs.obs_data_get_obj(document, "settings")
    if not values then return false, "Settings object is missing" end
    local problem = nil
    local types, numbers = user_store.json_types(obs.obs_data_get_json(values))
    for key, kind in pairs(user_store.fields) do
        if obs.obs_data_has_user_value(values, key) then
            if types[key] ~= kind then problem = "Invalid setting type: " .. key end
            if kind == "int" then
                local number, bounds = numbers[key], user_store.bounds[key]
                if not number or number ~= math.floor(number) or (bounds and (number < bounds[1] or number > bounds[2])) then problem = "Setting is out of range: " .. key end
            end
        end
    end
    for _, name in ipairs(user_store.hotkey_names) do
        local key = "hotkey_" .. name
        if obs.obs_data_has_user_value(values, key) and types[key] ~= "array" then problem = "Invalid hotkey bindings" end
    end
    local root = obs.obs_data_get_string(values, "output_root")
    if root == "" or not is_absolute_windows_path(clean_root_path(root)) then problem = "Replay folder must be an absolute path" end
    local fallback = obs.obs_data_get_string(values, "fallback_root")
    if fallback ~= "" and not is_absolute_windows_path(clean_root_path(fallback)) then problem = "Fallback folder must be an absolute path" end
    for _, key in ipairs({"game_capture_source", "game_audio_source"}) do
        if trim(obs.obs_data_get_string(values, key)) == "" then problem = "Capture source name is empty" end
    end
    for _, key in ipairs({"game_overrides", "ui_game_overrides"}) do
        local rules = obs.obs_data_get_string(values, key)
        if rules ~= "" then
            local ok = validate_text_config("root_folder=" .. root .. "\n[game_overrides]\n" .. rules)
            if not ok then problem = "Invalid per-game rules" end
        end
    end
    local folders = obs.obs_data_get_string(values, "game_rules")
    if folders ~= "" and not validate_text_config("root_folder=" .. root .. "\n[game_folders]\n" .. folders) then problem = "Invalid game folder rules" end
    obs.obs_data_release(values)
    return problem == nil, problem
end
function user_store.fail(message)
    user_store.error = message
    controls.message = "Settings need attention"
    obs.script_log(obs.LOG_WARNING, message)
    return false
end
function user_store.resolve_path()
    local record_path = script_path() .. "game-replay-installation.json"
    if user_store.exists(record_path) then
        local record = obs.obs_data_create_from_json_file(record_path)
        if not record then return user_store.fail("Cannot read installation record") end
        local valid = obs.obs_data_get_int(record, "schemaVersion") == 1 and
            obs.obs_data_get_string(record, "product") == "obs-game-replay-automation" and
            clean_root_path(obs.obs_data_get_string(record, "scriptsDir")):lower() == clean_root_path(script_path()):lower()
        user_store.directory = clean_root_path(obs.obs_data_get_string(record, "settingsDir"))
        obs.obs_data_release(record)
        if not valid or not is_absolute_windows_path(user_store.directory) then return user_store.fail("Invalid installation record") end
    else
        user_store.directory = clean_root_path([[%APPDATA%\obs-studio\game-replay-automation]])
    end
    user_store.path = user_store.directory .. "\\settings.json"
    return true
end
function user_store.save(settings)
    if user_store.disabled or not user_store.ready or user_store.error then return false end
    local document = user_store.snapshot(settings)
    local valid, problem = user_store.validate(document)
    if not valid then obs.obs_data_release(document); controls.notice = "Settings not saved: " .. problem; return false end
    local json = obs.obs_data_get_json(document)
    if json == user_store.disk_json then obs.obs_data_release(document); return true end
    if not user_store.mkdir(user_store.directory) then obs.obs_data_release(document); return user_store.fail("User settings folder is not writable") end
    local lock = kernel32.CreateFileW(utf8_to_wide(user_store.path .. ".lock"), 0xC0000000, 0, nil, 4, 0x80, nil)
    if is_null(lock) or lock == ffi.cast("void *", -1) then obs.obs_data_release(document); return user_store.fail("Settings are being written by another OBS instance; reload this script") end
    local current = obs.obs_data_create_from_json_file(user_store.path)
    local current_json = current and obs.obs_data_get_json(current) or nil
    if current then obs.obs_data_release(current) end
    local ok = false
    if current_json == user_store.disk_json and (current_json or not user_store.exists(user_store.path)) then
        ok = obs.obs_data_save_json_safe(document, user_store.path, "tmp", "bak")
    end
    kernel32.CloseHandle(lock)
    obs.obs_data_release(document)
    if not ok then return user_store.fail("Settings could not be saved or changed in another OBS instance; reload this script") end
    user_store.disk_json = json
    return true
end
function user_store.initialize(settings)
    if user_store.disabled or user_store.initialized then return end
    user_store.initialized = true
    if not user_store.resolve_path() then return end
    if user_store.exists(user_store.path) then
        local document = obs.obs_data_create_from_json_file(user_store.path)
        local valid, problem = user_store.validate(document)
        if valid then
            local values = obs.obs_data_get_obj(document, "settings")
            user_store.copy_values(values, settings)
            obs.obs_data_release(values)
            user_store.disk_json = obs.obs_data_get_json(document)
            user_store.ready = true
        else user_store.fail(problem .. "; original file preserved. Restore a backup or import a valid export.") end
        if document then obs.obs_data_release(document) end
        return
    end
    -- Import the old precedence once: defaults < OBS script values < sidecar.
    local original = obs.obs_data_create_from_json(obs.obs_data_get_json(settings))
    local raw = user_store.read_text(get_config_file_path())
    if not raw and user_store.exists(get_config_file_path()) then
        obs.obs_data_release(original); user_store.fail("Cannot read legacy configuration; migration was not performed"); return
    end
    if raw then
        local valid, problem = validate_text_config(raw)
        if not valid then obs.obs_data_release(original); user_store.fail(problem .. "; migration was not performed"); return end
        local parsed = parse_text_config(raw)
        local map = {replay_seconds="default_replay_seconds", game_rules_text="game_rules", game_overrides_text="game_overrides"}
        for key, value in pairs(parsed) do
            local destination = map[key] or key
            if user_store.fields[destination] then obs["obs_data_set_" .. user_store.fields[destination]](settings, destination, value) end
        end
        if parsed.excluded_exes_text then
            obs.obs_data_set_string(settings, "excluded_exes", obs.obs_data_get_string(settings, "excluded_exes") .. "\n" .. parsed.excluded_exes_text)
        end
    end
    if not user_store.mkdir(user_store.directory) then obs.obs_data_release(original); user_store.fail("Cannot create user settings folder"); return end
    local backed_up = obs.obs_data_save_json_safe(original, user_store.directory .. "\\migration-obs-settings.json", "tmp", "bak")
    obs.obs_data_release(original)
    if raw then
        local backup = user_store.directory .. "\\migration-sidecar.txt"
        backed_up = (user_store.exists(backup) or kernel32.CopyFileW(utf8_to_wide(get_config_file_path()), utf8_to_wide(backup), 1) ~= 0) and backed_up
    end
    if not backed_up then user_store.fail("Migration backup could not be written; original settings preserved"); return end
    user_store.ready = true
    user_store.save(settings)
end
function user_store.transfer(importing)
    if not user_store.path then controls.notice = "Repair the installation record before importing settings"; return true end
    local path = clean_root_path(obs.obs_data_get_string(controls.settings, "settings_transfer_path"))
    if not is_absolute_windows_path(path) then controls.notice = "Choose an absolute JSON file path first"; return true end
    if importing then
        local document = obs.obs_data_create_from_json_file(path)
        local valid, problem = user_store.validate(document)
        if valid then
            if not user_store.mkdir(user_store.directory) then
                obs.obs_data_release(document); controls.notice = "Cannot create settings folder"; return true
            end
            local lock = kernel32.CreateFileW(utf8_to_wide(user_store.path .. ".lock"), 0xC0000000, 0, nil, 4, 0x80, nil)
            if is_null(lock) or lock == ffi.cast("void *", -1) then
                obs.obs_data_release(document); controls.notice = "Settings are being written by another OBS instance; try again"; return true
            end
            user_store.import_sequence = (user_store.import_sequence or 0) + 1
            local backup_path = user_store.path .. ".before-import-" .. tostring(math.floor(now_seconds()*1000)) .. "-" .. user_store.import_sequence
            local backed_up = not user_store.exists(user_store.path) or kernel32.CopyFileW(utf8_to_wide(user_store.path), utf8_to_wide(backup_path), 1) ~= 0
            local saved = backed_up and obs.obs_data_save_json_safe(document, user_store.path, "tmp", "bak")
            kernel32.CloseHandle(lock)
            if not saved then
                controls.notice = "Could not back up or write settings; import was not applied"
                obs.obs_data_release(document); return true
            end
            local values = obs.obs_data_get_obj(document, "settings")
            user_store.copy_values(values, controls.settings); obs.obs_data_release(values)
            user_store.disk_json = obs.obs_data_get_json(document)
            user_store.error = nil; user_store.ready = true
            script_update(controls.settings)
            for name, hotkey in pairs(controls.hotkeys) do
                local data = obs.obs_data_get_array(controls.settings, "hotkey_" .. name)
                obs.obs_hotkey_load(hotkey.id, data); obs.obs_data_array_release(data)
            end
            controls.notice = user_store.error or "Settings imported; previous file retained as a backup"
        else controls.notice = problem .. "; import did not change your settings" end
        if document then obs.obs_data_release(document) end
    else
        if path:lower() == user_store.path:lower() then controls.notice = "Choose a separate file for the export"; return true end
        local document = user_store.snapshot(controls.settings)
        local ok = obs.obs_data_save_json_safe(document, path, "tmp", "bak")
        obs.obs_data_release(document)
        controls.notice = ok and "Settings exported (contains your folder paths and game rules)" or "Cannot write export file"
    end
    return true
end
