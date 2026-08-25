obs = obslua

local replay_active_since = nil
local replay_save_requested = false
local save_delay_seconds = 8

local function request_runtime_replay_save()
	if replay_save_requested or not obs.obs_frontend_replay_buffer_active() then
		return
	end

	local now = os.time()
	if replay_active_since == nil then
		replay_active_since = now
		obs.script_log(obs.LOG_INFO, "Runtime routing fixture observed an active replay buffer.")
		return
	end
	if now - replay_active_since < save_delay_seconds then
		return
	end

	replay_save_requested = true
	obs.script_log(obs.LOG_INFO, "Runtime routing fixture requested replay save.")
	obs.obs_frontend_replay_buffer_save()
	obs.timer_remove(request_runtime_replay_save)
end

local function on_frontend_event(event)
	if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
		obs.script_log(obs.LOG_INFO, "Runtime routing fixture observed replay saved.")
	end
end

function script_description()
	return "Test-only helper that saves one replay after the replay buffer has been active for eight seconds."
end

function script_load(settings)
	obs.obs_frontend_add_event_callback(on_frontend_event)
	obs.timer_add(request_runtime_replay_save, 250)
end

function script_unload()
	obs.timer_remove(request_runtime_replay_save)
	obs.obs_frontend_remove_event_callback(on_frontend_event)
end
