-- DD2 Co-op: rastreador da cópia (ferramenta de desenvolvimento; NÃO vai no pacote).
-- Instalar à mão em reframework\autorun (prefixo dd2dev_ para o launcher não apagar).
-- * A cada ~2 s, com cópia (dd2coop_p2 ou dd2coop_extra): posição, velocidade vertical,
--   distância do jogador, DrawSelf/UpdateSelf, morto, ação atual.
-- (Hooks em métodos "destroy" de via.GameObject/GenerateManager foram tirados: com eles a criação
-- da cópia crashou 2 vezes seguidas em DD2.exe+0x524feb4, 2026-10-17.)
-- Grava reframework\data\dd2dev_trace.txt (últimas MAX linhas) e o log do REFramework.
local T = { lines = {}, calls = {} }
_G.dd2dev_trace = T

local MAX = 400
local OUT = "dd2dev_trace.txt"
local dirty = false

local function add(s)
    local l = string.format("%s f=%d %s", os.date("%H:%M:%S"), T.frame or 0, s)
    T.lines[#T.lines + 1] = l
    if #T.lines > MAX then table.remove(T.lines, 1) end
    dirty = true
    log.info("[dd2dev_trace] " .. s)
end

-- endereços da cópia: Character, Human e GameObject de cada uma
local function copies()
    local set, list = {}, {}
    local function put(ch, label)
        if not ch then return end
        pcall(function()
            set[ch:get_address()] = label .. ".Character"
            set[ch:call("get_Human"):get_address()] = label .. ".Human"
            set[ch:call("get_GameObject"):get_address()] = label .. ".GameObject"
            list[#list + 1] = { ch = ch, label = label }
        end)
    end
    local P = _G.dd2coop_p2
    put(P and P.clone, "p2")
    local X = _G.dd2coop_extra
    for i, s in ipairs(X and X.slots or {}) do put(s.clone, "x" .. i) end
    return set, list
end

-- estado da cópia a cada ~2 s
local last = {}
re.on_pre_application_entry("LateUpdateBehavior", function()
    T.frame = (T.frame or 0) + 1
    if T.frame % 120 ~= 0 then return end
    pcall(function()
        local _, list = copies()
        if #list == 0 then return end
        local me = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
        local mp = me and me:call("get_GameObject"):call("get_Transform"):call("get_Position")
        for _, c in ipairs(list) do
            local go = c.ch:call("get_GameObject")
            local p = go:call("get_Transform"):call("get_Position")
            local prev = last[c.label]
            local vy = prev and (p.y - prev.y) / 2 or 0
            last[c.label] = { y = p.y }
            local d = mp and math.sqrt((p.x - mp.x) ^ 2 + (p.y - mp.y) ^ 2 + (p.z - mp.z) ^ 2) or -1
            local act = "?"
            pcall(function() act = tostring(c.ch:call("get_ActionManager"):get_field("CurrentActionHash")) end)
            add(string.format("%s pos=%.1f,%.1f,%.1f vy=%.2f dist=%.1f draw=%s upd=%s morto=%s acao=%s", c.label,
                p.x, p.y, p.z, vy, d, tostring(go:call("get_DrawSelf")), tostring(go:call("get_UpdateSelf")),
                tostring(c.ch:call("get_IsDead")), act))
        end
        local parts = {}
        for k, v in pairs(T.calls) do parts[#parts + 1] = k .. "=" .. v end
        if #parts > 0 then add("chamadas sem alvo: " .. table.concat(parts, " ")) end
    end)
end)

re.on_frame(function()
    if not dirty then return end
    dirty = false
    pcall(fs.write, OUT, table.concat(T.lines, "\n"))
end)

log.info("[dd2dev_trace] rastreador carregado")
