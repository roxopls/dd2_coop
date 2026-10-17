-- DD2 Co-op: os outros jogadores no minimapa com a setinha de pawn.
-- O minimapa (app.ui020301) tem 3 ícones de pawn (PawnIconList) que o jogo distribui entre os
-- pawns do grupo pelo CharacterID; as cópias têm o CharacterID do próprio Arisen e não entram.
-- Depois do updatePawnIcon do jogo, os ícones que ele deixou livres (IsUsed=false; durante a
-- sessão os pawns estão em espera, então os 3) vão para as cópias:
--   posição do painel = getIconPos(cópia) - getIconPos(jogador)   (conferido com um pawn)
--   rotação           = getIconRot(yaw da cópia)
-- Jogador morto: textura de pawn morto (PawnDeadTexPos) na última posição.
local M = { shown = 0, message = "" }
_G.dd2coop_mapicons = M

local used = {}   -- índice do ícone -> true quando está com uma cópia

local function yaw_of(q)
    return math.atan(2 * (q.x * q.z + q.w * q.y), 1 - 2 * (q.x * q.x + q.y * q.y))
end

-- cópias dos outros jogadores: { ch, dead }
local function players()
    local out = {}
    local P = _G.dd2coop_p2
    if P and P.state == "pronto" and P.clone then
        local live = P.drawn == true or P.remote_dead == true
        if live then out[#out + 1] = { ch = P.clone, dead = P.remote_dead == true } end
    end
    local X = _G.dd2coop_extra
    for _, s in ipairs(X and X.slots or {}) do
        if s.state == "pronto" and s.clone and s.active and (s.drawn or s.remote_dead) then
            out[#out + 1] = { ch = s.clone, dead = s.remote_dead == true }
        end
    end
    return out
end

local function update(ui)
    local arr = ui:get_field("PawnIconList")
    if not arr then return end
    local me = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
    if not me then return end
    local base = ui:call("getIconPos", me:call("get_GameObject"):call("get_Transform"):call("get_Position"))
    local list = players()
    local k, shown = 1, 0
    for i = 0, arr:get_size() - 1 do
        local icon = arr:get_element(i)
        if not icon:get_field("IsUsed") then
            local p = list[k]
            if p then
                k = k + 1
                local xf = p.ch:call("get_GameObject"):call("get_Transform")
                local at = ui:call("getIconPos", xf:call("get_Position"))
                local pnl = icon:get_field("Pnl")
                pnl:call("set_Position", Vector3f.new(at.x - base.x, at.y - base.y, 0))
                pnl:call("set_Rotation", ui:call("getIconRot", yaw_of(xf:call("get_Rotation"))))
                icon:call("setMatPos", ui:get_field(p.dead and "PawnDeadTexPos" or "PawnTexPos"))
                icon:call("set_Visible", true)
                used[i] = true
                shown = shown + 1
            elseif used[i] then
                -- ícone que era de uma cópia: some e volta à textura normal para um pawn
                icon:call("setMatPos", ui:get_field("PawnTexPos"))
                icon:call("set_Visible", false)
                used[i] = nil
            end
        end
    end
    M.shown = shown
end

local td = sdk.find_type_definition("app.ui020301")
local m = td and td:get_method("updatePawnIcon")
if m then
    local this
    sdk.hook(m, function(args) this = args[2] end, function(r)
        local ok, err = pcall(function()
            local ui = this and sdk.to_managed_object(this)
            if ui then update(ui) end
        end)
        if not ok then M.message = "erro no minimapa: " .. tostring(err) end
        return r
    end)
    log.info("[dd2coop_mapicons] jogadores no minimapa")
else
    log.info("[dd2coop_mapicons] app.ui020301.updatePawnIcon nao achado")
end
