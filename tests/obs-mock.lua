-- No OBS process is loaded. Every OBS mutation is an in-memory operation.
fixture = { results = {}, now = 100, alive = {}, callback = nil }
obslua = {
    LOG_INFO = 200, LOG_WARNING = 300,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED = 1,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED = 2,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPING = 3,
    OBS_FRONTEND_EVENT_PROFILE_CHANGING = 4,
    OBS_FRONTEND_EVENT_PROFILE_CHANGED = 5,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED = 6,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVING = 7,
    script_log = function(level, message) table.insert(fixture.logs, message) end,
    obs_get_source_by_name = function(name) return fixture.sources[name] end,
    obs_source_get_unversioned_id = function(source) return source.id end,
    obs_source_release = function() end,
    obs_source_removed = function(source) return source.removed == true end,
    obs_source_get_settings = function(source) return source.settings end,
    obs_source_update = function() fixture.updates = fixture.updates + 1 end,
    obs_data_get_string = function(settings, key) return settings[key] or "" end,
    obs_data_get_int = function(settings, key) return settings[key] or 0 end,
    obs_data_get_bool = function(settings, key) return settings[key] == true end,
    obs_data_set_string = function(settings, key, value) settings[key] = value end,
    obs_data_set_int = function(settings, key, value) settings[key] = value end,
    obs_data_set_bool = function(settings, key, value) assert(type(value) == "boolean", "Expected boolean: " .. key); settings[key] = value end,
    obs_data_release = function() end,
    obs_frontend_get_profile_config = function() return fixture.profile end,
    obs_frontend_get_current_profile = function() return fixture.profile_name end,
    config_get_string = function(config, section, key) return config[section .. "." .. key] or "" end,
    config_get_int = function(config, section, key) return config[section .. "." .. key] or 0 end,
    config_get_bool = function(config, section, key) return config[section .. "." .. key] == true end,
    config_set_string = function(config, section, key, value) config[section .. "." .. key] = value end,
    config_set_int = function(config, section, key, value) config[section .. "." .. key] = value end,
    config_set_bool = function(config, section, key, value) config[section .. "." .. key] = value end,
    config_has_user_value = function(config, section, key) return config[section .. "." .. key] ~= nil end,
    config_remove_value = function(config, section, key) config[section .. "." .. key] = nil end,
    config_save = function() end,
    obs_frontend_replay_buffer_active = function() return fixture.active end,
    obs_frontend_replay_buffer_start = function()
        fixture.starts = fixture.starts + 1
        fixture.start_seconds = fixture.profile["SimpleOutput.RecRBTime"]
        if fixture.defer_start then return end
        fixture.active = true
        fixture.output = { directory = fixture.profile["SimpleOutput.FilePath"], format = "%CCYY-%MM/%DD %hh-%mm-%ss" }
        fixture.callback(obslua.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED)
    end,
    obs_frontend_replay_buffer_stop = function()
        fixture.stops = fixture.stops + 1
        fixture.callback(obslua.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPING)
        if fixture.defer_stop then return end
        fixture.active = false
        fixture.callback(obslua.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED)
    end,
    obs_frontend_get_replay_buffer_output = function() return fixture.output end,
    obs_output_get_settings = function(output) return output end,
    obs_output_update = function() end,
    obs_output_release = function() end,
    timer_remove = function() end,
    timer_add = function() end,
    obs_frontend_remove_event_callback = function() end,
    obs_frontend_replay_buffer_save = function() fixture.saves = (fixture.saves or 0) + 1 end,
    obs_output_get_proc_handler = function(output) return output end,
    calldata_create = function() return {} end,
    calldata_destroy = function() end,
    calldata_string = function(data, key) return data[key] or "" end,
    proc_handler_call = function(_, name, data) data.path = fixture.saved_path; return true end,
    obs_properties_get = function(props, key) return props[key] end,
    obs_property_set_description = function(prop, value) prop.text = value end,
}
function script_path() return "" end
