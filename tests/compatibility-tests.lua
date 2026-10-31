local symbols = {}
for name in automation_source:gmatch('obs%.([%w_]+)%(') do symbols[name] = true end
for _, name in ipairs({'config_get_bool','config_get_string','config_set_bool','config_set_int','config_set_string'}) do symbols[name] = true end
local tests = 0
local function load_fixture(missing, platform)
    local calls, api = {}, {}
    for name in pairs(symbols) do
        local key = name
        api[key] = function() calls[#calls + 1] = key end
    end
    api.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED = 0
    api.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED = 1
    if missing then api[missing] = nil end
    local env = setmetatable({obslua = api}, {__index = _G})
    if platform then
        env.require = function(name)
            if name == 'ffi' then return {os=platform, arch='x64'} end
            return require(name)
        end
    end
    local chunk = assert(loadstring(automation_source))
    setfenv(chunk, env)()
    return env, calls
end
local normal = load_fixture()
assert(type(normal.script_load) == 'function', 'Current API should load: ' .. normal.script_description())
tests = tests + 1
for name in pairs(symbols) do
    local env, calls = load_fixture(name)
    assert(env.script_load == nil and env.script_update == nil, 'Missing API not guarded: ' .. name)
    assert(env.script_description():find(name, 1, true), 'Missing API diagnostic: ' .. name)
    for _, call in ipairs(calls) do assert(call == 'script_log', 'Guard mutated OBS via ' .. call) end
    tests = tests + 1
end
for _, event in ipairs({'OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED', 'OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED'}) do
    local env = load_fixture(event)
    assert(env.script_load == nil and env.script_description():find(event, 1, true))
    tests = tests + 1
end
local other_platform = load_fixture(nil, 'Linux')
assert(other_platform.script_load == nil, 'Unsupported platform reached Win32 calls')
tests = tests + 1
return tests .. ' Lua compatibility guard checks passed'
