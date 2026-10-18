-- DD2 Co-op: em sessão, nenhuma morte chega à tela de morte do jogo.
-- A tela de morte ("continuar": carregar save, estalagem...) levaria a um carregamento que
-- desconectaria todos. Ao morrer, o jogo chama MainFlowManager.changeFlowPhase(ConfirmContinue=40)
-- com CharacterManager.IsManualPlayerDead=true (medido em 2026-10-18). Com sessão ativa, essa troca
-- de fase é pulada: o jogador fica morto no lugar, sem tela de morte, até ser revivido.
-- Reviver: CharacterManager.WakestoneUser:useWakestoneToRevivePlayer(jogador), o mesmo caminho do
-- jogo para a Vitalita (Wakestone). Ele confere IsDead, espera não haver fade e pede a ação de
-- levantar; não gasta item (não chama deleteItem/useItem).
-- Espectador: enquanto morto, a câmera segue a cópia de um jogador vivo (registerTargetObject) e o
-- controle do próprio personagem fica desligado; ao reviver, câmera e controle voltam.
-- Próximos passos (ainda não aqui): reviver quando um vivo tocar uma Pedra de Fenda, derrota do
-- grupo levando todos ao último ponto seguro.
local M = { blocked = 0, revived = 0, dead = false, test = false, message = "" }
_G.dd2coop_death = M

local CONFIRM_CONTINUE = 40 -- app.MainFlowManager.Phase.ConfirmContinue

local function in_session()
    if M.test then return true end
    local S = _G.dd2coop_session
    local ls = S and S.status
    return ls and (ls.role == "host" or ls.role == "cliente") and S.peers and #S.peers > 0 or false
end

local function player() return sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer") end

do
    local td = sdk.find_type_definition("app.MainFlowManager")
    local m = td and td:get_method("changeFlowPhase")
    if m then
        sdk.hook(m, function(args)
            if (sdk.to_int64(args[3]) & 0xffffffff) ~= CONFIRM_CONTINUE or not in_session() then return end
            M.blocked = M.blocked + 1
            if not M.dead then
                M.dead, M.dead_at = true, os.clock()
                log.info("[dd2coop_death] morte em sessao: tela de morte bloqueada")
            end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, function(ret) return ret end)
    else
        M.message = "MainFlowManager.changeFlowPhase nao encontrado; tela de morte nao bloqueada"
    end
end

-- espectador: morto em sessão, a câmera segue a cópia de um jogador vivo e o controle do próprio
-- personagem fica desligado; ao reviver, câmera e controle voltam
local function main_camera_controller()
    local sm = sdk.get_native_singleton("via.SceneManager")
    local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
    local list = scene and scene:call("findComponents(System.Type)", sdk.typeof("app.MainCameraController"))
    return list and list:get_size() > 0 and list:get_element(0) or nil
end

local function alive(ch)
    local ok, dead = pcall(function() return ch:call("get_IsDead") end)
    return ok and not dead
end

-- cópia de um jogador vivo: jogador 2, depois 3 e 4
local function pick_target()
    local P = _G.dd2coop_p2
    if P and P.state == "pronto" and P.clone and not P.remote_dead and (P.drawn or M.test) and alive(P.clone) then
        return P.clone
    end
    local X = _G.dd2coop_extra
    for _, s in ipairs(X and X.slots or {}) do
        if s.state == "pronto" and s.clone and s.drawn and alive(s.clone) then return s.clone end
    end
end

local function set_input(p, on)
    pcall(function() p:call("get_InputProcessor"):call("set_IsEnable", on) end)
end

local function spectate(target)
    local mcc = main_camera_controller()
    if not mcc then return false end
    mcc:call("registerTargetObject", target:call("get_GameObject"))
    M.target = target
    return true
end

local function stop_spectating()
    local p = player()
    if M.target and p then
        local mcc = main_camera_controller()
        if mcc then mcc:call("registerTargetObject", p:call("get_GameObject")) end
        set_input(p, true)
        log.info("[dd2coop_death] espectador encerrado: camera de volta ao jogador")
    end
    M.target = nil
end

-- Lugar seguro: reviver no lugar da morte não serve (levantou no fundo do lago e no pé do
-- penhasco depois de uma queda, 2026-10-18). Vivo, em chão firme e fora de água funda, a posição é
-- guardada a cada ~1 s, e o reviver sempre leva o jogador para a última: morto por inimigo, é
-- praticamente onde caiu; numa queda, é a beira de onde caiu; na água, o último ponto seco.
local DEEP_WATER = 0.8 -- m de profundidade a partir da qual a posição não é guardada
local CALM_RADIUS = 40  -- m sem inimigo vivo: a posição também vale como "lugar calmo" (derrota do grupo)

-- inimigos vivos (mesma regra do dd2coop_enemies: tudo que não é Arisen, humano, pawn ou 32)
local SKIP_KIND = { [0] = true, [1] = true, [2] = true, [32] = true }
local function enemies_near(pos, radius)
    local out = {}
    local list = sdk.get_managed_singleton("app.CharacterListHolder"):call("getAllCharacters")
    for i = 0, (list and list:call("get_Count") or 0) - 1 do
        local ch = list:call("get_Item", i)
        local ok, near = pcall(function()
            if SKIP_KIND[ch:call("get_Context"):call("get_CharaKind")] or ch:call("get_IsDead") then return false end
            local q = ch:call("get_GameObject"):call("get_Transform"):call("get_UniversalPosition")
            return (q.x - pos.x) ^ 2 + (q.y - pos.y) ^ 2 + (q.z - pos.z) ^ 2 <= radius * radius
        end)
        if ok and near then out[#out + 1] = ch end
    end
    return out
end

local function track_safe(p)
    if p:call("get_IsDead") or not p:call("get_IsGround") then return end
    local water = p:call("get_WaterSurfaceDetector")
    if water and water:call("get_IsDetected") and (water:call("get_WaterDepth") or 0) > DEEP_WATER then return end
    local xf = p:call("get_GameObject"):call("get_Transform")
    M.safe_pos, M.safe_rot = xf:call("get_UniversalPosition"), xf:call("get_Rotation")
    if #enemies_near(M.safe_pos, CALM_RADIUS) == 0 then
        M.calm_pos = { M.safe_pos.x, M.safe_pos.y, M.safe_pos.z }
    end
end

local function warp_to_safe(p)
    local opt = ValueType.new(sdk.find_type_definition("app.CharacterWarpOption"))
    if M.revive_at then
        -- ao lado da Pedra de Fenda que um aliado tocou
        local xf = p:call("get_GameObject"):call("get_Transform")
        local pos = xf:call("get_UniversalPosition")
        pos.x, pos.y, pos.z = M.revive_at[1] + 1.5, M.revive_at[2], M.revive_at[3] + 1.5
        M.revive_at = nil
        p:call("warp(via.Position, via.Quaternion, app.CharacterWarpOption)", pos, xf:call("get_Rotation"), opt)
        log.info("[dd2coop_death] revivido " .. (M.revive_label or "ao lado da Pedra de Fenda"))
        M.revive_label = nil
        return true
    end
    if not M.safe_pos then return false end
    p:call("warp(via.Position, via.Quaternion, app.CharacterWarpOption)", M.safe_pos, M.safe_rot, opt)
    log.info("[dd2coop_death] revivido no ultimo lugar seguro")
    return true
end

-- Pedra de Fenda em sessão: o menu dela traria os pawns de volta com as cópias no mundo (pawns +
-- cópias passam do limite do grupo e o jogo crasha). RimStoneManager.RequestOpenRimStone(gimmick) é
-- pulado (devolve false: a pedra não abre, nada é travado e o jogador fica livre, testado em
-- 2026-10-18) e, no lugar, os outros jogadores recebem {t="rift"} com a posição da pedra.
local LAST_RIFT = "dd2coop_last_rift.json"
do
    local ok, r = pcall(json.load_file, LAST_RIFT)
    if ok and type(r) == "table" and type(r.x) == "number" and type(r.y) == "number" and type(r.z) == "number" then
        M.last_rift = { r.x, r.y, r.z }
    end
end
M.out = {}
function M.outgoing()
    local o = M.out
    M.out = {}
    return o
end

do
    local td = sdk.find_type_definition("app.RimStoneManager")
    local m = td and td:get_method("RequestOpenRimStone(app.GimmickBase)")
    if m then
        sdk.hook(m, function(args)
            local s = thread.get_hook_storage()
            s.dd2coop_rift = nil
            -- a última pedra tocada vale sempre (com ou sem sessão) e sobrevive a fechar o jogo:
            -- é o ponto da derrota do grupo
            local pos
            pcall(function()
                local gm = sdk.to_managed_object(args[3])
                pos = gm:call("get_GameObject"):call("get_Transform"):call("get_UniversalPosition")
                M.last_rift = { pos.x, pos.y, pos.z }
                pcall(json.dump_file, LAST_RIFT, { x = pos.x, y = pos.y, z = pos.z })
            end)
            if not in_session() then return end
            s.dd2coop_rift = true
            if pos then
                M.out[#M.out + 1] = { t = "rift", x = pos.x, y = pos.y, z = pos.z, id = os.time() }
                if _G.dd2coop_world then _G.dd2coop_world.urgent = true end
                log.info("[dd2coop_death] Pedra de Fenda tocada: aliados mortos revivem aqui")
            end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, function(ret)
            local s = thread.get_hook_storage()
            if s.dd2coop_rift then s.dd2coop_rift = nil; return sdk.to_ptr(0) end
            return ret
        end)
    else
        M.message = "RimStoneManager.RequestOpenRimStone nao encontrado"
    end
end

-- Derrota do grupo: com todos mortos ninguém toca uma Pedra de Fenda. O host, morto e vendo todos os
-- outros mortos (remote_dead, da mensagem de vida) por WIPE_DELAY s, manda {t="wipe"} com um ponto:
-- a última Pedra de Fenda tocada, ou o último lugar seguro do host. Cada jogador vê a tela "O grupo
-- caiu", revive pela Vitalita e vai para lá; a sessão continua conectada.
local WIPE_DELAY, WIPE_SCREEN = 3, 4
local WIPE_HEAL_RADIUS = 80 -- m em volta de onde o grupo caiu: inimigos voltam com a vida cheia
M.test_wipe = false -- teste sozinho: age como host de uma sessão em que todos estão mortos

local function peer_dead(sid)
    local P = _G.dd2coop_p2
    if P and P.get_peer and P.get_peer() == sid then return P.remote_dead == true end
    for _, s in ipairs((_G.dd2coop_extra or {}).slots or {}) do
        if s.peer == sid then return s.remote_dead == true end
    end
    return false
end

local function is_host()
    if M.test_wipe then return true end
    local S = _G.dd2coop_session
    return S and S.status and S.status.role == "host" or false
end

local function everyone_dead()
    if not M.dead then return false end
    if M.test_wipe then return true end
    local S = _G.dd2coop_session
    local peers = S and S.peers or {}
    if #peers == 0 then return false end
    for _, sid in ipairs(peers) do
        if not peer_dead(sid) then return false end
    end
    return true
end

-- todos os jogadores (host incluído) recebem: tela, reviver e ponto de volta
function M.on_wipe(sender, msg)
    if type(msg.x) ~= "number" or type(msg.y) ~= "number" or type(msg.z) ~= "number" then return end
    M.wipe_screen_until = os.clock() + WIPE_SCREEN
    M.wipe_text = msg.rift == true and "Voltando para a ultima Pedra de Fenda..." or "Voltando para o ultimo lugar seguro..."
    log.info("[dd2coop_death] derrota do grupo: todos voltam ao ponto")
    if not M.dead then return end
    M.revive_at = { msg.x, msg.y, msg.z }
    M.revive_label = msg.rift == true and "ao lado da Pedra de Fenda" or "no ponto da derrota do grupo"
    local ok, why = M.revive()
    if not ok then M.revive_at = nil; M.message = "reviver na derrota: " .. tostring(why) end
end

local function check_wipe()
    if not is_host() or not everyone_dead() then M.all_dead_since = nil; return end
    M.all_dead_since = M.all_dead_since or os.clock()
    if os.clock() - M.all_dead_since < WIPE_DELAY or M.wipe_pending then return end
    -- ponto: última Pedra de Fenda; senão o último lugar calmo (sem inimigo a CALM_RADIUS m); só
    -- em último caso o último lugar seguro (ficava no meio da luta, 2026-10-18)
    local point, rift = M.last_rift, M.last_rift ~= nil
    if not point then point = M.calm_pos end
    if not point and M.safe_pos then point = { M.safe_pos.x, M.safe_pos.y, M.safe_pos.z } end
    if not point then return end
    M.wipe_pending = true
    -- os inimigos da luta em que o grupo caiu voltam com a vida cheia (o host é o dono do mundo;
    -- dd2coop_enemies leva a vida para os clientes)
    pcall(function()
        local p = player()
        local here = p:call("get_GameObject"):call("get_Transform"):call("get_UniversalPosition")
        local n = 0
        for _, e in ipairs(enemies_near(here, WIPE_HEAL_RADIUS)) do
            if pcall(function() e:call("get_Hit"):call("recoverHpAndMaxHpCompletely(System.Boolean)", false) end) then n = n + 1 end
        end
        log.info("[dd2coop_death] derrota do grupo: " .. n .. " inimigos com a vida cheia")
    end)
    local msg = { t = "wipe", x = point[1], y = point[2], z = point[3], rift = rift, id = os.time() }
    M.out[#M.out + 1] = msg
    if _G.dd2coop_world then _G.dd2coop_world.urgent = true end
    M.on_wipe("host", msg)
end

-- outro jogador tocou numa Pedra de Fenda
function M.on_rift(sender, msg)
    if type(msg.x) ~= "number" or type(msg.y) ~= "number" or type(msg.z) ~= "number" then return end
    M.last_rift = { msg.x, msg.y, msg.z }
    if not M.dead then return end
    M.revive_at = { msg.x, msg.y, msg.z }
    local ok, why = M.revive()
    if not ok then M.revive_at = nil; M.message = "reviver na pedra: " .. tostring(why) end
end

-- Trava da interface de morte: ao morrer, o MainFlowManager ocupa o jogo com
-- OccupiedManager.tryLock("MainFlowManager", PlayerDieUI=5) nos sistemas A, B, C e E, e só a tela
-- de morte soltaria. Sem soltar, menu e mapa não abrem depois de reviver (o menu pede a trava
-- PauseMenu como "GameMenu") e uma nova morte nem pede a tela de morte. Soltar no mesmo quadro do
-- reviver não bastou; com o jogador já de pé, o jogo limpa em seguida as travas anteriores e a
-- interface ui022601 (2026-10-18).
local PLAYER_DIE_UI = 5 -- app.OccupiedManager.LockType.PlayerDieUI
local function unlock_death_ui()
    local om = sdk.get_managed_singleton("app.OccupiedManager")
    if not om then return false end
    local ok = om:call("unlock(System.String, app.OccupiedManager.LockType)", "MainFlowManager", PLAYER_DIE_UI)
    log.info("[dd2coop_death] trava da interface de morte solta: " .. tostring(ok))
    return ok
end

-- revive o jogador local pelo caminho da Vitalita, sem gastar item
function M.revive()
    local p = player()
    if not p then return false, "sem jogador" end
    if not p:call("get_IsDead") then M.dead = false; return false, "jogador nao esta morto" end
    local user = sdk.get_managed_singleton("app.CharacterManager"):get_field("<WakestoneUser>k__BackingField")
    if not user then return false, "WakestoneUser ausente" end
    M.move_to_safe = M.safe_pos ~= nil or M.revive_at ~= nil
    M.unlock_ui = true
    user:call("useWakestoneToRevivePlayer(app.Character)", p)
    M.revived = M.revived + 1
    log.info("[dd2coop_death] jogador revivido (caminho da Vitalita)")
    return true
end

local frame = 0
re.on_pre_application_entry("LateUpdateBehavior", function()
    frame = frame + 1
    if not M.dead then
        M.all_dead_since, M.wipe_pending = nil, nil
        if M.target then pcall(stop_spectating) end
        if frame % 60 == 0 then
            local ok, err = pcall(function()
                local p = player()
                if not p then return end
                -- revivido: de pé, solta a trava da interface de morte e vai para o lugar seguro
                if M.unlock_ui and not p:call("get_IsDead") then
                    M.unlock_ui = false
                    unlock_death_ui()
                end
                if M.move_to_safe and not p:call("get_IsDead") then
                    M.move_to_safe = false
                    warp_to_safe(p)
                    return
                end
                track_safe(p)
            end)
            if not ok then M.message = "erro no lugar seguro: " .. tostring(err) end
        end
        return
    end
    if frame % 15 ~= 0 then return end
    local ok, err = pcall(function()
        check_wipe()
        local p = player()
        if p and not p:call("get_IsDead") then
            M.dead = false
            stop_spectating()
            return
        end
        -- alvo atual morreu ou sumiu: outro jogador vivo
        local best = pick_target()
        if M.target and not (alive(M.target) and best and best:get_address() == M.target:get_address()) then
            M.target = nil
        end
        if not M.target then
            local target = pick_target()
            if target and spectate(target) then
                if p then set_input(p, false) end
                log.info("[dd2coop_death] espectador: camera seguindo um jogador vivo")
            end
        end
    end)
    if not ok then M.message = "erro no espectador: " .. tostring(err) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: morte em sessao") then return end
    imgui.text((M.dead and "MORTO (sem tela de morte)" or "vivo") ..
        " | telas bloqueadas=" .. M.blocked .. " | revividos=" .. M.revived)
    if M.dead then imgui.text(M.target and "espectador: seguindo um jogador vivo" or "nenhum jogador vivo para seguir") end
    local c, v = imgui.checkbox("Teste sem sessao", M.test)
    if c then M.test = v end
    if M.dead and imgui.button("Reviver agora") then
        local ok, why = M.revive()
        if not ok then M.message = tostring(why) end
    end
    if M.message ~= "" then imgui.text(M.message) end
    imgui.tree_pop()
end)

-- tela da derrota do grupo, por cima do jogo enquanto todos voltam ao ponto
re.on_frame(function()
    if not M.wipe_screen_until or os.clock() > M.wipe_screen_until then return end
    pcall(function()
        local w, h = 1920, 1080
        local ok, size = pcall(imgui.get_display_size)
        if ok and size then w, h = size.x, size.y end
        draw.filled_rect(0, 0, w, h, 0xFF000000)
        draw.text("O grupo caiu", w * 0.5 - 60, h * 0.5 - 20, 0xFFFFFFFF)
        draw.text(M.wipe_text or "Voltando...", w * 0.5 - 170, h * 0.5 + 6, 0xFFAAAAAA)
    end)
end)

log.info("[dd2coop_death] morte em sessao carregada")
