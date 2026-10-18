-- DD2 Co-op: portable profiles and a stopped-replica wardrobe.
-- MetaData.clone() was confirmed in the game's reflection dump. Keep the
-- original metadata untouched; no ItemManager, job changes, face/body rebuilds.
-- Managed reference handling: https://cursey.github.io/reframework-book/api/types/REManagedObject.html
local M = { version = 2, frame = 0, message = "", imported = nil, comparison = nil }
_G.dd2coop_profiles = M
local PROFILE, BACKUP = "dd2coop_profile.json", "dd2coop_visual_backup.json"
local RESTORE = "restore(app.CharacterEditDefine.MetaData, app.CharacterEditDefine.VisorSwitch)"
local OUTFIT = { _TopsStyle = true, _PantsStyle = true, _HelmStyle = true,
    _MantleStyle = true, _BackpackStyle = true, _FacewearStyle = true, _UnderwearStyle = true,
    _TopsVariationStyle = true, _PantsVariationStyle = true, _HelmVariationStyle = true,
    _MantleVariationStyle = true, _FacewearVariationStyle = true, _UnderwearVariationStyle = true }
local function number(v)
    return type(v) == "number" and v == v and math.abs(v) < math.huge
end
local function integer(v, lo, hi) return number(v) and v % 1 == 0 and v >= lo and v <= hi end
local function scalar(v)
    return number(v) or type(v) == "boolean" or (type(v) == "string" and #v <= 128)
end
local function call(obj, name)
    if not obj then return nil end
    local ok, value = pcall(function() return obj:call(name) end)
    return ok and value or nil -- boolean getters use read_bool below
end
local function read_bool(obj, name)
    if not obj then return nil end
    local ok, value = pcall(function() return obj:call(name) end)
    if ok and type(value) == "boolean" then return value end
end
local function key(obj) return obj and string.format("0x%X", obj:get_address()) end
local function meta_of(ch)
    local sw = call(ch, "get_HumanPartSwapper")
    local ok, meta = pcall(function() return sw:get_field("_Meta") end)
    return sw, ok and meta or nil
end
local function styles_of(meta)
    local values = {}
    for _, f in ipairs(meta:get_type_definition():get_fields()) do
        if not f:is_static() then
            local ok, value = pcall(function() return meta:get_field(f:get_name()) end)
            if ok and scalar(value) then values[f:get_name()] = value end
        end
    end
    return values
end

function M.capture(ch)
    local sw, meta = meta_of(ch)
    if not meta then return nil, "metadados de aparencia indisponiveis" end
    local styles = styles_of(meta)
    local p = { version = 2, game = "DD2", rig = "ch000000_00", styles = styles,
        species = styles._Species, gender = styles._Gender,
        vocation = call(call(ch, "get_HumanActionSelector"), "get_SelectorFor"),
        visor = call(sw, "get_VisorSwitch"), weapons = {}, captured_at = os.date("%Y-%m-%dT%H:%M:%S") }
    for _, side in ipairs({ "right", "left" }) do
        local name = side == "right" and "Right" or "Left"
        local id = call(ch, "get_" .. name .. "WeaponID")
        local appearance = call(ch, "get_Appearance" .. name .. "WeaponID")
        p.weapons[side] = { id = number(id) and id or nil,
            appearance_id = number(appearance) and appearance or nil,
            equipped = read_bool(ch, "get_IsEquip" .. name .. "Weapon") }
    end
    -- skills equipadas na vocação atual (slot, ID e nível): sem elas a cópia segurava o botão de
    -- skill e não fazia nada
    pcall(function()
        local hu = ch:call("get_Human")
        local sc, job = hu:call("get_SkillContext"), hu:call("get_JobContext"):call("get_Job")
        local skills = {}
        for slot = 0, 5 do
            local id = sc:call("getSkillID", job, slot)
            if number(id) and id ~= 0 then
                skills[#skills + 1] = { slot = slot, id = id, level = sc:call("getCustomSkillLevel", id) }
            end
        end
        p.skills = skills
    end)
    return p
end

function M.validate(raw)
    if type(raw) ~= "table" or raw.game ~= "DD2" or (raw.version ~= 1 and raw.version ~= 2) then
        return nil, "arquivo nao e um perfil DD2 suportado"
    end
    if raw.rig ~= nil and raw.rig ~= "ch000000_00" then return nil, "corpo de perfil nao suportado" end
    for _, field in ipairs({ "species", "gender" }) do
        if not integer(raw[field], -2147483648, 4294967295) then return nil, field .. " invalido" end
    end
    if not integer(raw.vocation, 0, 255) then return nil, "vocacao invalida" end
    if type(raw.styles) ~= "table" then return nil, "estilos ausentes" end
    local p = { version = 2, source_version = raw.version, game = "DD2", rig = "ch000000_00",
        species = raw.species, gender = raw.gender, vocation = raw.vocation,
        styles = {}, weapons = {} }
    local count = 0
    for name, value in pairs(raw.styles) do
        count = count + 1
        if count > 100 or type(name) ~= "string" or #name > 96 or not scalar(value) then
            return nil, "estilos invalidos ou extensos demais"
        end
        p.styles[name] = value
    end
    if (p.styles._Species ~= nil and p.styles._Species ~= p.species) or
        (p.styles._Gender ~= nil and p.styles._Gender ~= p.gender) then
        return nil, "especie/genero inconsistentes com os estilos"
    end
    if raw.visor ~= nil then
        if not integer(raw.visor, -2147483648, 4294967295) then return nil, "visor invalido" end
        p.visor = raw.visor
    end
    if raw.weapons ~= nil and type(raw.weapons) ~= "table" then return nil, "armas invalidas" end
    for _, side in ipairs({ "right", "left" }) do
        local w = raw.weapons and raw.weapons[side]
        if w ~= nil and type(w) ~= "table" then return nil, "arma invalida" end
        p.weapons[side] = {}
        for _, field in ipairs({ "id", "appearance_id" }) do
            if w and w[field] ~= nil then
                if not integer(w[field], -2147483648, 4294967295) then return nil, "ID de arma invalido" end
                p.weapons[side][field] = w[field]
            end
        end
        if w and w.equipped ~= nil then
            if type(w.equipped) ~= "boolean" then return nil, "estado de arma invalido" end
            p.weapons[side].equipped = w.equipped
        end
    end
    if raw.skills ~= nil then
        if type(raw.skills) ~= "table" or #raw.skills > 6 then return nil, "skills invalidas" end
        p.skills = {}
        for _, s in ipairs(raw.skills) do
            if type(s) ~= "table" or not integer(s.slot, 0, 5) or not integer(s.id, 1, 65535) or
                not integer(s.level, 0, 15) then return nil, "skill invalida" end
            p.skills[#p.skills + 1] = { slot = s.slot, id = s.id, level = s.level }
        end
    end
    return p
end

local function get(p, path)
    for part in path:gmatch("[^.]+") do
        if type(p) ~= "table" then return nil end
        p = p[part]
    end
    return p
end
function M.compare(a, b)
    local out = { mismatches = {}, unknown = {} }
    for _, path in ipairs({ "species", "gender", "vocation", "weapons.right.id", "weapons.left.id",
            "weapons.right.equipped", "weapons.left.equipped" }) do
        local av, bv = get(a, path), get(b, path)
        if av == nil or bv == nil then out.unknown[#out.unknown + 1] = path
        elseif av ~= bv then out.mismatches[#out.mismatches + 1] = path end
    end
    out.blocked = #out.mismatches > 0
    out.verified = not out.blocked and #out.unknown == 0
    return out
end
function M.compare_characters(a, b)
    return M.compare(M.capture(a), M.capture(b))
end

local function context()
    local s = _G.dd2coop_p2
    if not s or (s.state ~= "pronto" and s.state ~= "nenhum") then return nil, "sessao ainda nao esta pronta" end
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    local original = s.state == "pronto" and s.orig or call(cm, "get_ManualPlayer")
    local all = call(sdk.get_managed_singleton("app.CharacterListHolder"), "getAllCharacters")
    if not all then return nil, "lista de personagens indisponivel" end
    local original_live, clone_live = false, false
    for i = 0, all:call("get_Count") - 1 do
        local ch = all:call("get_Item", i)
        original_live = original_live or key(ch) == key(original)
        clone_live = clone_live or (s.clone ~= nil and key(ch) == key(s.clone))
    end
    if not original_live or (s.state == "pronto" and not clone_live) then return nil, "personagens mudaram; recupere a sessao" end
    return { state = s, original = original, clone = s.state == "pronto" and s.clone or nil }
end
M.context = context

function M.export_original()
    local ctx, err = context()
    if not ctx then M.message = err; return false end
    local profile = M.capture(ctx.original)
    local normalized, why = M.validate(profile)
    if not normalized then M.message = why; return false end
    local ok, result = pcall(json.dump_file, PROFILE, normalized)
    M.message = ok and result ~= false and "perfil, roupa e armas registrados em dd2coop_profile.json" or "falha ao gravar perfil"
    return ok and result ~= false
end
function M.load_profile()
    local ok, raw = pcall(json.load_file, PROFILE)
    local p, err = M.validate(ok and raw or nil)
    M.imported = p
    M.message = p and "perfil carregado; nenhuma alteracao aplicada" or err
    return p ~= nil
end

local function enum_has(field, value)
    local td = field:get_type()
    if not td or not td:is_enum() then return false end
    for _, item in ipairs(td:get_fields()) do
        if item:is_static() then
            local ok, candidate = pcall(function() return item:get_data(nil) end)
            if ok and candidate == value then return true end
        end
    end
    return false
end
local function outfit_plan(meta, profile)
    local fields, plan = {}, {}
    for _, f in ipairs(meta:get_type_definition():get_fields()) do
        if not f:is_static() then fields[f:get_name()] = f end
    end
    for name in pairs(OUTFIT) do
        local value = profile.styles[name]
        if value ~= nil then
            if not fields[name] or not integer(value, -2147483648, 4294967295) or not enum_has(fields[name], value) then
                return nil, "estilo nao reconhecido pelo jogo: " .. name
            end
            plan[name] = value
        end
    end
    if next(plan) == nil then return nil, "perfil nao contem roupa visual aplicavel" end
    return plan
end

function M.apply_outfit(raw, undo)
    local profile, err = M.validate(raw)
    if not profile then M.message = err; return false end
    local ctx, why = context()
    if not ctx or not ctx.clone then M.message = why or "crie a copia primeiro"; return false end
    local s = ctx.state
    if s.source_idx ~= 1 or M.pending or (_G.dd2coop_loadout and _G.dd2coop_loadout.pending) then
        M.message = "pare o jogador 2 e aguarde a preparacao antes de trocar a roupa"; return false
    end
    if not s.net_status or (s.net_status.save_hooks or 0) == 0 then M.message = "protecao nativa indisponivel"; return false end
    local before = M.capture(ctx.clone)
    if not before then M.message = "aparencia da copia indisponivel"; return false end
    if before.species ~= profile.species or before.gender ~= profile.gender then
        M.message = "especie/genero do perfil diferem da copia"; return false
    end
    local sw, meta = meta_of(ctx.clone)
    local original_sw, original_meta = meta_of(ctx.original)
    if not sw or not meta or not original_sw or not original_meta or
        key(sw) == key(original_sw) or key(meta) == key(original_meta) then
        M.message = "aparencia compartilhada com o original; troca bloqueada"; return false
    end
    local plan, plan_error = outfit_plan(meta, profile)
    if not plan then M.message = plan_error; return false end
    if not undo then
        local ok, backup = pcall(json.load_file, BACKUP)
        if not ok or type(backup) ~= "table" or backup.instance ~= s.instance or backup.clone ~= key(ctx.clone)
            or not M.validate(backup.profile) then
            local wrote, result = pcall(json.dump_file, BACKUP,
                { instance = s.instance, clone = key(ctx.clone), profile = before })
            if not wrote or result == false then M.message = "falha ao guardar roupa anterior"; return false end
        end
    end
    local detached = call(meta, "clone")
    if not detached or key(detached) == key(meta) or key(detached) == key(original_meta) then
        M.message = "nao foi possivel criar metadados independentes"; return false
    end
    detached:add_ref()
    local ok, apply_error = pcall(function()
        for name, value in pairs(plan) do detached:set_field(name, value) end
        -- Visor values come from the live target, never unchecked imported data.
        sw:call(RESTORE, detached, sw:call("get_VisorSwitch"))
        sw:call("requestSwap()")
    end)
    detached:release()
    if not ok then M.message = "falha ao pedir roupa: " .. tostring(apply_error); return false end
    M.pending = { instance = s.instance, clone = key(ctx.clone), expected = plan, started = M.frame }
    M.message = "troca visual solicitada; armas e vocacao mantidas"
    return true
end
function M.undo_outfit()
    local ctx, err = context()
    if not ctx or not ctx.clone then M.message = err or "copia indisponivel"; return false end
    local ok, backup = pcall(json.load_file, BACKUP)
    if not ok or type(backup) ~= "table" or backup.instance ~= ctx.state.instance or backup.clone ~= key(ctx.clone) then
        M.message = "nenhuma roupa anterior desta copia"; return false
    end
    return M.apply_outfit(backup.profile, true)
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    M.frame = M.frame + 1
    if not M.pending or M.frame % 15 ~= 0 then return end
    local ctx = context()
    if not ctx or not ctx.clone or ctx.state.instance ~= M.pending.instance or key(ctx.clone) ~= M.pending.clone then
        M.pending = nil; M.message = "personagens mudaram; verificacao visual interrompida"; return
    end
    local _, meta = meta_of(ctx.clone)
    local matches = meta ~= nil
    for name, value in pairs(M.pending.expected) do
        matches = matches and meta:get_field(name) == value
    end
    if matches then
        M.pending = nil; M.message = "metadados de roupa confirmados; montagem visual solicitada"
    elseif M.frame - M.pending.started > 600 then
        M.pending = nil; M.message = "troca visual nao confirmada; veja os logs antes de repetir"
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: perfil e roupa") then return end
    if imgui.button("Exportar perfil do original (inclui IDs das armas)") then M.export_original() end
    if imgui.button("Carregar perfil de dd2coop_profile.json") then M.load_profile() end
    if imgui.button("Comparar original e copia") then
        local ctx, err = context()
        if ctx and ctx.clone then M.comparison = M.compare_characters(ctx.original, ctx.clone)
        else M.message = err or "crie a copia primeiro" end
    end
    if M.comparison then
        imgui.text(M.comparison.blocked and ("Diferencas: " .. table.concat(M.comparison.mismatches, ", "))
            or M.comparison.verified and "Corpo, vocacao e armas conferem" or "Comparacao incompleta")
        if #M.comparison.unknown > 0 then imgui.text("Sem leitura: " .. table.concat(M.comparison.unknown, ", ")) end
    end
    if M.imported then
        imgui.text("Perfil carregado: vocacao " .. M.imported.vocation)
        if imgui.button("Aplicar somente roupa visual a copia parada") then M.apply_outfit(M.imported) end
    end
    if imgui.button("Restaurar roupa visual anterior da copia") then M.undo_outfit() end
    imgui.text("Para armas e vocacao, use o painel vocacao e armas da copia.")
    if M.message ~= "" then imgui.text(M.message) end
    imgui.tree_pop()
end)
log.info("[dd2coop_profiles] perfil v2 e roupa visual carregados")
