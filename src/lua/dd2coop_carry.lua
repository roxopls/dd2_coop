-- Let the local player carry known remote replicas without making them vulnerable
-- to ordinary damage. DD2 checks IsInvincible before handling Catch in damageProc.
if _G.dd2coop_carry then return end
local M={enabled=true,hooks=0,allowed=0,restored=0,errors=0,message=''}
_G.dd2coop_carry=M

local function same(a,b)
    return a and b and a:get_address()==b:get_address()
end
local function known_target(character,P)
    if not character or not P or not P.orig or same(character,P.orig)then return false end
    if P.state~='pronto' or (P.source_idx~=3 and P.source_idx~=4)then return false end
    if P.clone and not P.hidden and same(character,P.clone)then return true end
    for _,slot in ipairs((_G.dd2coop_extra or {}).slots or {})do
        if slot.state=='pronto' and slot.active and same(character,slot.clone)then return true end
    end
    return false
end
local function owner(hit)
    return hit and hit:get_field('<CachedCharacter>k__BackingField')
end
local function flag(name)
    local td=sdk.find_type_definition('app.AttackUserData.AttackFlagEnum')
    local f=td and td:get_field(name)
    return f and math.tointeger(tonumber(f:get_data(nil)))
end
local zero_fields={'Damage','FixedDamage','SlashDamage','BlowDamage','ShootDamage',
    'MagicDamage','EnchantDamage','NonMagicElementDamage','StaminaDamage'}
local catch_flag,zero_flag=flag('Catch'),flag('DamagePoint0')
local td=sdk.find_type_definition('app.HitController')
local method=td and td:get_method('damageProc')
local params=method and method:get_param_types()
if catch_flag and zero_flag and params and #params==1 and
        params[1]:get_full_name()=='app.HitController.DamageInfo'then
    sdk.hook(method,function(args)
        local storage=thread.get_hook_storage()
        storage.dd2coop_carry_restore=nil
        if not M.enabled then return end
        local ok,err=pcall(function()
            local P=_G.dd2coop_p2
            local hit=sdk.to_managed_object(args[2])
            if not known_target(owner(hit),P)then return end
            local info=sdk.to_managed_object(args[3])
            if not info then return end
            local from=info:call('get_AttackOwnerHitController')or info:call('get_AttackHitController')
            if not same(owner(from),P.orig)then return end
            local attack=info:call('get_AttackUserData')
            if not attack then return end
            local bits=math.tointeger(tonumber(attack:get_field('AttackFlag')))
            if not bits or (bits&catch_flag)==0 or (bits&zero_flag)==0 then return end
            if tonumber(attack:get_field('DamageValue'))~=0 then return end
            for _,name in ipairs(zero_fields)do
                if tonumber(info:get_field(name))~=0 then return end
            end
            if hit:call('get_IsNoDie')~=true or hit:call('get_IsInvincible')~=true then return end
            -- The engine holds this method's receiver alive for the whole call.
            -- Keep its wrapper only until post-hook, including if the registry changes.
            storage.dd2coop_carry_restore=hit
            hit:call('set_IsInvincible',false)
            M.allowed=M.allowed+1
        end)
        if not ok then M.errors=M.errors+1;M.message=tostring(err)end
    end,function(ret)
        local storage=thread.get_hook_storage()
        local hit=storage.dd2coop_carry_restore
        storage.dd2coop_carry_restore=nil
        if hit then
            local ok,err=pcall(function()hit:call('set_IsInvincible',true)end)
            if ok then M.restored=M.restored+1
            else M.errors=M.errors+1;M.message=tostring(err)end
        end
        return ret
    end)
    M.hooks=1
else M.message='Catch flags or HitController.damageProc signature unavailable'end

re.on_draw_ui(function()
    if not imgui.tree_node('DD2 Co-op: carregar jogadores')then return end
    local changed,value=imgui.checkbox('Permitir carregar as copias',M.enabled)
    if changed then M.enabled=value end
    imgui.text('Agarroes: '..M.allowed..' | protecoes restauradas: '..M.restored..' | erros: '..M.errors)
    if M.message~=''then imgui.text(M.message)end
    imgui.tree_pop()
end)
log.info('[dd2coop_carry] zero-damage local catch exception; hooks='..M.hooks)
