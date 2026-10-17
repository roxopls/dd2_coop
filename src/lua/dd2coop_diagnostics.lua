-- DD2 Co-op: read-only diagnostics for the original and remote Arisen.
-- No spawning, recovery requests, status writes, or save hooks here.
-- Load alongside dd2coop_puppet.lua; ordering of autorun files is irrelevant.
local VERSION = 1
local SAMPLE_FRAMES, FLUSH_FRAMES, MAX_EVENTS = 6, 120, 2000
local REQUEST = "dd2coop_diag_request.json"
local STATUS = "dd2coop_diag_status.json"
local session = os.date("%Y%m%d_%H%M%S")
local history = "dd2coop_diag_" .. session .. ".txt"
local d = { frame = 0, enabled = true, events = {}, total = 0, dirty = false,
    last = {}, requests = {}, owners = {}, latest = {}, errors = {}, cache = {},
    last_request_id = nil, request_initialized = false, lifecycle = nil }
_G.dd2coop_diagnostics = d

local function address(obj)
    if obj == nil then return nil end
    local ok, value = pcall(function() return obj:get_address() end)
    return ok and value or nil
end

local function clean(value)
    return tostring(value):gsub("[\r\n\t]", " ")
end

local function flatten(value, prefix, out)
    out = out or {}
    if type(value) == "table" then
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            flatten(value[k], prefix and (prefix .. "." .. k) or tostring(k), out)
        end
    else
        out[#out + 1] = prefix .. "=" .. clean(value)
    end
    return out
end

local function event(kind, data)
    d.total = d.total + 1
    local line = string.format("%s frame=%d event=%s %s", os.date("%Y-%m-%dT%H:%M:%S"),
        d.frame, kind, table.concat(flatten(data or {}), " "))
    d.events[#d.events + 1] = line
    if #d.events > MAX_EVENTS then table.remove(d.events, 1) end
    d.dirty = true
end

-- Resolve inherited methods too. Only explicitly listed getters are invoked;
-- signatures must match, and unsupported members stay unknown in the output.
local function read(obj, name, ...)
    if obj == nil then return nil end
    local count = select("#", ...)
    local td = obj:get_type_definition()
    local key = td:get_full_name() .. ":" .. name .. ":" .. count
    local method = d.cache[key]
    if method == nil then
        local t = td
        while t do
            local candidate = t:get_method(name)
            if candidate and candidate:get_num_params() == count and not candidate:is_static() then
                method = candidate
                break
            end
            t = t:get_parent_type()
        end
        d.cache[key] = method or false
        if not method then d.errors[key] = "unsupported" end
    end
    if not method then return nil end
    local ok, value = pcall(function(...) return method:call(obj, ...) end, ...)
    if not ok then
        d.errors[key] = clean(value)
        return nil
    end
    return value
end

local function scalar(obj, method)
    local value = read(obj, method)
    if type(value) == "boolean" or type(value) == "string" then return value end
    if type(value) == "number" and value == value and math.abs(value) < math.huge then return value end
    return nil
end

local CHAR = { hp = "get_Hp", max_hp = "get_OriginalMaxHp", dead = "get_IsDead",
    down = "get_IsDown", knee_down = "get_IsKneeDown", damaged = "get_IsDamage",
    fall_dead = "get_IsFallDead", unbalanced = "get_IsUnbalance", cause_of_death = "get_CauseOfDeath" }
local HUMAN = { action_type = "get_ActionType", move_state = "get_MoveState",
    unbalance_type = "get_UnbalanceType", down_seconds = "get_TimerSecDown",
    exhausted = "get_IsRunningOutOfStamina" }

local function capture(ch, label)
    local addr = address(ch)
    if not addr then return { available = false } end
    local result = { available = true, address = string.format("0x%X", addr),
        character_id = scalar(ch, "get_CharaID"), flags = {}, human = {}, actions = {} }
    for key, method in pairs(CHAR) do result.flags[key] = scalar(ch, method) end
    local human = read(ch, "get_Human")
    for key, method in pairs(HUMAN) do result.human[key] = scalar(human, method) end
    local stamina = read(human, "get_StaminaContext")
    result.stamina = scalar(stamina, "get_RemainingAmountProp")
    local status = read(human, "get_StatusContext")
    local status_addr = address(status)
    if status_addr then result.status_address = string.format("0x%X", status_addr) end
    local am = read(ch, "get_ActionManager")
    local am_addr = address(am)
    if am_addr then d.owners[am_addr] = label end
    for layer = 0, 1 do
        local value = read(am, "getCurrentActionHash", layer)
        if type(value) == "number" then result.actions["layer" .. layer] = value end
    end
    result.last_requests = d.requests[label]
    local xf = read(read(ch, "get_GameObject"), "get_Transform")
    local pos = read(xf, "get_UniversalPosition")
    if pos then
        local ok, xyz = pcall(function() return { x = pos.x, y = pos.y, z = pos.z } end)
        if ok then result.position = xyz end
    end
    return result
end

local function net_copy(source)
    local result = {}
    for _, k in ipairs({ "mode", "sent", "received", "applied", "held", "bad", "buffered",
        "drift", "snaps", "remote_valid", "error", "input_state", "rx_age_ms", "timeouts", "neutralized",
        "instance", "lua_epoch", "save_locked", "native_saves_blocked", "save_hooks" }) do
        local value = source and source[k]
        if value ~= nil then result[k] = value end
    end
    return result
end

local function sample(force)
    local p = _G.dd2coop_p2
    local lifecycle = p and p.state or "script_missing"
    if lifecycle ~= d.lifecycle then
        event("lifecycle", { state = lifecycle })
        d.lifecycle = lifecycle
        d.last, d.requests = {}, {}
    end
    d.owners = {}
    local pair = { version = VERSION, session = session, frame = d.frame,
        game_frame = p and p.frame, state = lifecycle, source = p and p.source_idx,
        hidden = p and p.hidden or false, network = net_copy(p and p.net_status) }
    if p and p.state == "pronto" then
        pair.original = capture(p.orig, "original")
        pair.clone = capture(p.clone, "clone")
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local manual = address(read(cm, "get_ManualPlayer"))
        if manual then pair.manual_player_address = string.format("0x%X", manual) end
        if manual and address(p.orig) then pair.manual_is_original = manual == address(p.orig) end
        for _, label in ipairs({ "original", "clone" }) do
            local s = pair[label]
            -- Timers, positions and stamina change continuously: include them in
            -- snapshots, but log transitions based on action/flags and HP instead.
            local signature = table.concat(flatten({ address = s.address, flags = s.flags,
                actions = s.actions, action_type = s.human and s.human.action_type,
                move_state = s.human and s.human.move_state,
                exhausted = s.human and s.human.exhausted }), " ")
            if force or signature ~= d.last[label] then
                event("character", { owner = label, state = s })
                d.last[label] = signature
            end
        end
    end
    pair.sampled_at = os.date("%Y-%m-%dT%H:%M:%S")
    d.latest = pair
end

local function flush()
    local ok, err = pcall(json.dump_file, STATUS, { latest = d.latest, enabled = d.enabled,
        history = history, total_events = d.total, retained_events = #d.events, read_errors = d.errors })
    if not ok or err == false then d.io_error = "status write failed"; return end
    if d.dirty then
        local header = "DD2 Co-op diagnostics v" .. VERSION .. " session=" .. session
            .. " total_events=" .. d.total .. " retained=" .. #d.events .. "\n"
        local wrote, result = pcall(fs.write, history, header .. table.concat(d.events, "\n") .. "\n")
        if not wrote or result == false then d.io_error = "history write failed"; return end
        d.dirty = false
    end
    d.io_error = nil
end

local function mark(note)
    local ok, err = pcall(sample, true)
    if not ok then event("read_error", { message = clean(err) }) end
    event("marker", { note = note or "problema observado", snapshot = d.latest })
    log.info("[dd2coop_diag] problema marcado: " .. history)
    flush()
end
d.mark = mark

-- Observe action requests without changing arguments, results, or execution.
local td = sdk.find_type_definition("app.ActionManager")
local core = td and td:get_method("requestActionCore")
if core and core:get_num_params() == 3 then
    sdk.hook(core, function(args)
        if not d.enabled then return end
        local owner = d.owners[sdk.to_int64(args[2])]
        if not owner then return end
        local ok, name = pcall(function()
            local text = sdk.to_managed_object(args[4])
            return text and text:call("ToString()")
        end)
        if not ok or type(name) ~= "string" then return end
        local layer = sdk.to_int64(args[5]) & 0xFFFFFFFF
        local request = { name = name, layer = layer, frame = d.frame }
        d.requests[owner] = d.requests[owner] or {}
        d.requests[owner]["layer" .. layer] = request
        event("action_request", { owner = owner, request = request })
    end, function(retval) return retval end)
else
    d.errors.action_request_hook = "unsupported signature"
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    d.frame = d.frame + 1
    if not d.enabled then return end
    if d.frame % SAMPLE_FRAMES == 0 then
        local ok, err = pcall(sample, false)
        if not ok then
            local message = clean(err)
            if message ~= d.last_error then event("read_error", { message = message }) end
            d.last_error = message
        else d.last_error = nil end
    end
    if d.frame % 60 == 0 then
        local ok, req = pcall(json.load_file, REQUEST)
        -- REFramework logs missing/empty JSON files even inside pcall. Repair the
        -- optional command file once so it cannot flood the main log every second.
        if not ok or type(req) ~= "table" then
            pcall(json.dump_file, REQUEST, { id = 0, command = "idle" })
        end
        if not d.request_initialized then
            d.last_request_id = ok and type(req) == "table" and req.id or nil
            d.request_initialized = true
        elseif ok and type(req) == "table" and req.id ~= nil and req.id ~= d.last_request_id then
            d.last_request_id = req.id
            if req.command == "mark" then mark(type(req.note) == "string" and req.note:sub(1, 200) or nil) end
        end
    end
    if d.frame % FLUSH_FRAMES == 0 then
        event("heartbeat", d.latest)
        flush()
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: diagnostico") then return end
    local changed, enabled = imgui.checkbox("Registrar diagnostico", d.enabled)
    if changed then
        d.enabled = enabled
        d.owners = {}
        event("enabled", { value = enabled })
        flush()
    end
    imgui.text("Log: reframework/data/" .. history)
    local net = d.latest.network
    if net and net.input_state then
        imgui.text(string.format("Input remoto: %s | ultimo pacote: %s ms | interrupcoes: %s",
            net.input_state, tostring(net.rx_age_ms), tostring(net.timeouts)))
    end
    for _, label in ipairs({ "original", "clone" }) do
        local s = d.latest[label]
        if s and s.available then
            local f = s.flags or {}
            imgui.text(string.format("%s: HP=%s morto=%s caido=%s acao0=%s", label,
                tostring(f.hp), tostring(f.dead), tostring(f.down), tostring(s.actions.layer0)))
            local req = s.last_requests and s.last_requests.layer0
            if req then imgui.text("  ultimo pedido (nao estado confirmado): " .. req.name) end
        end
    end
    if imgui.button("Marcar problema / gravar estados agora") then mark() end
    imgui.text("Eventos: " .. d.total .. " (ultimos " .. MAX_EVENTS .. " mantidos)")
    if d.io_error then imgui.text("Erro: " .. d.io_error) end
    imgui.tree_pop()
end)

re.on_script_reset(function() event("script_reset", d.latest); flush() end)
event("start", { version = VERSION, history = history })
log.info("[dd2coop_diag] diagnostico carregado v" .. VERSION)
