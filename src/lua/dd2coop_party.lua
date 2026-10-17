-- DD2 Co-op: sem pawns enquanto há outro jogador na sessão.
-- Com par na sessão: PawnManager.standbyPartyPawn(true, ...) descarrega os pawns do grupo (o
-- mesmo "esperar" que o jogo usa em quests). Sem par: comebackPartyPawn(posição, rotação) os
-- traz ao lado do jogador. (comebackPartyPawn(false) com os pawns descarregados crashou em
-- InstanceInfoController.autoDestroyCharaInstance; a versão com posição funcionou, 2026-10-17.)
-- A marca dd2coop_party.json {"standby":true} sobrevive a fechar/crashar: na próxima carga
-- sem sessão os pawns voltam.
local M = { frame = 0, standby = false, message = "" }
_G.dd2coop_party = M

local MARK = "dd2coop_party.json"
local STANDBY = "standbyPartyPawn(System.Boolean, System.Boolean, System.Boolean, app.TalkDefine.PawnStandbyAreaType)"
local COMEBACK = "comebackPartyPawn(via.vec3, via.Quaternion)"

do
    local ok, mark = pcall(json.load_file, MARK)
    M.standby = ok and type(mark) == "table" and mark.standby == true
end

local function mark(v)
    M.standby = v
    pcall(json.dump_file, MARK, { standby = v })
end

local function in_game()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    return cm and cm:call("get_ManualPlayer")
end

local function send_away()
    local pm = sdk.get_managed_singleton("app.PawnManager")
    if not pm or pm:call("get_IsStandby") then return end
    if pm:call("get_PartyPawnList"):call("get_Count") == 0 then return end
    pm:call(STANDBY, true, false, false, 0)
    mark(true)
    log.info("[dd2coop_party] pawns descarregados (jogador na sessao)")
end

local function bring_back(me)
    local pm = sdk.get_managed_singleton("app.PawnManager")
    if not pm then return end
    if pm:call("get_IsStandbyUnload") then
        local xf = me:call("get_GameObject"):call("get_Transform")
        pm:call(COMEBACK, xf:call("get_Position"), xf:call("get_Rotation"))
        log.info("[dd2coop_party] pawns de volta")
    end
    mark(false)
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    M.frame = M.frame + 1
    if M.frame % 60 ~= 0 then return end
    local me = in_game()
    if not me then return end
    local S = _G.dd2coop_session
    local ls = S and S.status
    local with_player = ls and (ls.role == "host" or ls.role == "cliente") and S.peer ~= nil
    local ok, err
    if with_player then
        ok, err = pcall(send_away)
    elseif M.standby then
        ok, err = pcall(bring_back, me)
    else
        ok = true
    end
    if not ok then M.message = "erro nos pawns: " .. tostring(err) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: pawns") then return end
    imgui.text(M.standby and "pawns descarregados (voltam quando a sessao acabar)" or "pawns no grupo")
    if M.message ~= "" then imgui.text(M.message) end
    imgui.tree_pop()
end)

log.info("[dd2coop_party] pawns carregado")
