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

log.info("[dd2coop_isolation] inventario isolado da copia; hooks=" .. M.hooks)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: inventario isolado da copia") then return end
    imgui.text("hooks=" .. M.hooks .. "  acoes da copia barradas=" .. M.total)
    for name, n in pairs(M.counts) do imgui.text("  " .. name .. ": " .. n) end
    imgui.tree_pop()
end)
