-- DD2 Co-op: gravador de cutscene (coleta para a sincronização "cutscene toca para todo mundo").
-- Forçar uma cutscene fora do contexto da quest não funciona (loadTimelineEvent carrega, mas
-- checkPlayTimelineEvent fica false), então primeiro registramos o que o jogo faz de verdade:
--   * PauseManager.requestPause com PlayEvent(7), CutScene(8) ou Demo(11);
--   * TimelineEventManager load/play/unload com o ID (app.TimelineEventDefine.ID).
-- Grava reframework\data\dd2coop_cutscene_log.txt (últimas MAX linhas). Só observa, não muda nada.
local M = { lines = {}, count = 0 }
_G.dd2coop_cutscene = M

local MAX = 300
local OUT = "dd2coop_cutscene_log.txt"
local PAUSE_KINDS = { [7] = "PlayEvent", [8] = "CutScene", [11] = "Demo" }
local dirty = false

local function add(text)
    M.count = M.count + 1
    local l = os.date("%H:%M:%S") .. " " .. text
    M.lines[#M.lines + 1] = l
    if #M.lines > MAX then table.remove(M.lines, 1) end
    dirty = true
    log.info("[dd2coop_cutscene] " .. text)
end

local function id_name(id)
    local ok, name = pcall(function()
        local td = sdk.find_type_definition("app.TimelineEventDefine.ID")
        for _, f in ipairs(td:get_fields()) do
            if f:is_static() and f:get_data(nil) == id then return f:get_name() end
        end
    end)
    return ok and name or "?"
end

local function low32(p) return sdk.to_int64(p) & 0xFFFFFFFF end

local pm = sdk.find_type_definition("app.PauseManager")
local rp = pm and pm:get_method("requestPause")
if rp then
    sdk.hook(rp, function(args)
        pcall(function()
            local kind = low32(args[4])
            if PAUSE_KINDS[kind] then
                local on = (sdk.to_int64(args[3]) & 1) == 1
                local who = "?"
                pcall(function() who = sdk.to_managed_object(args[5]):call("ToString") end)
                add(string.format("pausa %s %s por %s", PAUSE_KINDS[kind], on and "liga" or "solta", who))
            end
        end)
    end, function(r) return r end)
end

-- cada método tem overloads (via.Component / System.Object, com e sem callback): engancha todos
local WATCH = { loadTimelineEvent = true, playTimelineEvent = true, unloadTimelineEvent = true,
    stopTimelineEvent = true, skipTimelineEvent = true }
local tm = sdk.find_type_definition("app.TimelineEventManager")
for _, m in ipairs(tm and tm:get_methods() or {}) do
    local name = m:get_name()
    if WATCH[name] then
        sdk.hook(m, function(args)
            pcall(function()
                local id = low32(args[4])
                add(string.format("%s id=%d (%s)", name, id, id_name(id)))
            end)
        end, function(r) return r end)
    end
end

re.on_frame(function()
    if not dirty then return end
    dirty = false
    pcall(fs.write, OUT, table.concat(M.lines, "\n"))
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: gravador de cutscene") then return end
    imgui.text("eventos=" .. M.count .. " (" .. OUT .. ")")
    for i = math.max(1, #M.lines - 5), #M.lines do imgui.text(M.lines[i]) end
    imgui.tree_pop()
end)

log.info("[dd2coop_cutscene] gravador carregado")
