-- DD2 Co-op: cópias com CharacterID próprio (inventário, equipamento e status separados do jogador).
-- Cada jogador remoto usa o ID de um NPC humano com presets de aparência e roupa, sem quest
-- conhecida, com o prefab do Arisen (validado em 2026-10-18, protótipo do Codex em
-- dev/dd2dev_characterid_trial.lua: nasce, fica de pé, menu abre, inventário próprio e o do jogador
-- não muda na criação):
--   jogador 2: ch300000 Silas (260732951), Vernworth;
--   jogador 3: ch300005 Xavier (3713252879), local desconhecido;
--   jogador 4: ch300007 Rikhard (4099837137), local desconhecido (9 relações de afeto com NPCs).
-- Evitados: ch300001 Jacint, ch300002 Alsa e ch300004 Timothy são falas obrigatórias da quest
-- "Prey for the Pack".
-- Três coisas que o jogo não faz sozinho para um ID que não é o do Arisen:
--   1. Catálogo: o GenerateCatalogController só conhece o Arisen no catálogo de jogador. O ID novo
--      é registrado apontando para o MESMO PrefabController já carregado do Arisen
--      (_PlayerCatalog:register). registerPlayerCatalog(ID, via.Prefab) cria outro controller e
--      clona o prefab: deu prefab inválido e crashes de GC. Nunca desregistrar (crashou em GC).
--   2. Classificação: HumanEnemyController.onCharacterBeginInitialize(CharacterID) volta logo para
--      o ID do Arisen, mas classifica os outros como NPC/inimigo/pawn e inicializa uma IA que o
--      prefab do Arisen não tem (crash). Só na criação pedida aqui, o argumento vira o ID do
--      Arisen (uma vez); o CharacterID do objeto nunca muda.
--   3. Vida: o PlayerStatusCalculator do ID novo nasce sem contexto (Human nil, 0 HP). Depois da
--      adoção, setContexts(contexto da cópia) liga ele; antes da adoção ele continua em 0.
local M = { ids = { 260732951, 3713252879, 4099837137 }, message = "", refs = {}, entries = {} }
M.id = M.ids[1]
_G.dd2coop_replica_id = M

local ARISEN = 2891076981
local frame = 0
local pending_classify = {} -- [id] = classificações a reescrever (uma por criação pedida)
local pending_selector = {} -- [id] = montagens de seletores a fazer como Arisen

for _, id in ipairs(M.ids) do M.entries[id] = { stage = "nenhum", ready = false } end

-- ID do jogador remoto n (1 = jogador 2, 2 = jogador 3, 3 = jogador 4)
function M.id_for(n) return M.ids[math.min(math.max(n or 1, 1), #M.ids)] end
function M.is_replica(id) return id ~= nil and M.entries[id] ~= nil end

local function pin(o)
    if o and o.add_ref_permanent then o:add_ref_permanent() elseif o then o:add_ref() end
    M.refs[#M.refs + 1] = o
    return o
end

-- Generation IDs are managed objects too; keep each alive before allocating the next.
function M.retain_generation_id(value) return pin(value) end

-- A pooled HumanInfo became invalid during the third replica initialization. Give each
-- request its own native copy and retain the generation graph for the replica lifetime.
-- MemberwiseClone is shallow: retain Meta as well. Only the native setter writes references.
function M.prepare_container(container)
    local ok, err = pcall(function()
        assert(container, "missing generation container")
        pin(container)
        local common = pin(assert(container:get_field("_CommonInfo"), "missing CommonInfo"))
        local request = pin(assert(common:get_field("_RequestID"), "missing RequestID"))
        pin(assert(request:get_field("_GenID"), "missing GeneratorID"))
        pin(assert(request:get_field("_UniqID"), "missing UniqueID"))
        local source = pin(assert(container:call("get_HumanInfo"), "missing HumanInfo"))
        assert(source:get_type_definition():get_full_name() == "app.GenerateInfo.HumanInfoData",
            "unexpected source HumanInfo type")
        local method = assert(sdk.find_type_definition("System.Object"):get_method("MemberwiseClone"),
            "missing native MemberwiseClone")
        local human = pin(assert(method:call(source), "HumanInfo clone returned nil"))
        assert(human:get_type_definition():get_full_name() == "app.GenerateInfo.HumanInfoData",
            "unexpected HumanInfo clone type")
        assert(human:get_address() ~= source:get_address(), "HumanInfo was not copied")
        container:call("set_HumanInfo(app.GenerateInfo.HumanInfoData)", human)
        local installed = container:call("get_HumanInfo")
        assert(installed and installed:get_address() == human:get_address(), "HumanInfo setter failed")
        pin(human:call("get_Meta"))
        local status = pin(container:get_field("_StatusInfo"))
        if status then
            pin(status:get_field("<BreakRegionID>k__BackingField"))
            pin(status:get_field("<IgnoreRegionID>k__BackingField"))
        end
    end)
    if not ok then M.message = "generation preparation failed: " .. tostring(err) end
    return ok, err
end

-- prepara um ID nesta execução do jogo (uma vez): inventário próprio e entrada no catálogo
local function prepare_step(id, e)
    if e.stage == "nenhum" then
        local GM = sdk.get_managed_singleton("app.GenerateManager")
        local items = sdk.get_managed_singleton("app.ItemManager")
        if not GM or not items then return end
        local catalog = GM:get_field("_CatalogCtrl")
        local player_catalog = catalog and catalog:get_field("_PlayerCatalog")
        local dict = player_catalog and player_catalog:call("get_MergedCatalog")
        if not dict or not dict:call("ContainsKey", ARISEN) then return end
        if not items:get_field("StorageDict"):call("ContainsKey", id) then
            items:call("initStorage(app.CharacterID, System.Boolean)", id, false)
        end
        if not dict:call("ContainsKey", id) then
            local source = pin(dict:call("get_Item", ARISEN))
            local controller = pin(source:call("get_Item"))
            pin(controller:call("get_Item"))
            pin(catalog)
            player_catalog:call("register", id, controller)
            local alias = pin(dict:call("get_Item", id))
            local alias_controller = pin(alias:call("get_Item"))
            if alias_controller:get_address() ~= controller:get_address() then
                e.stage = "falhou"
                M.message = "o catálogo clonou o controller do ID " .. id .. "; esse ID foi desligado"
                log.info("[dd2coop_replica_id] " .. M.message)
                return
            end
            -- referência do recurso no próprio controller (diferente do pin do Lua); nunca solta
            alias_controller:call("addRef")
            e.controller = alias_controller
        else
            e.controller = pin(dict:call("get_Item", id):call("get_Item"))
        end
        e.stage, e.since = "aguardando_prefab", frame
    elseif e.stage == "aguardando_prefab" then
        e.controller:call("update")
        if not e.controller:call("get_Ready") then
            if frame - e.since > 1800 then
                e.stage, M.message = "falhou", "prefab do ID " .. id .. " nunca ficou pronto"
            end
            return
        end
        if frame - e.since < 120 then return end
        e.stage, e.ready = "pronto", true
        log.info("[dd2coop_replica_id] ID " .. id .. " preparado (inventário próprio e catálogo)")
    end
end

-- chamado antes de pedir a criação: true quando o ID já pode ser usado
function M.ensure(id)
    local e = M.entries[id or M.id]
    if not e then return false end
    if e.ready then return true end
    e.wanted = e.stage ~= "falhou"
    return false
end

function M.failed(id)
    local e = M.entries[id or M.id]
    return not e or e.stage == "falhou"
end

-- a próxima classificação e montagem de seletores deste ID seguem o caminho do Arisen (uma vez)
function M.arm_classification(id)
    id = id or M.id
    pending_classify[id] = 1
    pending_selector[id] = 1
end

do
    local td = sdk.find_type_definition("app.HumanEnemyController")
    local m = td and td:get_method("onCharacterBeginInitialize(app.CharacterID)")
    if m then
        sdk.hook(m, function(args)
            local id = sdk.to_int64(args[3]) & 0xffffffff
            if (pending_classify[id] or 0) <= 0 then return end
            args[3] = sdk.to_ptr(ARISEN)
            pending_classify[id] = pending_classify[id] - 1
            M.classified = (M.classified or 0) + 1
        end, function(ret) return ret end)
    else
        for _, e in pairs(M.entries) do e.stage = "falhou" end
        M.message = "onCharacterBeginInitialize não encontrado; ID próprio desligado"
    end
end

-- Seletores de ação: HumanActionSelector.setupSelectors lê o ID direto do campo do personagem
-- ([Character+0xc4c]) e só monta os seletores de jogador e de vocação para o ID do Arisen
-- (0xac525575); com o ID próprio a cópia andava mas não atacava (SelectorFor=0). Chamar
-- setupSelectors de novo com ela viva crashou em updateCurrentSelector (2026-10-18). Só durante
-- essa chamada, na criação pedida aqui, o campo vale o ID do Arisen; volta no pós-hook.
local CHARA_ID_OFFSET = 0xc4c
do
    local td = sdk.find_type_definition("app.HumanActionSelector")
    local m = td and td:get_method("setupSelectors(app.Character)")
    if m then
        sdk.hook(m, function(args)
            local s = thread.get_hook_storage()
            s.dd2coop_sel = nil
            local ch = sdk.to_managed_object(args[3])
            if not ch then return end
            local id = ch:read_dword(CHARA_ID_OFFSET)
            if (pending_selector[id] or 0) <= 0 or ch:call("get_CharaID") ~= id then return end
            pending_selector[id] = pending_selector[id] - 1
            ch:write_dword(CHARA_ID_OFFSET, ARISEN)
            s.dd2coop_sel, s.dd2coop_sel_id = ch, id
            M.selectors = (M.selectors or 0) + 1
        end, function(ret)
            local s = thread.get_hook_storage()
            local ch = s.dd2coop_sel
            s.dd2coop_sel = nil
            if ch then ch:write_dword(CHARA_ID_OFFSET, s.dd2coop_sel_id) end
            return ret
        end)
    else
        for _, e in pairs(M.entries) do e.stage = "falhou" end
        M.message = "setupSelectors não encontrado; ID próprio desligado"
    end
end

-- NPC verdadeiro: o NPC dono do ID (Silas, Xavier, Rikhard) não pode nascer enquanto uma cópia
-- usa o ID dele (Unique=1; o jogo podia confundir os dois). Matar o NPC iria para o save; aqui só
-- as consultas de geração do NPCManager respondem "não" para IDs em uso, até fechar o jogo (as
-- cópias nunca são destruídas). Nada é gravado: fora do co-op o NPC volta à rotina.
-- Não validado: confirmar perto da casa do Silas (Vernworth) que ele não nasce.
M.in_use = {}
M.npc_blocked = 0
do
    local td = sdk.find_type_definition("app.NPCManager")
    for _, sig in ipairs({ "canNPCGenerateCondition(app.CharacterID)",
            "canNPCGenerateCondition_SpecialLayer(app.CharacterID)" }) do
        local m = td and td:get_method(sig)
        if m then
            sdk.hook(m, function(args)
                local s = thread.get_hook_storage()
                s.dd2coop_npc = M.in_use[sdk.to_int64(args[3]) & 0xffffffff] == true
            end, function(ret)
                local s = thread.get_hook_storage()
                if s.dd2coop_npc then
                    s.dd2coop_npc = nil
                    M.npc_blocked = M.npc_blocked + 1
                    return sdk.to_ptr(0)
                end
                return ret
            end)
        end
    end
end

-- depois da adoção: calculador do ID ligado ao contexto da cópia e vida cheia. Cópias que dividem
-- um ID dividem o calculador dele: cada uma, na ordem de adoção, recebe a vida calculada.
local queue = {}
local binding = nil
function M.bind(clone)
    local id = clone:call("get_CharaID")
    M.in_use[id] = true -- a partir daqui o NPC dono do ID não nasce (ver acima)
    queue[#queue + 1] = { clone = clone, id = id }
end

local function bind_step()
    if not binding then
        binding = table.remove(queue, 1)
        if not binding then return end
        binding.started = frame
    end
    local b = binding
    if frame % 30 ~= 0 then return end
    if frame - b.started > 1800 then
        binding = nil
        M.message = "calculador da cópia continuou em 0 HP"
        log.info("[dd2coop_replica_id] " .. M.message)
        return
    end
    local CM = sdk.get_managed_singleton("app.CharacterManager")
    local calculators = CM:get_field("<PlayerStatusCalculatorHolder>k__BackingField"):get_field("Calculators")
    local own = calculators:call("get_Item", b.id)
    if not own then return end
    local arisen = calculators:call("get_Item", ARISEN)
    if arisen and arisen:get_address() == own:get_address() then
        binding = nil
        M.message = "calculador da cópia é o do jogador; não ligado"
        return
    end
    -- método do jogo; nunca gravar calc.Human com set_field
    own:call("setContexts(app.ContextHolder)", b.clone:call("get_Context"))
    local mx = own:call("calcMaxHPWithEquipmentAndBuff()")
    if not mx or mx <= 0 then return end
    local hit = b.clone:call("get_Hit")
    -- true no terceiro argumento: preenche a vida da região (false só limita a anterior, 0)
    hit:call("setRegionOriginalMaxHp(System.Single, System.Int32, System.Boolean)", mx, 0, true)
    hit:call("setReducedMaxHpValue", mx)
    hit:call("setHp(System.Single, System.Boolean, System.Int32)", mx, false, 0)
    binding = nil
    M.entries[b.id].bound_hp = mx
    log.info(string.format("[dd2coop_replica_id] calculador da cópia (ID %d) ligado: %.0f HP", b.id, mx))
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    frame = frame + 1
    local ok, err = pcall(function()
        if frame % 10 == 0 then
            for id, e in pairs(M.entries) do
                if e.wanted and not e.ready and e.stage ~= "falhou" then prepare_step(id, e) end
            end
        end
        if binding or #queue > 0 then bind_step() end
    end)
    if not ok then M.message = "erro: " .. tostring(err) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: ID proprio das copias") then return end
    for n, id in ipairs(M.ids) do
        local e = M.entries[id]
        imgui.text(string.format("jogador %d: ID %d %s%s", n + 1, id, e.stage,
            e.bound_hp and (" | vida " .. e.bound_hp) or ""))
    end
    imgui.text("geracao de NPC dono do ID bloqueada: " .. M.npc_blocked)
    if M.message ~= "" then imgui.text(M.message) end
    imgui.tree_pop()
end)

log.info("[dd2coop_replica_id] IDs proprios das copias carregados")
