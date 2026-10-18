-- DD2 Co-op: isola o inventario do jogador local das acoes da copia.
-- Os dois Arisen usam o mesmo CharacterID, e o ItemManager guarda o inventario por
-- CharacterID: sem isto, a copia usando pocao, pegando item, gastando oleo da lanterna ou
-- trocando equipamento mexeria no inventario de quem esta jogando. O jogador remoto aplica
-- os proprios itens no mundo dele; aqui so a animacao (que vem do input) importa.
-- Metodos do app.ItemManager que recebem um app.Character e alteram inventario/equipamento:
-- quando algum desses parametros e a copia, o original e pulado. Modelos e aparencia
-- (setEquipModel, setWeaponModel, requestRight/LeftEquipWeapon, setEquipAppearance,
-- applyEquipDataForCharacter) nao sao bloqueados.
local M = { counts = {}, total = 0, hooks = 0 }
_G.dd2coop_isolation = M

-- valor devolvido quando o original e pulado (nil = metodo void)
local TRUE, ZERO_F = sdk.to_ptr(1), sdk.float_to_ptr(0.0)
local BLOCK = {
    useItem = TRUE, eatItem = TRUE, useItemSub = false, eatItemSub = false, useLantern = false,
    addLanternOil = ZERO_F, subLanternOil = ZERO_F,
    getItem = false, getDropItem = false, deleteItem = false,
    passItem = false, putItem = false, putExpandItem = false,
    setEquip = false, setEquipDataNoLock = false, removeEquip = false, removeEquipNoLock = TRUE,
    setArisenEquipForce = TRUE, setArisenEquipByIndex = TRUE, addArisenEquipNoLock = TRUE,
    removeArisenEquipNoLock = TRUE, removeArisenEquipBeforeSetArisenEquipByIndex = false,
    breakJewelry = false, breakJewelryInternal = TRUE,
}

-- endereços de todas as cópias: jogador 2 (puppet) e jogadores 3 e 4 (dd2coop_extra)
local function clone_addresses()
    local set, any = {}, false
    local s = _G.dd2coop_p2
    local c = s and s.clone
    if c then
        local ok, a = pcall(c.get_address, c)
        if ok and a then set[a] = true; any = true end
    end
    local X = _G.dd2coop_extra
    for _, slot in ipairs(X and X.slots or {}) do
        if slot.addr then set[slot.addr] = true; any = true end
    end
    return any and set or nil
end

local td = sdk.find_type_definition("app.ItemManager")
for _, m in ipairs(td and td:get_methods() or {}) do
    local name = m:get_name()
    local ret = BLOCK[name]
    if ret ~= nil then
        local slots = {}
        for i, p in ipairs(m:get_param_types()) do
            if p:get_full_name() == "app.Character" then slots[#slots + 1] = i + 2 end -- args[1] thread, [2] this
        end
        if #slots > 0 then
            local skipped = false
            sdk.hook(m, function(args)
                skipped = false
                local set = clone_addresses()
                if not set then return end
                for _, i in ipairs(slots) do
                    if set[sdk.to_int64(args[i])] then
                        skipped = true
                        M.counts[name] = (M.counts[name] or 0) + 1
                        M.total = M.total + 1
                        return sdk.PreHookResult.SKIP_ORIGINAL
                    end
                end
            end, function(r)
                if skipped and ret then skipped = false; return ret end
                skipped = false
                return r
            end)
            M.hooks = M.hooks + 1
        end
    end
end

-- Contexto (registro salvo de cada personagem): ao mudar de área o CharacterManager.collectContext
-- chama <collectContext>b__0(i) para cada charaList[i]; a cópia não tem registro próprio e o jogo
-- lia memória inválida (crash saindo da cidade com a cópia para trás, 2026-10-17). Cópia pulada.
do
    local td = sdk.find_type_definition("app.CharacterManager.<>c__DisplayClass334_0")
    local m = td and td:get_method("<collectContext>b__0")
    if m then
        sdk.hook(m, function(args)
            local set = clone_addresses()
            if not set then return end
            local ok, skip = pcall(function()
                local closure = sdk.to_managed_object(args[2])
                local list = closure:get_field("charaList")
                local ch = list:call("get_Item", sdk.to_int64(args[3]) & 0xFFFFFFFF)
                return ch ~= nil and set[ch:get_address()] == true
            end)
            if ok and skip then
                M.counts.collectContext = (M.counts.collectContext or 0) + 1
                M.total = M.total + 1
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end, function(r) return r end)
        M.hooks = M.hooks + 1
    end
end

-- Auto-destruição: o AutoDestroyDistributorUnit da categoria Arisen (GeneratorCategory 0) tenta
-- destruir a cópia longe do jogador e crasha em InstanceInfoController.autoDestroyCharaInstance
-- (voltando à cidade onde a cópia ficou, 2026-10-17). Com cópia viva, essa unidade não roda; o
-- Arisen de verdade nunca é auto-destruído.
do
    local td = sdk.find_type_definition("app.AutoDestroyDistributorUnit")
    local m = td and td:get_method("update")
    if m then
        sdk.hook(m, function(args)
            if not clone_addresses() then return end
            local ok, cat = pcall(function() return sdk.to_managed_object(args[2]):call("get_Category") end)
            if ok and cat == 0 then
                M.counts.autoDestroy = (M.counts.autoDestroy or 0) + 1
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end, function(r) return r end)
        M.hooks = M.hooks + 1
    end
end

-- Calculador de status do Arisen: a cópia nascendo chama PlayerStatusCalculator.setup/setContexts
-- e o calculador passa a ler o Human e os contextos dela (inventário com limite 35 e vida 500 do
-- nível 1). Trocar o campo Human depois à mão (set_field) bagunçava a contagem de referências e
-- crashava na criação e no menu (DD2.exe+0x524feb4/+0x52345ae, 2026-10-17). Aqui as chamadas são
-- puladas enquanto uma cópia está sendo criada ou o controle está nela; o jogo cuida das refs.
do
    local td = sdk.find_type_definition("app.PlayerStatusCalculator")
    for _, m in ipairs(td and td:get_methods() or {}) do
        local name = m:get_name()
        if name == "setup" or name == "setContexts" then
            sdk.hook(m, function(args)
                local P, X = _G.dd2coop_p2, _G.dd2coop_extra
                local creating = (P and P.state == "gerando") or (X and X.busy)
                if not creating then
                    local set = clone_addresses()
                    if set then
                        local ok, man = pcall(function()
                            return sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
                        end)
                        creating = ok and man ~= nil and set[man:get_address()] == true
                    end
                end
                if creating then
                    M.counts.calcSkip = (M.counts.calcSkip or 0) + 1
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(r) return r end)
            M.hooks = M.hooks + 1
        end
    end
end

-- Peso: com a cópia no mundo o ItemManager.getWeightLimit do Arisen (por Character ou por
-- CharacterID) passa a ler o status da cópia (nível 1: limite 35 em vez de 61,65) e o jogador
-- fica sobrecarregado (2026-10-17). Enquanto houver cópia, devolve o limite do jogador guardado
-- de quando não havia cópia.
do
    local ARISEN_ID = 2891076981
    local td = sdk.find_type_definition("app.ItemManager")
    local limit_by_char = td and td:get_method("getWeightLimit(app.Character)")
    local frame = 0
    re.on_pre_application_entry("LateUpdateBehavior", function()
        frame = frame + 1
        if frame % 60 ~= 0 or clone_addresses() then return end
        pcall(function()
            local me = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
            local im = sdk.get_managed_singleton("app.ItemManager")
            if me and im then M.weight_limit = limit_by_char:call(im, me) end
        end)
    end)
    for _, sig in ipairs({ "getWeightLimit(app.Character)", "getWeightLimit(app.CharacterID)" }) do
        local m = td and td:get_method(sig)
        if m then
            local by_id = sig:find("CharacterID") ~= nil
            local replaced = false
            sdk.hook(m, function(args)
                replaced = false
                if not M.weight_limit or not clone_addresses() then return end
                local ok, arisen = pcall(function()
                    if by_id then return (sdk.to_int64(args[3]) & 0xFFFFFFFF) == ARISEN_ID end
                    local ch = sdk.to_managed_object(args[3])
                    return ch ~= nil and ch:call("get_CharaID") == ARISEN_ID
                end)
                if ok and arisen then
                    replaced = true
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(r)
                if replaced then
                    replaced = false
                    M.counts.weightLimit = (M.counts.weightLimit or 0) + 1
                    return sdk.float_to_ptr(M.weight_limit)
                end
                return r
            end)
            M.hooks = M.hooks + 1
        end
    end
end

-- Vida e carga: criar a cópia (mesmo CharacterID) recalcula o jogador com o status dela (nível 1):
-- HitController.OriginalMaxHp foi de 1782 para 500 (cortando a vida e a barra cinza) e
-- ItemManager.PlayerWeightRank ficou em 4 (sobrecarregado) (2026-10-17). Sem cópia, guarda vida,
-- barra cinza e vida máxima; com cópia, a cada 30 quadros volta a vida máxima calculada do
-- próprio status do jogador, recalcula a carga e, logo depois da cópia aparecer, devolve vida e
-- barra cinza guardadas.
do
    local SET_MAX = "setRegionOriginalMaxHp(System.Single, System.Int32, System.Boolean)"
    local SET_HP = "setHp(System.Single, System.Boolean, System.Int32)"
    local frame, saved, restore_at = 0, nil, nil
    local ARISEN_ID = 2891076981
    local PLAYER_T = sdk.find_type_definition("app.Player"):get_runtime_type()
    local function calculator()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local holder = cm:get_field("<PlayerStatusCalculatorHolder>k__BackingField")
        return holder and holder:get_field("Calculators"):call("get_Item", ARISEN_ID)
    end
    -- A cópia nova toma o ManualPlayer e o jogo aponta para ela ManualPlayerHuman,
    -- ManualPlayerPlayer e o PlayerStatusCalculator do Arisen (Human e contextos: inventário com
    -- limite 35 e vida 500 do nível 1). O puppet devolve só o ManualPlayer; aqui volta o resto.
    local function fix_refs(me)
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local hu = me:call("get_Human")
        if cm:call("get_ManualPlayerHuman") ~= hu then
            cm:call("set_ManualPlayerHuman", hu)
            local pl = me:call("get_GameObject"):call("getComponent(System.Type)", PLAYER_T)
            if pl then cm:call("set_ManualPlayerPlayer", pl) end
            M.counts.manualHuman = (M.counts.manualHuman or 0) + 1
        end
        local calc = calculator()
        if calc and (calc:get_field("Human") ~= hu or
                calc:get_field("Param"):get_field("Status") ~= hu:call("get_StatusContext")) then
            -- setContexts (método do jogo) já aponta calc.Human para o Human do jogador, com as
            -- referências contadas. NUNCA gravar o campo Human com set_field: sem contar a referência,
            -- o próprio setContexts soltava o ponteiro gravado à mão e o jogo crashava na criação e no
            -- menu (DD2.exe+0x524feb4/+0x52345ae: soltura de objeto já liberado, 2026-10-17).
            calc:call("setContexts(app.ContextHolder)", me:call("get_Context"))
            M.counts.calculator = (M.counts.calculator or 0) + 1
        end
        return calc
    end
    M.fix_refs = function(me) return pcall(fix_refs, me) end
    local function my_max(me)
        local calc = fix_refs(me)
        -- só se o calculador for do jogador (com o da cópia daria a vida do nível 1)
        if calc and calc:get_field("Human") == me:call("get_Human") then return calc:call("calcMaxHPWithEquipmentAndBuff()") end
        local hu = me:call("get_Human")
        return hu:call("get_StatusContext"):call("calcMaxHp", hu:call("get_JobContext"):get_field("CurrentJob"))
    end
    re.on_pre_application_entry("LateUpdateBehavior", function()
        frame = frame + 1
        if frame % 30 ~= 0 then return end
        local ok, err = pcall(function()
            local me = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
            if not me then return end
            local set = clone_addresses()
            if set and set[me:get_address()] then return end -- controle ainda na cópia (criando)
            local h = me:call("get_Hit")
            -- cópia sendo criada (ainda sem endereço): a vida já pode ter sido cortada, não guarda
            local P, X = _G.dd2coop_p2, _G.dd2coop_extra
            local creating = (P and P.state ~= "nenhum" and P.state ~= "pronto") or (X and X.busy)
            if not set and creating then return end
            if not set then
                saved = { hp = h:call("get_Hp"), reduced = h:call("get_ReducedMaxHp"), max = h:call("get_OriginalMaxHp") }
                restore_at = nil
                return
            end
            local mx = my_max(me)
            if mx and mx > 0 and math.abs(h:call("get_OriginalMaxHp") - mx) > 0.5 then
                h:call(SET_MAX, mx, 0, false)
                M.counts.maxHp = (M.counts.maxHp or 0) + 1
            end
            restore_at = restore_at or frame + 90
            if saved and frame >= restore_at then
                local R = _G.dd2coop_revive
                local cut = h:call("get_ReducedMaxHp") < saved.reduced - 0.5 or h:call("get_Hp") < saved.hp - 0.5
                if not (R and R.downed) and cut then
                    if h:call("get_ReducedMaxHp") < saved.reduced - 0.5 then h:call("setReducedMaxHpValue", saved.reduced) end
                    h:call(SET_HP, math.min(saved.hp, saved.reduced), false, 0)
                    M.counts.hpRestore = (M.counts.hpRestore or 0) + 1
                end
                saved = nil
            end
        end)
        if not ok then M.message = "erro ao manter status: " .. tostring(err) end
    end)
    -- a atualização periódica do jogo (ItemManager.updatePlayerWeightRank) volta a carga para a
    -- da cópia: depois dela, com cópia viva, a carga é refeita pelo personagem do jogador
    local m = sdk.find_type_definition("app.ItemManager"):get_method("updatePlayerWeightRank")
    if m then
        local this
        sdk.hook(m, function(args) this = args[2] end, function(r)
            if clone_addresses() then
                pcall(function()
                    local im = sdk.to_managed_object(this)
                    local me = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
                    local set = clone_addresses()
                    if not im or not me or set[me:get_address()] then return end
                    local rank = im:call("getWeightRank(app.Character)", me)
                    if im:get_field("PlayerWeightRank") ~= rank then
                        im:set_field("PlayerWeightRank", rank)
                        M.counts.weightRank = (M.counts.weightRank or 0) + 1
                    end
                end)
            end
            return r
        end)
        M.hooks = M.hooks + 1
    end
end

log.info("[dd2coop_isolation] inventario isolado da copia; hooks=" .. M.hooks)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: inventario isolado da copia") then return end
    imgui.text("hooks=" .. M.hooks .. "  acoes da copia barradas=" .. M.total)
    for name, n in pairs(M.counts) do imgui.text("  " .. name .. ": " .. n) end
    imgui.tree_pop()
end)
