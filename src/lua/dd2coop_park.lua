-- DD2 Co-op: cópia estacionada quando o jogador dela está longe.
-- A ~200 m do jogador local o chão e a colisão sob a cópia descarregam: ela cai sem parar
-- (y -6400 m em 1 min, rastreado em 2026-10-17) e a física quebra pouco depois (crash nativo
-- "uns 90 s depois de se afastar"). Com o jogador da cópia a mais de PARK m do jogador local, a
-- cópia é congelada (GameObject.UpdateSelf=false: sem física, não cai) e escondida; abaixo de
-- UNPARK m (área já carregada) volta a atualizar e a aparecer, e a correção de posição do plugin
-- a leva à pose real.
-- Posição do jogador da cópia: pose da rede (dd2coop_net_status, por slot) quando há rede; senão
-- a da própria cópia (teste sem rede).
local M = { parked = {}, message = "" }
_G.dd2coop_park = M

local PARK, UNPARK = 120, 100

local function upos(ch)
    local p = ch:call("get_GameObject"):call("get_Transform"):call("get_UniversalPosition")
    return p.x, p.y, p.z
end

-- { ch, key, drawn = visibilidade que o dono da cópia quer, remote = {x,y,z} ou nil }
local function copies()
    local out = {}
    local P = _G.dd2coop_p2
    if P and P.state == "pronto" and P.clone then
        local s = P.net_status
        local rp = nil
        if s and s.remote_valid and (s.input_state == "active" or s.input_state == "buffering") then
            rp = { s.rx, s.ry, s.rz }
        end
        out[#out + 1] = { ch = P.clone, key = "p2", drawn = P.drawn, remote = rp }
    end
    local X = _G.dd2coop_extra
    for _, s in ipairs(X and X.slots or {}) do
        if s.state == "pronto" and s.clone then
            out[#out + 1] = { ch = s.clone, key = "x:" .. tostring(s.peer), drawn = s.drawn, remote = s.remote_pose }
        end
    end
    return out
end

local function set_parked(c, on)
    local go = c.ch:call("get_GameObject")
    go:call("set_UpdateSelf", not on)
    go:call("set_DrawSelf", (not on) and c.drawn == true)
    M.parked[c.key] = on or nil
    log.info("[dd2coop_park] " .. c.key .. (on and " estacionada (longe)" or " de volta (perto)"))
end

-- estacionada? (dd2coop_puppet/extra consultam para não mostrar a cópia)
function M.is_parked(key) return M.parked[key] == true end

local frame = 0
re.on_pre_application_entry("LateUpdateBehavior", function()
    frame = frame + 1
    if frame % 15 ~= 0 then return end
    local ok, err = pcall(function()
        local me = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
        if not me then return end
        local mx, my, mz = upos(me)
        for _, c in ipairs(copies()) do
            if me:get_address() ~= c.ch:get_address() then
                local x, y, z
                if c.remote then x, y, z = c.remote[1], c.remote[2], c.remote[3] else x, y, z = upos(c.ch) end
                local d = math.sqrt((x - mx) ^ 2 + (y - my) ^ 2 + (z - mz) ^ 2)
                if not M.parked[c.key] and d > PARK then set_parked(c, true)
                elseif M.parked[c.key] and d < UNPARK then set_parked(c, false) end
            end
        end
    end)
    if not ok then M.message = "erro: " .. tostring(err) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: copias estacionadas") then return end
    local n = 0
    for k in pairs(M.parked) do imgui.text(k .. " estacionada"); n = n + 1 end
    if n == 0 then imgui.text("nenhuma (estaciona acima de " .. PARK .. " m)") end
    if M.message ~= "" then imgui.text(M.message) end
    imgui.tree_pop()
end)

log.info("[dd2coop_park] copias longe estacionadas")
