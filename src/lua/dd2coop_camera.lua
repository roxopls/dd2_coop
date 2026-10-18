-- Remote Arisen animation camera tracks must not drive the local player's camera.
-- Match live instances, never the CharacterID shared by all Arisen.
-- The hooks are installed only after the first replica is fully created, and they do nothing
-- while any replica is still being created: creation is when the game crashed most, so nothing
-- of ours touches the camera then.
if _G.dd2coop_camera then return end
local M = { enabled=true, blocked=0, hooks=0, errors=0, message='', installed=false }
_G.dd2coop_camera = M

-- a replica already created and none being created now
local function ready()
    local P=_G.dd2coop_p2
    local X=_G.dd2coop_extra
    if (P and P.state~='nenhum' and P.state~='pronto') or (X and X.busy) then return false end
    if P and P.state=='pronto' and P.clone then return true end
    for _,slot in ipairs(X and X.slots or {}) do
        if slot.state=='pronto' and slot.clone then return true end
    end
    return false
end

local function is_clone(address)
    if not address or address==0 then return false end
    local P=_G.dd2coop_p2
    -- An ambiguous/recovered identity must never suppress the original's camera.
    if P and P.orig and P.orig:get_address()==address then return false end
    if P and P.clone and P.clone:get_address()==address then return true end
    for _,slot in ipairs((_G.dd2coop_extra or {}).slots or {}) do
        if slot.clone and slot.clone:get_address()==address then return true end
    end
    return false
end

-- With a replica alive the main camera could end up reading the replica's UserInput (the remote
-- player turned the host's camera, 2026-10-17). Replica inputs are registered in
-- UserInputManager.CharacterInputs next to the player's, and switchUserInput writes the camera
-- fields directly (it does not go through set_UserInput). So: set_UserInput with a replica input
-- is skipped, and after switchUserInput a replica choice is put back to the local player's input
-- with set_UserInput (the game's setter; the crashes once blamed on it came from the avatar
-- writing inside the build MetaData, 2026-10-18).
local function is_clone_input(address)
    if not address or address==0 then return false end
    local P=_G.dd2coop_p2
    local function input_of(ch)
        local ok,i=pcall(function() return ch:call('get_Input') end)
        return ok and i and i:get_address() or nil
    end
    if P and P.clone and input_of(P.clone)==address then return true end
    for _,slot in ipairs((_G.dd2coop_extra or {}).slots or {}) do
        if slot.clone and input_of(slot.clone)==address then return true end
    end
    return false
end
M.input_blocked=0
M.input_restored=0

local function install()
    local td=sdk.find_type_definition('app.SkillCameraTrack')
    local method=td and td:get_method('update(app.Character)')
    if method then
        sdk.hook(method,function(args)
            if not M.enabled or not ready() then return end
            local ok,remote=pcall(function() return is_clone(sdk.to_int64(args[3])) end)
            if not ok then
                M.errors=M.errors+1
                M.message=tostring(remote)
                return -- preserve original behavior when ownership cannot be established
            end
            if remote then
                M.blocked=M.blocked+1
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end,function(ret) return ret end)
        M.hooks=M.hooks+1
    else M.message='SkillCameraTrack.update(app.Character) not found' end

    local mcc_td=sdk.find_type_definition('app.MainCameraController')
    local set_input=mcc_td and mcc_td:get_method('set_UserInput(app.UserInput)')
    if set_input then
        sdk.hook(set_input,function(args)
            if not M.enabled or not ready() then return end
            local ok,remote=pcall(function() return is_clone_input(sdk.to_int64(args[3])) end)
            if not ok then M.errors=M.errors+1;M.message=tostring(remote);return end
            if remote then
                M.input_blocked=M.input_blocked+1
                log.info('[dd2coop_camera] camera tried to take a replica input: blocked ('..M.input_blocked..')')
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end,function(ret) return ret end)
        M.hooks=M.hooks+1
    end
    local switch_input=mcc_td and mcc_td:get_method('switchUserInput(app.CameraDefine.InputType)')
    if switch_input and set_input then
        sdk.hook(switch_input,function(args)
            thread.get_hook_storage().dd2coop_mcc=args[2]
        end,function(ret)
            local this=thread.get_hook_storage().dd2coop_mcc
            if not M.enabled or not this or not ready() then return ret end
            local ok,err=pcall(function()
                local mcc=sdk.to_managed_object(this)
                local ui=mcc and mcc:call('get_UserInput')
                if not ui or not is_clone_input(ui:get_address()) then return end
                local me=sdk.get_managed_singleton('app.CharacterManager'):call('get_ManualPlayer')
                local mi=me and me:call('get_Input')
                if not mi or is_clone_input(mi:get_address()) then return end
                mcc:call('set_UserInput',mi)
                M.input_restored=M.input_restored+1
                log.info('[dd2coop_camera] switchUserInput picked a replica input: player input restored ('..M.input_restored..')')
            end)
            if not ok then M.errors=M.errors+1;M.message=tostring(err) end
            return ret
        end)
        M.hooks=M.hooks+1
    end
    log.info('[dd2coop_camera] camera isolation installed after the first replica was created; hooks='..M.hooks)
end

-- fallback for paths not yet known (the swap seen in the 2026-10-17 session did not come from
-- set_UserInput, and switchUserInput did not reproduce it alone): every 30 frames, with all
-- replicas ready, a camera reading a replica input gets the player's back
M.input_periodic=0
local frame=0
local function periodic()
    local me=sdk.get_managed_singleton('app.CharacterManager'):call('get_ManualPlayer')
    local mi=me and me:call('get_Input')
    if not mi or is_clone_input(mi:get_address()) then return end
    local sm=sdk.get_native_singleton('via.SceneManager')
    local scene=sdk.call_native_func(sm,sdk.find_type_definition('via.SceneManager'),'get_CurrentScene()')
    local list=scene and scene:call('findComponents(System.Type)',sdk.typeof('app.MainCameraController'))
    local mcc=list and list:get_size()>0 and list:get_element(0) or nil
    local ui=mcc and mcc:call('get_UserInput')
    if ui and is_clone_input(ui:get_address()) then
        mcc:call('set_UserInput',mi)
        M.input_periodic=M.input_periodic+1
        log.info('[dd2coop_camera] camera was reading a replica input (unknown path): player input restored ('..M.input_periodic..')')
    end
end

re.on_pre_application_entry('LateUpdateBehavior',function()
    frame=frame+1
    if not ready() then return end
    if not M.installed then
        M.installed=true
        local ok,err=pcall(install)
        if not ok then M.errors=M.errors+1;M.message=tostring(err) end
    end
    if M.enabled and frame%30==0 then
        local ok,err=pcall(periodic)
        if not ok then M.errors=M.errors+1;M.message=tostring(err) end
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node('DD2 Co-op: camera local') then return end
    local changed,value=imgui.checkbox('Isolar camera das copias',M.enabled)
    if changed then M.enabled=value end
    imgui.text((M.installed and 'ativa' or 'espera a primeira copia ficar pronta')..' | hooks: '..M.hooks..' | erros: '..M.errors)
    imgui.text('Trilhas remotas bloqueadas: '..M.blocked)
    imgui.text('Camera pegando controle da copia: bloqueado '..M.input_blocked..' | devolvido '..M.input_restored..' | periodico '..M.input_periodic)
    if M.message~='' then imgui.text(M.message) end
    imgui.tree_pop()
end)
log.info('[dd2coop_camera] loaded; hooks wait for the first replica to be ready')
