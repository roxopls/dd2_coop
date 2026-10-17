-- DD2 Co-op: prepare the stopped replica from its selected profile.
-- Character-owned JobChanger/weapon slots only; never ItemManager/inventory.
local M = {frame=0, message="", pending=nil}
_G.dd2coop_loadout = M
local function key(o) return o and o:get_address() end
-- target: cópia de outro jogador (dd2coop_extra.lua); sem target, o jogador 2 do puppet
local function context(target)
    local profiles = _G.dd2coop_profiles
    if not profiles then return nil, "modulo de perfis indisponivel" end
    local ctx, why
    if target then
        local s = _G.dd2coop_p2
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local original = s and s.orig or (cm and cm:call("get_ManualPlayer"))
        if not (s and original) then return nil, "sem player" end
        ctx = { state = s, original = original, clone = target }
    else
        ctx, why = profiles.context()
    end
    if not ctx or not ctx.clone then return nil, why or "crie a copia primeiro" end
    local s = ctx.state
    if not target and (s.source_idx ~= 1 or profiles.pending) then return nil, "pare a copia e aguarde a troca de roupa" end
    if not s.net_status or (s.net_status.save_hooks or 0) == 0 then return nil, "protecao nativa indisponivel" end
    local o,c = ctx.original, ctx.clone
    local oh,ch = o:call("get_Human"),c:call("get_Human")
    local oj,cj = oh:call("get_JobContext"),ch:call("get_JobContext")
    local oc,cc = o:get_field("WeaponContext"),c:get_field("WeaponContext")
    local ow,cw = o:call("get_WeaponAndItemHolder"),c:call("get_WeaponAndItemHolder")
    local changer = ch:call("get_JobChanger")
    for _,pair in ipairs({{oh,ch},{oj,cj},{oc,cc},{ow,cw}}) do
        if not pair[1] or not pair[2] or key(pair[1]) == key(pair[2]) then
            return nil, "contexto compartilhado ou ausente; preparacao interrompida"
        end
    end
    if not changer or key(changer:get_field("Chara")) ~= key(c) or
        key(changer:get_field("JobContext")) ~= key(cj) then return nil, "dono da vocacao nao confere" end
    ctx.slots = {}
    for _,side in ipairs({"Right","Left"}) do
        local a,b = ow:call("get_"..side.."Weapon"),cw:call("get_"..side.."Weapon")
        if not a or not b or key(a)==key(b) then return nil, "slot de arma compartilhado ou ausente" end
        ctx.slots[side:lower()] = b
    end
    ctx.changer,ctx.job = changer,cj
    return ctx
end
local function enum_has(name, value)
    local td=sdk.find_type_definition(name)
    for _,f in ipairs(td and td:get_fields() or {}) do
        if f:is_static() and f:get_data(nil)==value then return true end
    end
    return false
end
local function fail(message) M.pending=nil; M.message=message; log.info("[dd2coop_loadout] "..message) end
function M.apply(raw, target)
    if M.pending then M.message="preparacao em andamento"; return false end
    local p,why = _G.dd2coop_profiles.validate(raw)
    if not p then M.message=why; return false end
    local ok,ctx,err = pcall(context,target)
    if not ok or not ctx then M.message=err or (not ok and tostring(ctx)) or "copia indisponivel"; return false end
    if not enum_has("app.Character.JobEnum",p.vocation) or p.vocation==0 then
        M.message="vocacao do perfil nao reconhecida"; return false
    end
    for _,side in ipairs({"right","left"}) do
        local w=p.weapons[side]
        if w.id==nil or w.appearance_id==nil or w.equipped==nil or
            not enum_has("app.WeaponID",w.id) or not enum_has("app.WeaponID",w.appearance_id) then
            M.message="perfil sem IDs de armas reconhecidos nas duas maos"; return false
        end
        -- Empty-slot removal needs separate validation; never guess a native ID.
        if w.appearance_id==0 and ctx.slots[side]:call("get_WeaponID")~=0 then
            M.message="remocao de arma existente ainda nao implementada"; return false
        end
        if (w.id==0) ~= (w.appearance_id==0) or w.equipped ~= (w.id~=0) then
            M.message="perfil de armas inconsistente"; return false
        end
    end
    local before=_G.dd2coop_profiles.capture(ctx.original)
    local wrote,result=pcall(json.dump_file,"dd2coop_loadout_before.json",{
        instance=ctx.state.instance,clone=string.format("0x%X",key(ctx.clone)),
        original=before,replica=_G.dd2coop_profiles.capture(ctx.clone),requested=p})
    if not wrote or result==false then M.message="falha ao registrar estado anterior"; return false end
    M.pending={instance=ctx.state.instance,clone=key(ctx.clone),original=key(ctx.original),
        profile=p,before=before,stage="job",started=M.frame,target=target}
    local changed,change_error=pcall(function()
        if ctx.job:call("get_Job")~=p.vocation then
            ctx.changer:call("requestChangeJob(app.Character.JobEnum)",p.vocation)
        end
    end)
    if not changed then fail("falha ao pedir vocacao: "..tostring(change_error)); return false end
    M.message="preparando vocacao e armas do perfil na copia"
    return true
end
local function advance()
    local pending=M.pending
    local ctx,why=context(pending.target)
    if not ctx or ctx.state.instance~=pending.instance or key(ctx.clone)~=pending.clone or key(ctx.original)~=pending.original then
        fail(why or "personagens mudaram; preparacao interrompida"); return
    end
    local profiles=_G.dd2coop_profiles
    if profiles.compare(pending.before,profiles.capture(ctx.original)).blocked then
        fail("original mudou durante a preparacao; operacao interrompida"); return
    end
    if M.frame-pending.started>600 then fail("preparacao nao confirmada; confira os logs"); return end
    local p=pending.profile
    if pending.stage=="job" then
        -- o JobContext da copia pode nascer ja com o job do save (CharacterID compartilhado);
        -- o seletor de acoes (vocation na captura) so muda depois das armas
        if ctx.job:call("get_Job")~=p.vocation then return end
        -- Use the replica's own slot callbacks to attach and initialize each weapon.
        for _,side in ipairs({"right","left"}) do
            local id=p.weapons[side].appearance_id
            if id~=0 and ctx.slots[side]:call("get_WeaponID")~=id then
                if ctx.slots[side]:call("requestEquipWeapon(app.WeaponID)",id)~=true then
                    fail("pedido de arma recusado: "..side); return
                end
            end
        end
        pending.stage="weapons"
    else
        for _,side in ipairs({"right","left"}) do
            local slot,id=ctx.slots[side],p.weapons[side].appearance_id
            if slot:call("get_WeaponID")~=id or (id~=0 and not slot:call("get_Weapon")) then return end
        end
        if profiles.capture(ctx.clone).vocation~=p.vocation then return end
        -- Appearance overrides are not physical inventory/stat replication.
        fail("vocacao e objetos das armas confirmados na copia; confira a aparencia")
    end
end
re.on_pre_application_entry("LateUpdateBehavior",function()
    M.frame=M.frame+1
    if not M.pending or M.frame%15~=0 then return end
    local ok,err=pcall(advance)
    if not ok then fail("falha durante preparacao: "..tostring(err)) end
end)
re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: vocacao e armas da copia") then return end
    imgui.text("A copia usa a vocacao e as armas do perfil carregado.")
    local profiles=_G.dd2coop_profiles
    if profiles and profiles.imported then
        if imgui.button("Aplicar vocacao e armas do perfil a copia parada") then M.apply(profiles.imported) end
    else imgui.text("Carregue um perfil no painel perfil e roupa.") end
    imgui.text("Inventario, melhorias de armas e skills customizadas nao sao copiados.")
    if M.message~="" then imgui.text(M.message) end
    imgui.tree_pop()
end)
