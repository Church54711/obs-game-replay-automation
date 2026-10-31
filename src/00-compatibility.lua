obs = obslua

-- Check capabilities rather than rejecting newer OBS version numbers.
-- If an API disappears, leave profiles, sources and replay buffers untouched.
local compatibility_error = nil
local required_obs_functions = {
	"calldata_create",
	"calldata_destroy",
	"calldata_string",
	"config_get_bool",
	"config_get_int",
	"config_get_string",
	"config_has_user_value",
	"config_remove_value",
	"config_save",
	"config_set_bool",
	"config_set_int",
	"config_set_string",
	"obs_data_addref",
	"obs_data_array_release",
	"obs_data_get_array",
	"obs_data_get_bool",
	"obs_data_get_int",
	"obs_data_get_string",
	"obs_data_release",
	"obs_data_set_array",
	"obs_data_set_bool",
	"obs_data_set_default_bool",
	"obs_data_set_default_int",
	"obs_data_set_default_string",
	"obs_data_set_int",
	"obs_data_set_string",
	"obs_enum_sources",
	"obs_frontend_add_event_callback",
	"obs_frontend_get_current_profile",
	"obs_frontend_get_profile_config",
	"obs_frontend_get_replay_buffer_output",
	"obs_frontend_remove_event_callback",
	"obs_frontend_replay_buffer_active",
	"obs_frontend_replay_buffer_save",
	"obs_frontend_replay_buffer_start",
	"obs_frontend_replay_buffer_stop",
	"obs_get_source_by_name",
	"obs_hotkey_load",
	"obs_hotkey_register_frontend",
	"obs_hotkey_save",
	"obs_hotkey_unregister",
	"obs_output_get_proc_handler",
	"obs_output_get_settings",
	"obs_output_release",
	"obs_output_update",
	"obs_properties_add_bool",
	"obs_properties_add_button",
	"obs_properties_add_int",
	"obs_properties_add_list",
	"obs_properties_add_path",
	"obs_properties_add_text",
	"obs_properties_create",
	"obs_properties_get",
	"obs_property_list_add_string",
	"obs_property_set_description",
	"obs_source_get_name",
	"obs_source_get_settings",
	"obs_source_get_unversioned_id",
	"obs_source_release",
	"obs_source_removed",
	"obs_source_update",
	"proc_handler_call",
	"script_log",
	"source_list_release",
	"timer_add",
	"timer_remove",
	"obs_data_create",
	"obs_data_create_from_json",
	"obs_data_create_from_json_file",
	"obs_data_get_json",
	"obs_data_get_json_with_defaults",
	"obs_data_get_obj",
	"obs_data_has_user_value",
	"obs_data_save_json_safe",
	"obs_data_set_obj",
	"obs_data_array_count",
	"obs_frontend_get_current_scene",
	"obs_frontend_recording_active",
	"obs_frontend_save",
	"obs_frontend_streaming_active",
	"obs_get_version_string",
	"obs_scene_add",
	"obs_scene_find_source_recursive",
	"obs_scene_from_source",
	"obs_source_create",
}
for _, name in ipairs(required_obs_functions) do
	if type(obslua[name]) ~= "function" then
		compatibility_error = "Missing OBS Lua API: " .. name
		break
	end
end
for _, name in ipairs({"OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED", "OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED"}) do
	if type(obslua[name]) ~= "number" then compatibility_error = "Missing OBS event: " .. name end
end
local ffi_ok, ffi = pcall(require, "ffi")
local bit_ok, bit = pcall(require, "bit")
if not ffi_ok or not bit_ok or ffi.os ~= "Windows" or ffi.arch ~= "x64" then
	compatibility_error = "Windows x64 OBS with LuaJIT is required"
end
if compatibility_error then
	local message = "Replay automation disabled: " .. compatibility_error .. ". Update the script or use a supported OBS build."
	function script_description() return message end
	if type(obslua.script_log) == "function" then obslua.script_log(obslua.LOG_WARNING, message) end
	return
end
