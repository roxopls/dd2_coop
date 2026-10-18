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
-- caído esperando reviver (dd2coop_revive) também usa o ícone de pawn morto
local function is_down(peer)
    local R = _G.dd2coop_revive
    local r = R and peer and R.remote[peer]
    return r ~= nil and r.down == true
end

local function players()
    local out = {}
    local P = _G.dd2coop_p2
    if P and P.state == "pronto" and P.clone then
        local live = P.drawn == true or P.remote_dead == true
        local peer = P.get_peer and P.get_peer()
        local down = is_down(peer) or is_down("0")
        if live then out[#out + 1] = { ch = P.clone, dead = P.remote_dead == true or down } end
    end
    local X = _G.dd2coop_extra
    for _, s in ipairs(X and X.slots or {}) do
        if s.state == "pronto" and s.clone and s.active and (s.drawn or s.remote_dead) then
            out[#out + 1] = { ch = s.clone, dead = s.remote_dead == true or is_down(s.peer) }
        end
    end
    return out
end

-- Som de morte do minimapa: ui020301.callDeadSe toca o som contínuo de "alguém do grupo morreu" (só
-- se [ui+0x320] estiver desligado, e liga), e o jogo chama stopDeadSe a cada atualização em que não
-- acha pawn morto (300 vezes em 3 s, medido em 2026-10-18). Com algum jogador morto, o som é
-- disparado uma vez e o stopDeadSe do jogo é pulado; quando ninguém mais está morto, ele volta a
-- valer e o som para.
M.any_dead = false
local function dead_sound(ui, any)
    if any and not M.any_dead then pcall(function() ui:call("callDeadSe") end) end
    M.any_dead = any
end
do
    local td = sdk.find_type_definition("app.ui020301")
    local m = td and td:get_method("stopDeadSe")
    if m then
        sdk.hook(m, function(args)
            if M.any_dead then return sdk.PreHookResult.SKIP_ORIGINAL end
        end, function(r) return r end)
    end
end

local function update(ui)
    local arr = ui:get_field("PawnIconList")
    if not arr then return end
    local me = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
    if not me then return end
    local base = ui:call("getIconPos", me:call("get_GameObject"):call("get_Transform"):call("get_Position"))
    local list = players()
    local any = false
    for _, p in ipairs(list) do any = any or p.dead end
    dead_sound(ui, any)
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
                -- morte como a de um pawn: o update do ícone troca o estado do painel (DEFAULT ->
                -- death_wait, com caveira e onda) quando IsDead muda
                icon:set_field("IsDead", p.dead == true)
                pcall(function() icon:call("update(System.String, System.Single, System.Single)", "DEFAULT", 1.0, 1.0) end)
                icon:call("set_Visible", true)
                used[i] = true
                shown = shown + 1
            elseif used[i] then
                -- ícone que era de uma cópia: some e volta à textura normal para um pawn
                icon:call("setMatPos", ui:get_field("PawnTexPos"))
                icon:set_field("IsDead", false)
                pcall(function() icon:call("update(System.String, System.Single, System.Single)", "DEFAULT", 1.0, 1.0) end)
                icon:call("set_Visible", false)
                used[i] = nil
            end
        end
    end
    M.shown = shown
end

-- Mapa grande (app.ui040205): só desenha o Arisen (PnlArisen). Os últimos ícones de uso geral
-- (MapIcon[31], [30], [29]; o jogo usa o pool a partir do início) viram o ícone de Arisen
-- (MapIconRef.setupPlIcon, o mesmo do jogador) na posição getIconPos(posição universal) de cada jogador.
local big_used = {}
local function update_big(ui)
    local arr = ui:get_field("MapIcon")
    if not arr then return end
    local list = players()
    local last = arr:get_size() - 1
    for k = 1, 3 do
        local i = last - (k - 1)
        local r = arr:get_element(i)
        local p = list[k]
        if r and p then
            -- o jogo reconfigura a aparência do pool ao abrir o mapa: reaplica sempre
            r:call("setupPlIcon")
            big_used[i] = true
            local xf = p.ch:call("get_GameObject"):call("get_Transform")
            r:call("set_Position", ui:call("getIconPos(via.Position)", xf:call("get_UniversalPosition")))
            r:call("set_Rotation", ui:call("getIconRot", yaw_of(xf:call("get_Rotation"))))
            r:call("setAlpha", p.dead and 0.4 or 1.0)
            r:call("set_Visible", true)
        elseif r and big_used[i] then
            r:call("set_Visible", false)
            big_used[i] = nil
        end
    end
end

do
    local bt = sdk.find_type_definition("app.ui040205")
    local bm = bt and bt:get_method("update")
    if bm then
        local this
        sdk.hook(bm, function(args) this = args[2] end, function(r)
            local ok, err = pcall(function()
                local ui = this and sdk.to_managed_object(this)
                if ui then update_big(ui) end
            end)
            if not ok then M.message = "erro no mapa grande: " .. tostring(err) end
            return r
        end)
    end
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
