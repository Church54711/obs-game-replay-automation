function poll_foreground_game()
    if user_store.error then
        if replay_state.owned then stop_owned_replay_buffer() end
        controls.message = "Settings need attention: " .. user_store.error
        return
    end
	load_text_config()
	prune_game_identities(false)
	controls.check_save_timeout()
	if controls.paused then controls.message = "Automation paused"; return end
	if replay_state.profile_changing then return end
	if active_game_is_disabled() then deactivate_active_game() end
	synchronize_saved_capture_hook_policy()
	if replay_state.starting then maybe_start_pending_replay_buffer() end

	local info = get_foreground_game_window()
	if info and not info.is_excluded and info.exe ~= "obs64.exe" then controls.last_detected = info end
	local now = now_seconds()
	maybe_stop_replay_buffer_after_game_exit(now)
	-- Continue validating the tracked game's sources and storage while the
	-- user is in OBS or another application. No new foreground game is selected.
	if active_game_pid and active_game_process_is_running() and controls.active_info
		and (not info or build_process_identity_key(info) ~= active_process_key) then
		local tracked = controls.active_info
		local name, rule, key = resolve_game_identity(tracked)
		configure_for_game(tracked, name, rule, key, build_window_identity_key(tracked))
	end
	if info == nil then
		candidate_key = nil
		candidate_count = 0
		maybe_stop_replay_buffer_after_game_exit(now)
		return
	end

	local game_name, override, process_key = resolve_game_identity(info)
	if controls.ignored[process_key] then controls.message = "Ignored for this session: " .. info.exe; return end
	if not game_window_is_eligible(info, override) then
		if active_game_pid == nil then
			controls.message = (info.is_excluded or (override and override.enabled == false))
				and ("Excluded: " .. info.exe) or ("Window is not fullscreen: " .. info.exe)
		end
		candidate_key = nil
		candidate_count = 0
		maybe_stop_replay_buffer_after_game_exit(now)
		return
	end

	local new_candidate_key = build_window_identity_key(info)
	if new_candidate_key ~= candidate_key then
		candidate_key = new_candidate_key
		candidate_count = 1
	else
		candidate_count = candidate_count + 1
	end

	if candidate_count < stable_poll_count then
		return
	end

	configure_for_game(info, game_name, override, process_key, new_candidate_key)
end
