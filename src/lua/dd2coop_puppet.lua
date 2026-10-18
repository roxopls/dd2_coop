-- DD2 Co-op: jogador 2, sessao local e recuperacao apos reset de scripts.
--
-- O jogador 2 é um segundo Arisen gerado pelo app.GenerateManager:
--   categoria 0 (Arisen), CharacterID proprio por dd2coop_replica_id (fallback ch000000_00),
--   IDs nativos NoUsePool com GUID novo, HumanInfo copiado antes de safeRequestCreateInstance.
-- Ele nasce com a lógica completa de player (PlayerInputProcessor, app.Player): mesmo
-- corpo, mesma passada, mesmas ações. Efeitos colaterais tratados aqui:
--   * ele vira o CharacterManager.ManualPlayer e leva a câmera: o original é devolvido
--     (set_ManualPlayer) e a câmera volta (MainCameraController.registerTargetObject),
--     reforçados por alguns segundos porque o jogo pode trocar de novo;
--   * ele obedece ao mesmo controle: o input dele é desligado
--     (InputProcessor.set_IsEnable(false)) ou, no espelho, substituído;
--   * nasce sem equipamento e com outro cabelo: recebe os estilos do player
--     (PartSwapper.restore(MetaData, VisorSwitch) + requestSwap).
-- Save: enquanto ele existir, os pedidos de save são barrados (SaveDataManager.requestSave*
-- e MainFlowManager.requestSaveGameData), inclusive com CharacterID proprio.
--
-- Espelho por input (teste do jogador remoto sem rede): o estado do controle do player
-- (app.UserInput: flags de botão, analógicos, gatilhos) é gravado a cada frame depois do
-- update do input dele, e aplicado no input do jogador 2 com atraso, no lugar do update
-- normal (que leria o controle). É exatamente o dado que a rede vai transportar.
--
-- Painel: Script Generated UI > "DD2 Co-op: jogador 2".
--
-- Histórico: NPC/pawn gerados quebram ao receber o corpo/rosto do Arisen
-- (BodyEditorRoot.JointEditValue::setTRS, FaceEditor::destroyTargetObject); prefab
-- instanciado na mão e o mockup do menu não têm o transform atualizado. Ver memória.

log.info("[dd2coop] jogador 2 carregado")

local ARISEN_ID = 2891076981   -- ch000000_00
local ARISEN_CATEGORY = 0

local cfg = {
    block_save = true,
    mirror = false,
    delay = 30,          -- atraso do espelho, em frames
    jitter = 6,
    peer = "",
    snap_dist = 1.5,
    smooth_correction = true,
    echo_correction = false,
}

local SETTINGS, REGISTRY = "dd2coop_settings.json", "dd2coop_session.json"
local function load_json(path)
    local ok, value = pcall(json.load_file, path)
    return ok and type(value) == "table" and value or nil
end
local function bounded(value, fallback, lo, hi, integer)
    value = tonumber(value)
    if not value or value ~= value then value = fallback end
    value = math.max(lo, math.min(hi, value))
    return integer and math.floor(value) or value
end
local saved_cfg = load_json(SETTINGS) or {}
cfg.delay = bounded(saved_cfg.delay, cfg.delay, 1, 120, true)
cfg.jitter = bounded(saved_cfg.jitter, cfg.jitter, 1, 60, true)
cfg.snap_dist = bounded(saved_cfg.snap_dist, cfg.snap_dist, 0.3, 6, false)
if type(saved_cfg.smooth_correction) == "boolean" then cfg.smooth_correction = saved_cfg.smooth_correction end
if type(saved_cfg.echo_correction) == "boolean" then cfg.echo_correction = saved_cfg.echo_correction end
if type(saved_cfg.peer) == "string" then cfg.peer = saved_cfg.peer:sub(1, 32):gsub("%s", "") end
local function save_settings()
    return pcall(json.dump_file, SETTINGS, { version = 1, peer = cfg.peer,
        delay = cfg.delay, jitter = cfg.jitter, snap_dist = cfg.snap_dist,
        smooth_correction = cfg.smooth_correction, echo_correction = cfg.echo_correction })
end
local saved_session = load_json(REGISTRY) or {}

local st = {
    state = "verificando", -- nenhum | gerando | aguardando | pronto | recuperacao
    container = nil,
    orig = nil,          -- app.Character original (o player)
    clone = nil,         -- app.Character do jogador 2
    guard_until = 0,     -- até quando reforçar ManualPlayer/câmera
    frame = 0,
    snaps = {},          -- frame -> estado do controle do player
    n_saves_blocked = 0, n_applied = 0,
    info = "",
    source_idx = 1,
    candidates = {},
}

local write_net_cfg, recover, remember, set_source
local function key(ch)
    return ch and string.format("0x%X", ch:get_address()) or nil
end
local function locked() return st.state ~= "nenhum" end

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

-- geração ---------------------------------------------------------------------------

local function spawn()
    recover()
    if st.state ~= "nenhum" then st.info = "jogador 2 ja existe"; return end
    local p = cm():call("get_ManualPlayer")
    if p == nil then st.info = "sem player"; return end
    if not st.net_status or (tonumber(st.net_status.save_hooks) or 0) == 0 then
        st.info = "protecao nativa indisponivel; atualize o plugin antes de criar a copia"; return
    end
    -- com os pawns no mundo a cópia passa do limite do grupo e o jogo crasha (dd2coop_party)
    local party = _G.dd2coop_party
    if not party or not party.away() then
        if party then party.send_away() end
        st.info = "aguardando os pawns sairem; tente de novo em alguns segundos"; return false
    end
    -- CharacterID próprio (dd2coop_replica_id): inventário e status separados do jogador. Se a
    -- preparação do ID falhar, a cópia nasce com o ID do Arisen, como antes.
    local R = _G.dd2coop_replica_id
    local spawn_id = ARISEN_ID
    local own_id = R and R.id_for(1)
    if own_id and not R.failed(own_id) then
        if not R.ensure(own_id) then st.info = "preparando o ID proprio da copia"; return false end
        spawn_id = own_id
    end
    st.orig = p:add_ref()
    st.avatar_applied = false -- dd2coop_avatar marca true se aplicar o avatar antes da montagem
    st.state = "gerando" -- block saves BEFORE requesting any generated object
    st.guard_until = os.time() + 15
    if not remember() then st.state = "recuperacao"; st.info = "falha ao registrar a sessao"; return end
    write_net_cfg("off")
    local guid = sdk.find_type_definition("System.Guid"):get_method("NewGuid"):call(nil)
    local GM, m_gen = gm_method("createGeneratorIDNoUsePool", 2, "System.Guid")
    local _, m_uid = gm_method("createUniqueIDNoUsePool", 2, "System.Guid")
    local _, m_box = gm_method("getPoolGenerateInfoContainerForCharacter", 9)
    local _, m_new = gm_method("safeRequestCreateInstance", 3)
    local xf = p:call("get_GameObject"):call("get_Transform")
    local rot = xf:call("get_Rotation")
    local fwd = rot * Vector3f.new(0, 0, 1)
    local up = xf:call("get_UniversalPosition")
    up.x = up.x + fwd.x * 3.0
    up.z = up.z + fwd.z * 3.0
    local gen = m_gen:call(GM, guid, 0)
    if R then R.retain_generation_id(gen) elseif gen then gen:add_ref() end
    local uid = m_uid:call(GM, guid, 0)
    if R then R.retain_generation_id(uid) elseif uid then uid:add_ref() end
    local c = m_box:call(GM, gen, uid, up, rot,
        Vector3f.new(1, 1, 1), ARISEN_CATEGORY, 0, spawn_id, 2)
    if c == nil then st.state = "nenhum"; remember(); write_net_cfg("off"); st.info = "container nao criado"; return end
    -- referência permanente: add_ref() é solta no reset de scripts e o container liberado deixava a
    -- cópia viva apontando para memória morta (crash ~40 s depois de um reset, 2026-10-17)
    if c.add_ref_permanent then c:add_ref_permanent() else c:add_ref() end
    st.container = c
    st.state = "gerando"
    st.guard_until = os.time() + 15
    if R then
        local ok, err = R.prepare_container(c)
        if not ok then
            st.state, st.info = "recuperacao", "falha ao preparar a copia: " .. tostring(err)
            remember(); write_net_cfg("off")
            return false
        end
    end
    if spawn_id ~= ARISEN_ID then R.arm_classification(spawn_id) end
    local r = m_new:call(GM, c, nil, nil)
    st.info = "geracao pedida (" .. tostring(r) .. ")"
    log.info("[dd2coop] jogador 2: " .. st.info)
end

-- depois de nascer: player e câmera de volta, input desligado, estilos do player
local function settle()
    local orig, clone = st.orig, st.clone
    local man = cm():call("get_ManualPlayer")
    if man == nil or man:get_address() ~= orig:get_address() then
        cm():call("set_ManualPlayer", orig)
    end
    -- ManualPlayerHuman/Player e calculador de status também ficam na cópia (dd2coop_isolation)
    if _G.dd2coop_isolation and _G.dd2coop_isolation.fix_refs then _G.dd2coop_isolation.fix_refs(orig) end
    local mcc = main_camera_controller()
    if mcc then
        local tc = mcc:call("get_TargetCharacter")
        if tc == nil or tc:get_address() ~= orig:get_address() then
            mcc:call("registerTargetObject", orig:call("get_GameObject"))
        end
        -- NÃO chamar mcc:set_UserInput aqui: crashava a criação da cópia ou minutos depois
        -- (2026-10-18). O controle da câmera é protegido no dd2coop_camera.lua.
    end
    if clone and (st.source_idx or 1) == 1 then
        pcall(function() clone:call("get_InputProcessor"):call("set_IsEnable", false) end)
    end
end

local function dress()
    pcall(function()
        local psw = st.orig:call("get_HumanPartSwapper")
        local csw = st.clone:call("get_HumanPartSwapper")
        csw:call("restore(app.CharacterEditDefine.MetaData, app.CharacterEditDefine.VisorSwitch)",
            psw:get_field("_Meta"), psw:call("get_VisorSwitch"))
        csw:call("requestSwap()")
    end)
end

local function scan_arisen()
    local manual = cm():call("get_ManualPlayer")
    if not manual then return nil end
    local all = sdk.get_managed_singleton("app.CharacterListHolder"):call("getAllCharacters")
    if not all then return nil end
    local found = {}
    for i = 0, all:call("get_Count") - 1 do
        local ch = all:call("get_Item", i)
        -- as cópias dos jogadores 3 e 4 (dd2coop_extra) não entram na recuperação do jogador 2
        local id = ch and ch:call("get_CharaID")
        local R = _G.dd2coop_replica_id
        -- o original (Arisen) e a cópia do jogador 2, que pode ter o ID próprio
        if ch and (id == ARISEN_ID or (R and R.is_replica(id))) and not (_G.dd2coop_extra and _G.dd2coop_extra.owns(ch)) then
            found[#found + 1] = ch
        end
    end
    return found, manual
end

remember = function()
    local record = { version = 1, instance = st.instance, phase = st.state,
        original = key(st.orig), clone = key(st.clone), hidden = st.hidden == true }
    local ok, result = pcall(json.dump_file, REGISTRY, record)
    if ok and result ~= false then saved_session = record; return true end
    return false
end

local function adopt(orig, clone, restored)
    st.orig, st.clone = orig:add_ref(), clone:add_ref()
    st.state, st.source_idx, cfg.mirror = "pronto", 1, false
    st.snaps = {}
    st.hidden = restored and saved_session.hidden == true or false
    pcall(function() st.geninfo_addr = clone:call("get_GenerateInfo"):get_address() end)
    pcall(function() clone:call("get_InputProcessor"):call("set_IsEnable", false) end)
    -- a vida do jogador 2 e do jogador remoto (morte chega pelo barramento): aqui ele nao
    -- morre nem leva dano (queda, inimigos), senao ficava caido/morto so neste mundo
    pcall(function()
        local hit = clone:call("get_Hit")
        hit:call("set_IsNoDie", true)
        hit:call("set_IsInvincible", true)
    end)
    -- stamina: segue a do jogador remoto (dd2coop_world, vitals.st); até lá, cheia e sem consumo
    pcall(function()
        local sm = clone:call("get_StaminaManager")
        sm:call("set_IsEnableConsume", false)
        sm:call("recoverAll")
    end)
    pcall(function() clone:call("get_GameObject"):call("set_DrawSelf", not st.hidden) end)
    st.drawn = nil -- visibilidade automatica (conectado) reavalia
    st.guard_until = os.time() + 15
    pcall(settle)
    -- ID próprio: o calculador de status dele só liga depois da adoção (dd2coop_replica_id)
    local R = _G.dd2coop_replica_id
    if R and R.is_replica(clone:call("get_CharaID")) then R.bind(clone) end
    -- com avatar aplicado na montagem, a roupa ja veio do arquivo; nao sobrescrever com a do original
    if not restored and not st.avatar_applied then dress() end
    remember()
    write_net_cfg("off")
    st.info = restored and "sessao recuperada; jogador 2 parado" or "jogador 2 pronto"
    log.info("[dd2coop] " .. st.info)
end

recover = function()
    local status = load_json("dd2coop_net_status.json")
    if not status or type(status.instance) ~= "string" then
        st.info = "aguardando identificacao desta execucao pelo plugin"
        return
    end
    st.instance, st.net_status = status.instance, status
    local found, manual = scan_arisen()
    if not found or #found == 0 then return end
    local same = saved_session.instance == st.instance
    if #found == 1 then
        local uncertain = same and saved_session.phase ~= "nenhum" and saved_session.original ~= nil
        -- recarga do save (morte -> menu -> carregar) destrói a cópia e recria o jogador: se o
        -- único Arisen vivo é o do controle e não é a cópia registrada, a sessão recomeça do zero
        -- e o jogador tambem tem identidade nova; sumir apenas a copia nao libera o save
        if uncertain and saved_session.phase == "pronto" and saved_session.clone ~= nil and
            key(found[1]) ~= saved_session.clone and key(found[1]) ~= saved_session.original and
            key(found[1]) == key(manual) then
            st.state, st.orig, st.clone, st.source_idx, cfg.mirror = "nenhum", nil, nil, 1, false
            remember()
            write_net_cfg("off")
            st.info = "copia sumiu com a recarga do save; pronta para criar de novo"
            log.info("[dd2coop] " .. st.info)
            return
        end
        if uncertain then
            st.source_idx, cfg.mirror = 1, false
            if key(found[1]) == saved_session.original and key(st.orig) ~= key(found[1]) then
                st.orig = found[1]:add_ref()
            end
            if saved_session.phase == "gerando" or saved_session.phase == "aguardando" then
                st.state = "aguardando" -- a delayed spawn may still complete
            else
                st.state = "recuperacao"
                st.info = "copia ausente; save continua protegido ate reiniciar o jogo"
                if key(found[1]) == saved_session.clone then
                    pcall(function() found[1]:call("get_InputProcessor"):call("set_IsEnable", false) end)
                    st.info = "original ausente; sessao parada e save protegido ate reiniciar o jogo"
                end
            end
        elseif key(found[1]) == key(manual) then
            st.state, st.orig = "nenhum", nil
            remember()
        end
        write_net_cfg("off")
        return
    end
    local orig, clone
    if same then
        for _, ch in ipairs(found) do
            if key(ch) == saved_session.original then orig = ch end
            if key(ch) == saved_session.clone then clone = ch end
        end
        if orig and not clone and #found == 2 and
            (saved_session.phase == "gerando" or saved_session.phase == "aguardando") then
            for _, ch in ipairs(found) do if key(ch) ~= key(orig) then clone = ch end end
        end
    end
    if orig and clone and #found == 2 and key(orig) ~= key(clone) then
        if st.state ~= "pronto" or key(st.clone) ~= key(clone) or key(st.orig) ~= key(orig) then
            adopt(orig, clone, saved_session.clone ~= nil)
        end
        return
    end
    st.state, st.source_idx, cfg.mirror = "recuperacao", 1, false
    st.candidates = {}
    for _, ch in ipairs(found) do
        -- Keep only the currently controlled body reading local input while the
        -- user identifies the original. This does not infer original identity.
        if key(ch) ~= key(manual) then
            pcall(function() ch:call("get_InputProcessor"):call("set_IsEnable", false) end)
        end
        st.candidates[#st.candidates + 1] = { address = key(ch), label = key(ch)
            .. (key(ch) == key(manual) and " (controle atual)" or "") }
    end
    st.info = "original nao identificado; escolha abaixo. Nova criacao e save bloqueados"
    write_net_cfg("off")
end

st.create = spawn
st.recover = recover
st.confirm_original = function(address)
    local found = scan_arisen()
    if not found or #found ~= 2 then st.info = "recuperacao exige exatamente dois Arisen vivos"; return false end
    local orig, clone
    for _, ch in ipairs(found) do
        if key(ch) == address then orig = ch else clone = ch end
    end
    if not orig or not clone then return false end
    pcall(function() orig:call("get_InputProcessor"):call("set_IsEnable", true) end)
    adopt(orig, clone, true)
    return true
end

_G.dd2coop_p2 = st
-- false: não criou (ex.: pawns ainda saindo); a sessão tenta de novo
st.spawn = function() local ok, r = pcall(spawn); return ok and r ~= false end
-- sessao (dd2coop_session.lua): o par vem do lobby, nao precisa ser digitado
st.set_peer = function(id)
    if type(id) ~= "string" or not id:match("^%d+$") then return false end
    if cfg.peer ~= id then cfg.peer = id; save_settings() end
    return true
end
st.get_peer = function() return cfg.peer end

-- save barrado enquanto o jogador 2 existir (exceto com o save co-op ativo) --------------

local function hook_block(tn, names)
    local td = sdk.find_type_definition(tn)
    for _, m in ipairs(td and td:get_methods() or {}) do
        if names[m:get_name()] then
            local returns_bool = m:get_return_type():get_full_name() == "System.Boolean"
            sdk.hook(m, function(args)
                -- com o save co-op ativo (win64_coop) o vanilla nao e tocado: nao barra
                local coop = _G.dd2coop_save and _G.dd2coop_save.status and _G.dd2coop_save.status.coop == true
                if locked() and not coop then
                    st.n_saves_blocked = st.n_saves_blocked + 1
                    log.info("[dd2coop] jogador 2: save barrado (" .. tn .. "." .. m:get_name() .. ")")
                    if returns_bool then thread.get_hook_storage().blocked = true end
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(r)
                local s = thread.get_hook_storage()
                if s and s.blocked then s.blocked = nil; return sdk.to_ptr(0) end
                return r
            end)
        end
    end
end
hook_block("app.SaveDataManager", { requestSave = true, requestSaveAuto = true, requestSaveManual = true,
    requestSaveSlot = true })
hook_block("app.MainFlowManager", { requestSaveGameData = true })

-- lógica de geração pulada no jogador 2 ---------------------------------------------------
-- O app.GenerateInfo dele chama GenerateManager.calcSystemPriority (prioridade/distância de
-- geração), que não prevê um segundo Arisen e derruba o jogo ao trocar de área. Para o
-- jogador remoto ela nem deveria agir (decide quando despawnar por distância): os métodos
-- de update do GenerateInfo do jogador 2 são pulados.
st.n_geninfo_skips = 0
do
    local td = sdk.find_type_definition("app.GenerateInfo")
    for _, m in ipairs(td and td:get_methods() or {}) do
        local mn = m:get_name()
        if (mn == "update" or mn == "lateUpdate") and m:get_num_params() == 0 and not m:is_static() then
            sdk.hook(m, function(args)
                if st.geninfo_addr and sdk.to_int64(args[2]) == st.geninfo_addr then
                    st.n_geninfo_skips = st.n_geninfo_skips + 1
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(r) return r end)
        end
    end
end

-- espelho por input -----------------------------------------------------------------------

-- campos de app.UserInput copiados do player para o jogador 2
local INPUT_FIELDS = {
    "ButtonOnFlags", "OldButtonOnFlags", "ButtonReleaseFlags", "ButtonTriggerFlags", "ButtonRepeatFlags",
    "ButtonOnFlagsForUI", "PadButtonDown", "PadButtonUp", "PadButton", "PadButtonRepeat",
    "_AxisL", "<AxisR>k__BackingField", "<AxisMagnitudeL>k__BackingField", "<AxisMagnitudeR>k__BackingField",
    "<AnalogL>k__BackingField", "<AnalogR>k__BackingField",
    "KeyboardMouseAxisL", "KeyboardMouseAxisR", "KeyboardMouseAnalogL", "KeyboardMouseAnalogR",
    "<IsMouseMovedInFrame>k__BackingField", "<IsPadAxisRMovedInFrame>k__BackingField",
}

local function input_addr(ch)
    local ok, a = pcall(function() return ch:call("get_Input"):get_address() end)
    return ok and a or 0
end

do
    local td = sdk.find_type_definition("app.UserInput")
    local m = td and td:get_method("update(System.Boolean, System.Boolean)")
    if m then
        sdk.hook(m, function(args)
            if not cfg.mirror or st.state ~= "pronto" or st.clone == nil then return end
            local this = sdk.to_int64(args[2])
            if this ~= input_addr(st.clone) then return end
            -- jogador 2: no lugar de ler o controle, recebe o estado gravado do player
            local snap = st.snaps[st.frame - cfg.delay]
            if snap then
                local inp = sdk.to_managed_object(args[2])
                for k, v in pairs(snap) do pcall(function() inp:set_field(k, v) end) end
                st.n_applied = st.n_applied + 1
            end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, function(r) return r end)
    else
        log.error("[dd2coop] jogador 2: UserInput.update nao achado")
    end
end

-- grava o estado do controle do player depois do update do input dele (frame atual)
local function record()
    local inp = st.orig:call("get_Input")
    local snap = {}
    for _, k in ipairs(INPUT_FIELDS) do
        local ok, v = pcall(function() return inp:get_field(k) end)
        if ok and v ~= nil then snap[k] = v end
    end
    st.snaps[st.frame] = snap
    st.snaps[st.frame - cfg.delay - 60] = nil
end

-- fonte do input do jogador 2 ---------------------------------------------------------------
-- 1 parado (input desligado); 2 espelho local (este script, com atraso); 3 rede: eco (o
-- plugin dd2coop_net captura o input do player, manda pela Steam em loopback e aplica no
-- jogador 2); 4 rede: amigo (P2P) — o mesmo, mas trocando com o SteamID64 do amigo, e o
-- jogador 2 representa o amigo: vai para a posição que ele manda.
-- A ponte com o plugin é reframework\data\dd2coop_net_cfg.json (escrito aqui: modo,
-- endereços dos inputs, SteamID do amigo e a pose do player, a cada ~0,5 s) e
-- dd2coop_net_status.json (escrito pelo plugin: contadores, SteamID local, pose recebida).
SOURCES = { "parado", "espelho local (Lua)", "rede: eco (plugin)", "rede: amigo (P2P)" }
local NET_MODE = { [3] = "eco", [4] = "p2p" }

-- pose do player: posição universal (precisão dupla) + yaw do corpo
local function my_pose()
    local xf = st.orig:call("get_GameObject"):call("get_Transform")
    local up = xf:call("get_UniversalPosition")
    local q = xf:call("get_Rotation")
    local yaw = math.atan(2 * (q.x * q.z + q.w * q.y), 1 - 2 * (q.x * q.x + q.y * q.y))
    return up.x, up.y, up.z, yaw
end

write_net_cfg = function(mode)
    local X = _G.dd2coop_extra
    local c = { mode = mode, save_lock = locked(), instance = st.instance,
        force_lock = X ~= nil and #X.slots > 0,
        lua_epoch = st.net_status and math.floor(tonumber(st.net_status.lua_epoch) or -1) }
    if mode ~= "off" and st.orig and st.clone then
        c.orig = st.orig:call("get_Input"):get_address()
        c.clone = st.clone:call("get_Input"):get_address()
        c.jitter = cfg.jitter
        c.peer = cfg.peer
        c.snap = cfg.snap_dist
        c.smooth_correction = cfg.smooth_correction
        c.echo_correction = cfg.echo_correction
        pcall(function()
            c.orig_xf = st.orig:call("get_GameObject"):call("get_Transform"):get_address()
            c.clone_xf = st.clone:call("get_GameObject"):call("get_Transform"):get_address()
            c.clone_ch = st.clone:get_address() -- o plugin reposiciona por app.Character.warp
        end)
        local ok, x, y, z, yaw = pcall(my_pose)
        if ok then c.px, c.py, c.pz, c.pyaw = x, y, z, yaw end
        -- N jogadores: slot 0 = jogador 2 (este puppet); os demais da sessão vêm do
        -- dd2coop_extra (com cópia ou ainda sem: o input deste PC vai para todos)
        c.peer_count, c.peer0, c.clone0, c.clone_xf0, c.clone_ch0 = 1, c.peer, c.clone, c.clone_xf, c.clone_ch
        local X = _G.dd2coop_extra
        if mode == "p2p" and X then
            for _, e in ipairs(X.net_peers(c.peer)) do
                local i = c.peer_count
                if i >= 3 then break end
                c["peer" .. i], c["clone" .. i], c["clone_xf" .. i], c["clone_ch" .. i] = e.peer, e.clone, e.clone_xf, e.clone_ch
                c.peer_count = i + 1
            end
        end
    end
    pcall(json.dump_file, "dd2coop_net_cfg.json", c)
end

set_source = function(idx)
    if idx ~= 1 then
        if st.state ~= "pronto" or st.hidden then st.info = "mostre e recupere o jogador 2 antes de conectar"; return false end
        if (_G.dd2coop_profiles and _G.dd2coop_profiles.pending) or
            (_G.dd2coop_loadout and _G.dd2coop_loadout.pending) then
            st.info = "aguarde a verificacao da troca visual antes de conectar"; return false
        end
        if idx == 4 and (not cfg.peer:match("^%d+$") or #cfg.peer ~= 17 or
            (st.net_status and cfg.peer == st.net_status.me)) then
            st.info = "informe o SteamID64 do amigo, diferente do seu"; return false
        end
        local found = scan_arisen()
        local original_live, clone_live = false, false
        for _, ch in ipairs(found or {}) do
            original_live = original_live or key(ch) == key(st.orig)
            clone_live = clone_live or key(ch) == key(st.clone)
        end
        if not original_live or not clone_live then
            st.state = "recuperacao"; st.info = "personagens mudaram; sessao interrompida"
            write_net_cfg("off"); return false
        end
        if (idx == 2 or idx == 3) and _G.dd2coop_profiles then
            local ok, comparison = pcall(_G.dd2coop_profiles.compare_characters, st.orig, st.clone)
            if ok then st.compatibility = comparison end
        end
    end
    st.source_idx = idx
    cfg.mirror = idx == 2
    st.snaps = {}
    st.placed = false
    local active = idx ~= 1
    pcall(function() st.clone:call("get_InputProcessor"):call("set_IsEnable", active) end)
    write_net_cfg(NET_MODE[idx] or "off")
    save_settings()
    return true
end
st.set_source = set_source

-- A portable profile for later remote setup. Only read visual metadata and
-- vocation here; inventory and shared CharacterID data are never written.
st.export_profile = function()
    if _G.dd2coop_profiles then return _G.dd2coop_profiles.export_original() end
    if st.state ~= "pronto" and st.state ~= "nenhum" then return false end
    local found, manual = scan_arisen()
    local original = st.state == "pronto" and st.orig or manual
    local live = false
    for _, ch in ipairs(found or {}) do live = live or key(ch) == key(original) end
    if not live then return false end
    local profile = { version = 1, game = "DD2", styles = {} }
    local ok, err = pcall(function()
        local swapper = original:call("get_HumanPartSwapper")
        local meta = swapper:get_field("_Meta")
        profile.species, profile.gender = meta:get_field("_Species"), meta:get_field("_Gender")
        profile.vocation = original:call("get_HumanActionSelector"):call("get_SelectorFor")
        for _, f in ipairs(meta:get_type_definition():get_fields()) do
            if not f:is_static() then
                local value = meta:get_field(f:get_name())
                if type(value) == "number" or type(value) == "boolean" or type(value) == "string" then
                    profile.styles[f:get_name()] = value
                end
            end
        end
        local result = json.dump_file("dd2coop_profile.json", profile)
        if result == false then error("nao foi possivel gravar o perfil") end
    end)
    st.info = ok and "aparencia e vocacao exportadas em dd2coop_profile.json" or "falha ao exportar perfil: " .. tostring(err)
    return ok
end

write_net_cfg("off")
st.net_off = function() return set_source(1) end

-- Esconder no lugar de remover: destruir o jogador 2 derruba o jogo, porque estruturas
-- do player (status, buffs) indexadas pelo mesmo CharacterID ficam apontando para ele
-- (HumanSpecialBuffManager.HotSpringBuff.getParam). Escondido, ele fica parado e invisível
-- até o jogo fechar; o save continua barrado enquanto ele existir.
-- Destruir de verdade foi testado em 2026-10-16 e cai em cadeia nos buffs especiais
-- (HotSpring, OfflineItem, Job05Guts, Job01Ascertain...) de um gerenciador reiniciado pelo
-- pool. Congelar o GameObject (UpdateSelf=false) tambem foi testado: ao voltar, a logica
-- anda mas o modelo fica preso no lugar. Por isso so esconde (DrawSelf) e para o input.
-- Mostrar de novo traz a copia 3 m a frente do original.
st.toggle_hidden = function()
    st.hidden = not st.hidden
    st.drawn = nil -- visibilidade automatica reavalia no proximo ciclo
    if st.hidden then set_source(1) end
    pcall(function()
        local go = st.clone:call("get_GameObject")
        local xf = go:call("get_Transform")
        if st.hidden then
            go:call("set_DrawSelf", false)
        else
            local oxf = st.orig:call("get_GameObject"):call("get_Transform")
            local rot = oxf:call("get_Rotation")
            local fwd = rot * Vector3f.new(0, 0, 1)
            local up = oxf:call("get_UniversalPosition")
            up.x, up.z = up.x + fwd.x * 3.0, up.z + fwd.z * 3.0
            xf:call("set_UniversalPosition", up)
            go:call("set_UpdateSelf", true)
            go:call("set_DrawSelf", true)
        end
    end)
    remember()
end

-- a cada ~0,5 s: pose do player para o plugin e status do plugin para cá
re.on_pre_application_entry("LateUpdateBehavior", function()
    if st.frame % 30 ~= 0 then return end
    local mode = NET_MODE[st.source_idx or 1]
    write_net_cfg(st.state == "pronto" and mode or "off")
    local ok, s = pcall(json.load_file, "dd2coop_net_status.json")
    if ok and s then
        st.net_status = s
        -- (a correção de posição agora é do plugin, sincronizada com o input do mesmo pacote)
    end
    -- jogador 2 so aparece conectado: chegando dados (rede) ou no espelho local; sem
    -- conexao ou apos o timeout de 500 ms do plugin, fica invisivel. "Esconder" manda acima.
    if st.state == "pronto" and st.clone then
        local live = st.source_idx == 2 or (mode ~= nil and st.net_status ~= nil and
            (st.net_status.input_state == "active" or st.net_status.input_state == "buffering"))
        local parked = _G.dd2coop_park and _G.dd2coop_park.is_parked("p2") -- longe: dd2coop_park esconde
        local visible = live and not st.hidden and not st.remote_dead and not parked -- amigo morto: escondido
        if visible ~= st.drawn then
            st.drawn = visible
            pcall(function() st.clone:call("get_GameObject"):call("set_DrawSelf", visible) end)
            log.info("[dd2coop] jogador 2 " .. (visible and "conectado: visivel" or "sem conexao: invisivel"))
        end
    end
end)

-- painel da rede (chamado de dentro do painel do jogador 2)
st.draw_net_panel = function()
    local s = st.net_status
    imgui.text("seu SteamID64: " .. tostring(s and s.me or "?") .. "  (passe este numero ao amigo)")
    if st.source_idx == 4 or (st.source_idx or 1) == 1 then
        local cp, peer = imgui.input_text("SteamID64 do amigo", cfg.peer)
        if cp then
            if st.source_idx == 4 then set_source(1) end
            cfg.peer = peer:sub(1, 32):gsub("%s", ""); save_settings()
        end
        if st.state == "pronto" and st.source_idx == 1 and not st.hidden then
            if imgui.button("Conectar ao amigo") then set_source(4) end
        end
    end
    if st.source_idx ~= 1 and imgui.button("Desconectar / parar jogador 2") then set_source(1) end
    if NET_MODE[st.source_idx or 1] then
        local cj, j = imgui.slider_int("Buffer da rede (frames)", cfg.jitter, 1, 60)
        if cj then cfg.jitter = j; save_settings() end
        if s and s.input_state then
            local labels = { waiting = "aguardando dados", buffering = "preparando buffer",
                active = "recebendo dados", timeout = "sem dados; controle neutralizado" }
            imgui.text("Conexao: " .. (labels[s.input_state] or s.input_state))
        end
        if s then
            imgui.text(string.format("rede (%s): enviados=%s recebidos=%s aplicados=%s repetidos=%s ruins=%s buffer=%s",
                tostring(s.mode), tostring(s.sent), tostring(s.received), tostring(s.applied),
                tostring(s.held), tostring(s.bad), tostring(s.buffered)))
            if st.source_idx == 3 then
                local changed, value = imgui.checkbox("Eco com correcao de posicao (teste)", cfg.echo_correction)
                if changed then cfg.echo_correction = value; save_settings() end
            end
            if st.source_idx == 4 or (st.source_idx == 3 and cfg.echo_correction) then
                imgui.text(string.format("pose do amigo: %s  deriva=%.2f m  reposicionamentos=%s",
                    s.remote_valid and "recebida" or "ainda nao", tonumber(s.drift) or -1, tostring(s.snaps)))
                local changed, value = imgui.checkbox("Correcao suave pelo movimento", cfg.smooth_correction)
                if changed then cfg.smooth_correction = value; save_settings() end
                if not cfg.smooth_correction then
                    local cs, sd = imgui.slider_float("Reposicionar acima de (m)", cfg.snap_dist, 0.3, 6)
                    if cs then cfg.snap_dist = sd; save_settings() end
                end
            end
            if s.error and s.error ~= "" then imgui.text("erro: " .. s.error) end
        else
            imgui.text("rede: sem status do plugin")
        end
    end
end

-- por frame ------------------------------------------------------------------------------

re.on_pre_application_entry("UpdateBehavior", function()
    st.frame = st.frame + 1
    local audit_interval = (st.state == "pronto" or st.state == "nenhum") and 60 or 10
    if st.frame == 1 or st.frame % audit_interval == 0 then
        local ok, err = pcall(recover)
        if not ok then
            st.state, cfg.mirror, st.source_idx = "recuperacao", false, 1
            write_net_cfg("off")
            st.info = "falha ao conferir personagens: " .. tostring(err)
        end
    end
    if st.state == "pronto" and os.time() < st.guard_until and st.frame % 10 == 0 then
        pcall(settle)
    end
end)

re.on_script_reset(function()
    -- No destruction: keep identity on disk, stop network and local input.
    cfg.mirror, st.source_idx = false, 1
    pcall(remember)
    write_net_cfg("off")
    if st.state == "pronto" then
        pcall(function() st.clone:call("get_InputProcessor"):call("set_IsEnable", false) end)
    end
    save_settings()
end)


-- diagnóstico do "pisca": a cada 5 frames, se o jogador 2 está visível para o jogo
-- (GameObject.Draw e a malha principal ligada). Conta as vezes que ficou invisível sem
-- ser escondido por nós, para separar de reposicionamento (contador do plugin).
st.n_invisible, st.vis_prev = 0, true
re.on_pre_application_entry("LateUpdateBehavior", function()
    if st.state ~= "pronto" or st.hidden or st.clone == nil or st.frame % 5 ~= 0 then return end
    local ok, vis = pcall(function()
        local go = st.clone:call("get_GameObject")
        if not go:call("get_Draw") then return false end
        for _, c in ipairs(go:call("get_Components"):get_elements()) do
            if c:get_type_definition():get_full_name() == "via.render.Mesh" then return c:call("get_Enabled") end
        end
        return true
    end)
    if ok then
        if st.vis_prev and not vis then
            st.n_invisible = st.n_invisible + 1
            log.info("[dd2coop] jogador 2 ficou invisivel (vez " .. st.n_invisible .. ")")
        end
        st.vis_prev = vis
    end
end)
re.on_pre_application_entry("LateUpdateBehavior", function()
    if st.state == "pronto" and cfg.mirror then pcall(record) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: jogador 2") then return end
    imgui.text("estado: " .. st.state)
    if st.state == "nenhum" or st.state == "pronto" then
        if imgui.button("Exportar aparencia e vocacao do original") then st.export_profile() end
    end
    if st.state == "nenhum" then
        if imgui.button("Criar jogador 2") then
            local ok, err = pcall(spawn)
            if not ok then st.info = "erro: " .. tostring(err) end
        end
        st.draw_net_panel()
    elseif st.state == "pronto" then
        local changed, src = imgui.combo("Fonte do input do jogador 2", st.source_idx or 1, SOURCES)
        if changed then set_source(src) end
        if st.source_idx == 2 then
            local changed_delay, d = imgui.slider_int("Atraso (frames)", cfg.delay, 1, 120)
            if changed_delay then cfg.delay = d; save_settings() end
        end
        st.draw_net_panel()
        if imgui.button("Devolver camera e controle ao original") then pcall(settle) end
        imgui.text("vezes que o jogador 2 ficou invisivel: " .. tostring(st.n_invisible or 0))
        local hl = st.hidden and "Mostrar jogador 2" or "Esconder jogador 2"
        if imgui.button(hl) then st.toggle_hidden() end
    elseif st.state == "recuperacao" and #st.candidates == 2 then
        local labels = {}
        for _, candidate in ipairs(st.candidates) do labels[#labels + 1] = candidate.label end
        local _, selected = imgui.combo("Qual e o personagem original?", st.recover_idx or 1, labels)
        st.recover_idx = selected
        if imgui.button("Confirmar original e recuperar copia") then
            st.confirm_original(st.candidates[selected].address)
        end
    end
    imgui.text(locked() and "Save protegido: bloqueado enquanto existir copia ou recuperacao pendente"
        or "Save liberado: nenhum jogador 2 detectado")
    imgui.text(string.format("saves barrados=%d  quadros de input aplicados=%d  geracao pulada=%d", st.n_saves_blocked, st.n_applied, st.n_geninfo_skips))
    if st.info ~= "" then imgui.text(st.info) end
    imgui.tree_pop()
end)
