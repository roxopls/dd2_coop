-- DD2 Co-op: jogador caído e reviver, igual pawn.
-- Com outros jogadores na sessão, o jogador não morre de vez:
--   * vida chega a 0 (IsNoDie segura em 0..1): cai com a ação de pawn caído (DmgDownLoop),
--     fica invencível e sem controle; os outros recebem "caído" no vitals (dd2coop_world);
--   * quem está a menos de RANGE m da cópia caída e segura Interagir (bit 6 do ButtonOnFlags,
--     app.CharacterInput.Action.Interact) por HOLD s revive: aviso na tela, toca RescuePawn ->
--     RescuePawnEnd e manda {t="revive", target=<SteamID do caído>} pelo barramento;
--   * revivido: levanta (DmgStandup) com REVIVE_HP da vida máxima;
--   * ninguém reviveu em BLEED s (ou a sessão acabou): morte normal do jogo.
-- Queda no abismo (IsFallDead) segue a morte normal.
-- Nomes de ação vistos no jogo (2026-10-17): pawn caído DmgDownLoop, jogador reviveu com
-- RescuePawn/RescuePawnEnd, pawn levantou com DmgStandup.
local M = { frame = 0, downed = false, down_at = 0, out = {}, remote = {}, message = "",
    revived = 0, test = false }
_G.dd2coop_revive = M

local BLEED = 60       -- s caído até morrer de vez
local RANGE = 1.8      -- m da cópia caída para reviver
local HOLD = 3.0       -- s segurando Interagir para reviver
local INTERACT_BIT = 1 << 6
local REVIVE_HP = 0.3  -- fração da vida máxima ao levantar
local CORE = sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore")
local KILL = "killAndSetDieLoop(app.Character.KillAndSetDieLoopOption)"

local function me() return sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer") end
local function act(ch, name) pcall(function() CORE:call(ch:call("get_ActionManager"), 10, name, 0) end) end

local function session()
    local S = _G.dd2coop_session
    local ls = S and S.status
    local on = M.test or (ls and (ls.role == "host" or ls.role == "cliente") and S.peers and #S.peers > 0)
    return on, ls and ls.me
end

local function set_input(p, on)
    pcall(function() p:call("get_InputProcessor"):call("set_IsEnable", on) end)
end

local function go_down(p)
    local hit = p:call("get_Hit")
    M.downed, M.down_at = true, os.clock()
    hit:call("set_IsInvincible", true)
    set_input(p, false)
    act(p, "DmgDownLoop")
    log.info("[dd2coop_revive] caido; aguardando reviver")
end

local function get_up(p)
    local hit = p:call("get_Hit")
    M.downed = false
    hit:call("setHp(System.Single, System.Boolean, System.Int32)", math.max(1, hit:call("get_ReducedMaxHp") * REVIVE_HP), false, 0)
    hit:call("set_IsInvincible", false)
    set_input(p, true)
    act(p, "DmgStandup")
    M.revived = M.revived + 1
    log.info("[dd2coop_revive] revivido")
end

local function die_for_real(p)
    local hit = p:call("get_Hit")
    M.downed = false
    hit:call("set_IsNoDie", false)
    hit:call("set_IsInvincible", false)
    set_input(p, true)
    p:call(KILL, nil)
    log.info("[dd2coop_revive] ninguem reviveu: morte normal")
end

-- barramento (dd2coop_world): o que vai no vitals e as mensagens a enviar
function M.vitals_extra() return M.downed end
function M.outgoing()
    local o = M.out
    M.out = {}
    return o
end

-- vitals de outro jogador: guarda se está caído e faz a cópia dele deitar
function M.on_vitals(sender, msg, clone)
    local r = M.remote[sender] or {}
    M.remote[sender] = r
    local down = msg.down == true
    if down and not r.down and clone then act(clone, "DmgDownLoop") end
    if not down and r.down and clone then act(clone, "DmgStandup") end
    r.down, r.clone, r.near = down, clone, r.near or 0
end

function M.on_revive(sender, msg, my_id)
    if msg.target ~= my_id and not (M.test and msg.target == "0") then return end
    if M.downed then pcall(get_up, me()) end
end

local function dist(a, b)
    local p = a:call("get_GameObject"):call("get_Transform"):call("get_Position")
    local q = b:call("get_GameObject"):call("get_Transform"):call("get_Position")
    return math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2)
end

local last = os.clock()
re.on_pre_application_entry("LateUpdateBehavior", function()
    M.frame = M.frame + 1
    if M.frame % 10 ~= 0 then return end
    local now = os.clock()
    local dt = now - last
    last = now
    local ok, err = pcall(function()
        local p = me()
        if not p then return end
        local hit = p:call("get_Hit")
        local on, my_id = session()
        if not on then
            if M.downed then die_for_real(p) end
            if M.nodie then hit:call("set_IsNoDie", false); M.nodie = false end
            return
        end
        if not M.nodie then hit:call("set_IsNoDie", true); M.nodie = true end
        if p:call("get_IsFallDead") then
            if M.downed then M.downed = false; hit:call("set_IsInvincible", false); set_input(p, true) end
            hit:call("set_IsNoDie", false); M.nodie = false
            return
        end
        if not M.downed and hit:call("get_Hp") <= 1 then go_down(p) end
        if M.downed then
            if now - M.down_at > BLEED then die_for_real(p); return end
            -- mantém deitado (golpes/física podem trocar a ação); a cada ~3 s para não reiniciar a animação
            if M.frame % 180 == 0 then act(p, "DmgDownLoop") end
        end
        -- reviver os outros: perto da cópia caída, segurando Interagir por HOLD s
        M.prompt = nil
        if not M.downed then
            local flags = 0
            pcall(function() flags = p:call("get_Input"):get_field("ButtonOnFlags") end)
            local holding = (flags & INTERACT_BIT) ~= 0
            for sender, r in pairs(M.remote) do
                if r.down and r.clone then
                    local d = dist(p, r.clone)
                    if d <= RANGE then
                        M.prompt = { clone = r.clone, progress = r.near / HOLD }
                        if not holding then r.near = 0; goto continue end
                        if r.near == 0 then act(p, "RescuePawn") end
                        r.near = r.near + dt
                        if r.near >= HOLD then
                            act(p, "RescuePawnEnd")
                            M.out[#M.out + 1] = { t = "revive", target = sender, id = os.time() }
                            r.down, r.near = false, 0
                            act(r.clone, "DmgStandup") -- levanta já aqui; o vitals do caído confirma
                            if _G.dd2coop_world then _G.dd2coop_world.urgent = true end
                            log.info("[dd2coop_revive] reviveu " .. sender)
                        end
                    else
                        r.near = 0
                    end
                end
                ::continue::
            end
        end
    end)
    if not ok then M.message = "erro no reviver: " .. tostring(err) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: cair e reviver") then return end
    imgui.text(M.downed and string.format("CAIDO (%.0f s para morrer)", BLEED - (os.clock() - M.down_at)) or "de pe")
    imgui.text("revividos=" .. M.revived)
    local c, v = imgui.checkbox("Teste sem sessao (eco)", M.test)
    if c then M.test = v end
    if M.message ~= "" then imgui.text(M.message) end
    imgui.tree_pop()
end)

log.info("[dd2coop_revive] cair e reviver carregado")

-- aviso na tela sobre a cópia caída
re.on_frame(function()
    local pr = M.prompt
    if not pr then return end
    pcall(function()
        local pos = pr.clone:call("get_GameObject"):call("get_Transform"):call("get_Position")
        local sp = draw.world_to_screen(Vector3f.new(pos.x, pos.y + 1.0, pos.z))
        if not sp then return end
        local text = pr.progress > 0 and string.format("Ajudando... %d%%", math.floor(pr.progress * 100))
            or "Segure Interagir para ajudar"
        draw.text(text, sp.x - 90, sp.y, 0xFFFFFFFF)
        if pr.progress > 0 then
            draw.filled_rect(sp.x - 90, sp.y + 22, 180, 8, 0x80000000)
            draw.filled_rect(sp.x - 90, sp.y + 22, 180 * math.min(1, pr.progress), 8, 0xFF40C0FF)
        end
    end)
end)
