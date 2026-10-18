-- DD2 Co-op: cópias dos jogadores 3 e 4 (o jogador 2 continua no dd2coop_puppet.lua).
-- Para cada membro da sessão além do par do jogador 2, cria uma cópia de Arisen com o avatar e
-- a vocação/armas do perfil dele e entrega ao plugin (slots 1 e 2 da config de rede, escrita
-- pelo puppet). Regras aprendidas em 2026-10-17:
--   * uma cópia por vez: duas no mesmo quadro crasham em GenerateManager.calcSystemPriority;
--   * o container de geração fica referenciado (add_ref) enquanto a cópia existir: sem isso o
--     GC o libera e o jogo crasha ao abrir o menu;
--   * no máximo 4 Arisen (a 5ª trava em safeRequestCreateInstance);
--   * a cópia nova vira o ManualPlayer: controle e câmera voltam ao original logo depois.
-- Cópias não são destruídas (destruir Arisen crasha): quem sai fica escondido e parado, e a
-- cópia é reaproveitada se o mesmo jogador voltar.
-- Visível só enquanto chega input dele (slot do plugin ativo) e ele não está morto.
local M = { frame = 0, slots = {}, message = "", busy = nil }
_G.dd2coop_extra = M

local ARISEN_ID = 2891076981
local MAX_EXTRA = 2

local function cm() return sdk.get_managed_singleton("app.CharacterManager") end

local function gm_method(name, np, first)
    local GM = sdk.get_managed_singleton("app.GenerateManager")
    for _, m in ipairs(GM:get_type_definition():get_methods()) do
        if m:get_name() == name and m:get_num_params() == np
            and (first == nil or m:get_param_types()[1]:get_full_name() == first) then
            return GM, m
        end
    end
end

local function main_camera_controller()
    local ok, mcc = pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
        local list = scene:call("findComponents(System.Type)", sdk.typeof("app.MainCameraController"))
        return list and list:get_size() > 0 and list:get_element(0) or nil
    end)
    return ok and mcc or nil
end

function M.owns(ch)
    if not ch then return false end
    local a = ch:get_address()
    for _, s in ipairs(M.slots) do if s.addr == a then return true end end
    -- recém-nascida, ainda não adotada: qualquer Arisen que não existia antes do pedido
    local b = M.busy
    if b and b.state == "gerando" and b.before and not b.before[a] then return true end
    return false
end

local function slot_of(peer)
    for _, s in ipairs(M.slots) do if s.peer == peer then return s end end
end

-- todos os Arisen vivos agora (endereço -> Character)
local function arisen_now()
    local out = {}
    local all = sdk.get_managed_singleton("app.CharacterListHolder"):call("getAllCharacters")
    for i = 0, all:call("get_Count") - 1 do
        local ch = all:call("get_Item", i)
        if ch and ch:call("get_CharaID") == ARISEN_ID then out[ch:get_address()] = ch end
    end
    return out
end

local function original()
    local s = _G.dd2coop_p2
    return s and s.orig or cm():call("get_ManualPlayer")
end

-- controle e câmera de volta ao original (a cópia recém-criada toma o ManualPlayer)
local function settle(orig)
    local man = cm():call("get_ManualPlayer")
    if man == nil or man:get_address() ~= orig:get_address() then cm():call("set_ManualPlayer", orig) end
    -- ManualPlayerHuman/Player e calculador de status também ficam na cópia (dd2coop_isolation)
    if _G.dd2coop_isolation and _G.dd2coop_isolation.fix_refs then _G.dd2coop_isolation.fix_refs(orig) end
    local mcc = main_camera_controller()
    if mcc then
        local tc = mcc:call("get_TargetCharacter")
        if tc == nil or tc:get_address() ~= orig:get_address() then
            mcc:call("registerTargetObject", orig:call("get_GameObject"))
        end
    end
end

local function spawn(slot)
    local A = _G.dd2coop_avatar
    local bundle = A and A.peer_bundle(slot.peer)
    if not bundle then return false end
    local orig = original()
    if not orig then return false end
    local before = arisen_now()
    local count = 0
    for _ in pairs(before) do count = count + 1 end
    if count >= 4 then
        slot.state, slot.info = "limite", "limite de 4 Arisen"
        return false
    end
    A.next_build = { data = bundle.avatar, original = orig, skip = before }
    local guid = sdk.find_type_definition("System.Guid"):get_method("NewGuid"):call(nil)
    local GM, m_gen = gm_method("createGeneratorID", 2, "System.Guid")
    local _, m_uid = gm_method("createUniqueID", 2, "System.Guid")
    local _, m_box = gm_method("getPoolGenerateInfoContainerForCharacter", 9)
    local _, m_new = gm_method("safeRequestCreateInstance", 3)
    local xf = orig:call("get_GameObject"):call("get_Transform")
    local rot = xf:call("get_Rotation")
    local fwd = rot * Vector3f.new(0, 0, -3)
    local up = xf:call("get_UniversalPosition")
    up.x, up.z = up.x + fwd.x, up.z + fwd.z
    local c = m_box:call(GM, m_gen:call(GM, guid, 0), m_uid:call(GM, guid, 0), up, rot,
        Vector3f.new(1, 1, 1), 0, 0, ARISEN_ID, 2)
    if c == nil then A.next_build = nil; slot.info = "container nao criado"; return false end
    -- vivo enquanto a cópia existir (ver cabeçalho); permanente: add_ref() é solta no reset de scripts
    if c.add_ref_permanent then c:add_ref_permanent() else c:add_ref() end
    slot.container = c
    slot.before, slot.started, slot.state = before, M.frame, "gerando"
    slot.profile = bundle.profile
    m_new:call(GM, c, nil, nil)
    M.busy = slot
    log.info("[dd2coop_extra] copia pedida para " .. slot.peer)
    return true
end

local function adopt(slot, ch, orig)
    slot.clone = ch:add_ref()
    slot.addr = ch:get_address()
    pcall(settle, orig)
    pcall(function() ch:call("get_InputProcessor"):call("set_IsEnable", false) end)
    pcall(function()
        local hit = ch:call("get_Hit")
        hit:call("set_IsNoDie", true)        -- a vida dele é decidida no PC dele
        hit:call("set_IsInvincible", true)
    end)
    pcall(function() ch:call("get_GameObject"):call("set_DrawSelf", false) end)
    slot.drawn = false
    slot.state = "loadout"
    log.info(string.format("[dd2coop_extra] copia de %s criada (0x%X)", slot.peer, slot.addr))
end

local function step_slot(slot)
    local orig = original()
    if not orig then return end
    if slot.state == "gerando" then
        pcall(settle, orig)
        for a, ch in pairs(arisen_now()) do
            if not slot.before[a] then adopt(slot, ch, orig); slot.before = nil; M.busy = nil; return end
        end
        if M.frame - slot.started > 900 then -- ~15 s
            slot.state, slot.info, M.busy = "falhou", "copia nao apareceu", nil
            local A = _G.dd2coop_avatar
            if A then A.next_build = nil end
        end
    elseif slot.state == "loadout" then
        local L = _G.dd2coop_loadout
        if not slot.profile or not L then slot.state = "pronto"; return end
        if L.pending then return end
        if slot.loadout_started then slot.state = "pronto"; return end
        slot.loadout_started = true
        if not L.apply(slot.profile, slot.clone) then slot.state = "pronto" end
    end
end

-- visibilidade: só com input chegando dele e vivo
local function visibility(slot, status)
    if slot.state ~= "pronto" or not slot.clone then return end
    local live = false
    slot.remote_pose = nil
    for _, s in ipairs(status and status.slots or {}) do
        if s.peer == slot.peer then
            live = s.input_state == "active" or s.input_state == "buffering"
            if live and s.remote_valid then slot.remote_pose = { s.rx, s.ry, s.rz } end -- dd2coop_park
        end
    end
    local parked = _G.dd2coop_park and _G.dd2coop_park.is_parked("x:" .. tostring(slot.peer)) -- longe
    local show = live and not slot.remote_dead and slot.active and not parked
    if slot.drawn ~= show then
        slot.drawn = show
        pcall(function() slot.clone:call("get_GameObject"):call("set_DrawSelf", show) end)
    end
end

function M.clone_of(peer)
    local s = slot_of(peer)
    return s and s.clone or nil
end

function M.set_dead(peer, dead)
    local s = slot_of(peer)
    if s then s.remote_dead = dead end
end

-- slots 1.. da config de rede (o puppet escreve): todo jogador da sessão além do jogador 2,
-- com a cópia quando ela estiver pronta (sem cópia o plugin só envia o input para ele)
function M.net_peers(main_peer)
    local out = {}
    local S = _G.dd2coop_session
    for _, peer in ipairs(S and S.peers or {}) do
        if peer ~= main_peer then
            local e = { peer = peer, clone = 0, clone_xf = 0, clone_ch = 0 }
            local s = slot_of(peer)
            if s and s.state == "pronto" and s.clone and s.active then
                pcall(function()
                    e.clone = s.clone:call("get_Input"):get_address()
                    e.clone_xf = s.clone:call("get_GameObject"):call("get_Transform"):get_address()
                    e.clone_ch = s.clone:get_address()
                end)
            end
            out[#out + 1] = e
        end
    end
    return out
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    M.frame = M.frame + 1
    if M.frame % 30 ~= 0 then return end
    local ok, err = pcall(function()
        local S, P = _G.dd2coop_session, _G.dd2coop_p2
        local main = S and S.peer
        local wanted = {}
        for _, peer in ipairs(S and S.peers or {}) do
            if peer ~= main then wanted[peer] = true end
        end
        -- quem saiu: cópia escondida e fora da rede; quem está: ativo
        for _, s in ipairs(M.slots) do s.active = wanted[s.peer] == true end
        for _, s in ipairs(M.slots) do pcall(step_slot, s) end
        -- nova cópia só com o jogador 2 resolvido, nada sendo criado e o loadout livre
        local can_spawn = not M.busy and P and (P.state == "pronto" or P.state == "nenhum") and
            not (_G.dd2coop_loadout and _G.dd2coop_loadout.pending) and
            not (_G.dd2coop_avatar and (_G.dd2coop_avatar.armed or _G.dd2coop_avatar.next_build)) and
            (P.state == "pronto" or not main) and
            (_G.dd2coop_party and _G.dd2coop_party.away()) -- pawns no mundo + cópia passam do limite do grupo
        if can_spawn then
            for peer in pairs(wanted) do
                if not slot_of(peer) then
                    -- reaproveita a cópia de quem saiu (destruir crasha); senão, cria
                    local free
                    for _, s in ipairs(M.slots) do if not s.active and s.state == "pronto" then free = s end end
                    if free then
                        log.info("[dd2coop_extra] copia de " .. free.peer .. " reaproveitada para " .. peer)
                        free.peer, free.remote_dead, free.loadout_started = peer, false, false
                        free.reuse = true -- aparência é a do anterior até haver troca ao vivo
                        free.active = true
                    elseif #M.slots < MAX_EXTRA then
                        local slot = { peer = peer, state = "nenhum", active = true }
                        M.slots[#M.slots + 1] = slot
                        if not spawn(slot) then table.remove(M.slots) end
                    end
                    break -- um por vez
                end
            end
        end
        local status = P and P.net_status
        for _, s in ipairs(M.slots) do visibility(s, status) end
    end)
    if not ok then M.message = "erro nas copias extras: " .. tostring(err) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: jogadores 3 e 4") then return end
    if #M.slots == 0 then imgui.text("nenhuma copia extra") end
    for i, s in ipairs(M.slots) do
        imgui.text(string.format("%d: %s  estado=%s  ativo=%s  visivel=%s%s", i + 2, tostring(s.peer), tostring(s.state),
            tostring(s.active), tostring(s.drawn), s.info and ("  " .. s.info) or ""))
    end
    if M.message ~= "" then imgui.text(M.message) end
    imgui.tree_pop()
end)

log.info("[dd2coop_extra] jogadores 3 e 4 carregado")
