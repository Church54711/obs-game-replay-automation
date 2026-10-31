local function trim(value)
	return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local expand_environment_strings = nil

local function clean_root_path(value)
	value = trim(value)
	if #value >= 2 and value:sub(1, 1) == '"' and value:sub(-1) == '"' then
		value = trim(value:sub(2, -2))
	end
	if expand_environment_strings ~= nil then
		value = expand_environment_strings(value)
	end
	value = value:gsub("/", "\\")
	while #value > 3 and value:match("[\\/]$") do
		value = value:sub(1, -2)
	end
	return value
end

local function is_absolute_windows_path(value)
	value = (value or ""):gsub("/", "\\")
	if value:match("^%a:\\") then
		return true
	end
	return value:match("^\\\\[^\\]+\\[^\\]+") ~= nil
end

local function now_seconds()
	return tonumber(kernel32.GetTickCount64()) / 1000
end

local function config_bool(value)
	value = trim(value):lower()
	if value == "1" or value == "true" or value == "yes" or value == "on" then
		return true
	end
	if value == "0" or value == "false" or value == "no" or value == "off" then
		return false
	end
	return nil
end

local function number_or(value, fallback)
	local number = tonumber(value)
	if number == nil then
		return fallback
	end
	return number
end

local function is_null(value)
	return value == nil or value == null
end

local function copy_default_excluded_exes()
	local values = {}
	for exe, enabled in pairs(default_excluded_exes) do
		values[exe] = enabled
	end
	return values
end

local function sorted_default_excluded_text()
	local values = {}
	for exe, _ in pairs(default_excluded_exes) do
		table.insert(values, exe)
	end
	table.sort(values)
	return table.concat(values, "\n")
end

local function get_config_file_path()
	if config_file_path == nil then
		config_file_path = script_path() .. "game-replay-auto-config.txt"
	end
	return config_file_path
end

local function read_file(path)
	local file = io.open(path, "r")
	if file == nil then
		return nil
	end

	local contents = file:read("*a")
	file:close()
	return contents
end

local function apply_base_settings()
	if base_settings == nil then
		return
	end

	game_capture_source = base_settings.game_capture_source
	game_audio_source = base_settings.game_audio_source
	output_root = base_settings.output_root
	poll_interval_ms = base_settings.poll_interval_ms
	minimum_window_area_percent = base_settings.minimum_window_area_percent
	fullscreen_only = base_settings.fullscreen_only
	fullscreen_min_coverage_percent = base_settings.fullscreen_min_coverage_percent
	stable_poll_count = base_settings.stable_poll_count
	match_priority = base_settings.match_priority
	start_replay_buffer = base_settings.start_replay_buffer
	replay_seconds = base_settings.replay_seconds
	restart_replay_buffer_on_game_change = base_settings.restart_replay_buffer_on_game_change
	stop_replay_buffer_when_game_exits = base_settings.stop_replay_buffer_when_game_exits
	game_exit_stop_delay_seconds = base_settings.game_exit_stop_delay_seconds
	game_rules = base_settings.game_rules
	game_overrides = base_settings.game_overrides
	excluded_exes = base_settings.excluded_exes
end

local function parse_match_expression(value)
	local exe = trim(value or "")
	local title = ""
	local pipe_at = exe:find("|", 1, true)
	if pipe_at ~= nil then
		title = trim(exe:sub(pipe_at + 1)):lower()
		exe = trim(exe:sub(1, pipe_at - 1))
	end
	return exe:lower(), title
end

local function parse_key_values(raw)
	local values = {}
	for part in (raw or ""):gmatch("[^;]+") do
		part = trim(part)
		if part ~= "" then
			local key, value = part:match("^([%w_]+)%s*=%s*(.-)%s*$")
			if key ~= nil then
				values[key:lower()] = trim(value)
			elseif values.folder == nil then
				values.folder = part
			end
		end
	end
	return values
end

local function optional_config_bool(values, key, fallback)
	if values[key] == nil then
		return fallback
	end
	local parsed = config_bool(values[key])
	if parsed == nil then
		return fallback
	end
	return parsed
end

local function parse_game_rules(raw)
	local rules = {}
	for line in (raw or ""):gmatch("[^\r\n]+") do
		line = trim(line)
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local left, name = line:match("^([^=]+)=(.+)$")
			if left ~= nil and name ~= nil then
				left = trim(left)
				name = trim(name)
				local exe, title = parse_match_expression(left)
				if exe ~= "" and name ~= "" then
					table.insert(rules, { exe = exe, title = title, name = name })
				end
			end
		end
	end
	return rules
end

local function parse_game_overrides(raw)
	local overrides = {}
	for line in (raw or ""):gmatch("[^\r\n]+") do
		line = trim(line)
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local left, right = line:match("^([^=]+)=(.+)$")
			if left ~= nil and right ~= nil then
				local exe, title = parse_match_expression(left)
				local values = parse_key_values(right)
				if exe ~= "" then
					table.insert(overrides, {
						exe = exe,
						title = title,
						folder = values.folder,
						root_folder = values.root_folder or values.output_root,
						replay_seconds = tonumber(values.replay_seconds),
						stop_delay_seconds = tonumber(values.stop_delay_seconds),
						match_priority = tonumber(values.match_priority),
						anti_cheat_hook = optional_config_bool(values, "anti_cheat_hook", nil),
						fullscreen_only = optional_config_bool(values, "fullscreen_only", nil),
						enabled = optional_config_bool(values, "enabled", nil),
					})
				end
			end
		end
	end
	return overrides
end

local function parse_excluded_exes(raw, inherited_values)
	local values = copy_default_excluded_exes()
	for exe, enabled in pairs(inherited_values or {}) do
		if enabled then
			values[exe] = true
		end
	end
	for part in (raw or ""):gmatch("[^\r\n,;]+") do
		local exe = trim(part):lower()
		if exe ~= "" then
			values[exe] = true
		end
	end
	return values
end

local function parse_text_config(raw)
	local parsed = {
		game_rules_text = nil,
		game_overrides_text = nil,
		excluded_exes_text = nil,
	}
	local section = ""
	local game_rule_lines = {}
	local game_override_lines = {}
	local excluded_lines = {}
	local saw_game_folders = false
	local saw_game_overrides = false
	local saw_ignored_exes = false

	for line in (raw or ""):gmatch("[^\r\n]+") do
		line = line:gsub("^\239\187\191", "")
		line = trim(line)
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local new_section = line:match("^%[([^%]]+)%]$")
			if new_section ~= nil then
				section = trim(new_section):lower()
				if section == "game_folders" then
					saw_game_folders = true
				elseif section == "game_overrides" then
					saw_game_overrides = true
				elseif section == "ignored_exes" then
					saw_ignored_exes = true
				end
			elseif section == "game_folders" then
				table.insert(game_rule_lines, line)
			elseif section == "game_overrides" then
				table.insert(game_override_lines, line)
			elseif section == "ignored_exes" then
				table.insert(excluded_lines, line)
			else
				local key, value = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
				if key ~= nil then
					key = key:lower()
					value = trim(value)
					if key == "root_folder" or key == "output_root" then
						parsed.output_root = value
					elseif key == "game_capture_source" then
						parsed.game_capture_source = value
					elseif key == "game_audio_source" then
						parsed.game_audio_source = value
					elseif key == "fullscreen_only" then
						parsed.fullscreen_only = config_bool(value)
					elseif key == "fullscreen_min_coverage_percent" then
						parsed.fullscreen_min_coverage_percent = tonumber(value)
					elseif key == "match_priority" then
						parsed.match_priority = tonumber(value)
					elseif key == "replay_seconds" or key == "default_replay_seconds" then
						parsed.replay_seconds = tonumber(value)
					elseif key == "stop_replay_buffer_when_game_exits" then
						parsed.stop_replay_buffer_when_game_exits = config_bool(value)
					elseif key == "game_exit_stop_delay_seconds" then
						parsed.game_exit_stop_delay_seconds = tonumber(value)
					end
				end
			end
		end
	end

	if saw_game_folders then
		parsed.game_rules_text = table.concat(game_rule_lines, "\n")
	end
	if saw_game_overrides then
		parsed.game_overrides_text = table.concat(game_override_lines, "\n")
	end
	if saw_ignored_exes then
		parsed.excluded_exes_text = table.concat(excluded_lines, "\n")
	end

	return parsed
end

local function validate_text_config(raw)
	local section, line_number, meaningful = "", 0, false
	local seen = {}
	local booleans = { fullscreen_only = true, stop_replay_buffer_when_game_exits = true,
		anti_cheat_hook = true, enabled = true }
	local numbers = { fullscreen_min_coverage_percent = {1, 100}, match_priority = {0, 2},
		replay_seconds = {1, 86400}, default_replay_seconds = {1, 86400},
		game_exit_stop_delay_seconds = {0, 86400}, stop_delay_seconds = {0, 86400} }
	local globals = { root_folder = true, output_root = true, game_capture_source = true,
		game_audio_source = true, fullscreen_only = true, fullscreen_min_coverage_percent = true,
		match_priority = true, replay_seconds = true, default_replay_seconds = true,
		stop_replay_buffer_when_game_exits = true, game_exit_stop_delay_seconds = true }
	local overrides = { folder = true, root_folder = true, output_root = true, fullscreen_only = true,
		match_priority = true, replay_seconds = true, stop_delay_seconds = true,
		anti_cheat_hook = true, enabled = true }
	local function valid_value(key, value)
		if booleans[key] then return config_bool(value) ~= nil end
		if numbers[key] then
			local n, bounds = tonumber(value), numbers[key]
			return n ~= nil and n == math.floor(n) and n >= bounds[1] and n <= bounds[2]
		end
		if key == "root_folder" or key == "output_root" then
			return is_absolute_windows_path(clean_root_path(value))
		end
		return trim(value) ~= ""
	end
	for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
		line_number = line_number + 1
		line = trim(line:gsub("^\239\187\191", ""))
		if line ~= "" and line:sub(1, 1) ~= "#" then
			meaningful = true
			local next_section = line:match("^%[([^%]]+)%]$")
			local valid = true
			if next_section then
				section = trim(next_section):lower()
				valid = section == "game_folders" or section == "game_overrides" or section == "ignored_exes"
			elseif section == "ignored_exes" then
				valid = line:lower():match("^[^=|/\\]+%.exe$") ~= nil
			elseif section == "game_folders" or section == "game_overrides" then
				local left, right = line:match("^([^=]+)=(.+)$")
				valid = left ~= nil and trim(right or "") ~= ""
				if valid then
					local exe = parse_match_expression(left)
					valid = exe:match("%.exe$") ~= nil
				end
				if valid and section == "game_overrides" then
					local keys = {}
					for part in right:gmatch("[^;]+") do
						local key, value = trim(part):match("^([%w_]+)%s*=%s*(.-)%s*$")
						if key then
							key = key:lower()
							if not overrides[key] or keys[key] or not valid_value(key, value) then valid = false end
							keys[key] = true
						elseif keys.folder or part:find("=", 1, true) then
							valid = false
						else keys.folder = true end
					end
				end
			else
				local key, value = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
				key = key and key:lower()
				local canonical = key == "output_root" and "root_folder" or key
				if key == "default_replay_seconds" then canonical = "replay_seconds" end
				valid = key ~= nil and globals[key] and not seen[canonical] and valid_value(key, value)
				if canonical then seen[canonical] = true end
			end
			if not valid then return false, "Invalid configuration at line " .. line_number .. ": " .. line end
		end
	end
	return meaningful, meaningful and nil or "Configuration is empty"
end

local function load_text_config(force)
    if user_store.ready then return false end -- Legacy text is imported once.
	local now = now_seconds()
	if not force and now - config_last_checked_at < config_reload_interval_seconds then
		return false
	end
	config_last_checked_at = now

	local raw = read_file(get_config_file_path())
	local valid, problem = false, "Cannot read configuration; retaining the last valid settings"
	if raw ~= nil then valid, problem = validate_text_config(raw) end
	if not valid then
		config_pending_raw = nil
		if problem ~= config_last_error then
			obs.script_log(obs.LOG_WARNING, problem .. "; configuration was not replaced.")
			config_last_error = problem
		end
		if not force then return false end
		raw = config_last_raw
		if raw == nil then apply_base_settings(); return false end
	elseif config_last_raw ~= nil and raw ~= config_last_raw and raw ~= config_pending_raw then
		-- Editors may truncate/rewrite the file. Require two identical reads.
		config_pending_raw = raw
		if not force then return false end
		raw = config_last_raw
	else
		config_pending_raw = nil
		config_last_error = nil
	end
	if not force and raw == config_last_raw then return false end

	config_last_raw = raw
	apply_base_settings()

	local parsed = parse_text_config(raw)
	if parsed.output_root ~= nil and clean_root_path(parsed.output_root) ~= "" then
		local parsed_output_root = clean_root_path(parsed.output_root)
		if is_absolute_windows_path(parsed_output_root) then
			output_root = parsed_output_root
			last_invalid_output_root = nil
		elseif parsed_output_root ~= last_invalid_output_root then
			last_invalid_output_root = parsed_output_root
			obs.script_log(obs.LOG_WARNING, "Ignoring non-absolute root_folder path: " .. parsed_output_root)
		end
	end
	if parsed.game_capture_source ~= nil and trim(parsed.game_capture_source) ~= "" then
		game_capture_source = trim(parsed.game_capture_source)
	end
	if parsed.game_audio_source ~= nil and trim(parsed.game_audio_source) ~= "" then
		game_audio_source = trim(parsed.game_audio_source)
	end
	if parsed.fullscreen_only ~= nil then
		fullscreen_only = parsed.fullscreen_only
	end
	if parsed.fullscreen_min_coverage_percent ~= nil then
		fullscreen_min_coverage_percent = math.max(1, math.min(100, parsed.fullscreen_min_coverage_percent))
	end
	if parsed.match_priority ~= nil then
		match_priority = math.max(0, math.min(2, parsed.match_priority))
	end
	if parsed.replay_seconds ~= nil then
		replay_seconds = math.max(1, parsed.replay_seconds)
	end
	if parsed.stop_replay_buffer_when_game_exits ~= nil then
		stop_replay_buffer_when_game_exits = parsed.stop_replay_buffer_when_game_exits
	end
	if parsed.game_exit_stop_delay_seconds ~= nil then
		game_exit_stop_delay_seconds = math.max(0, parsed.game_exit_stop_delay_seconds)
	end
	if parsed.game_rules_text ~= nil then
		game_rules = parse_game_rules(parsed.game_rules_text)
	end
	if parsed.game_overrides_text ~= nil then
		game_overrides = parse_game_overrides(parsed.game_overrides_text)
	end
	if parsed.excluded_exes_text ~= nil then
		-- The sidecar section is documented as extra ignored executables. Keep
		-- exclusions saved in OBS's script settings instead of replacing them.
		excluded_exes = parse_excluded_exes(parsed.excluded_exes_text, excluded_exes)
	end

	configuration_revision = configuration_revision + 1
	return true
end
