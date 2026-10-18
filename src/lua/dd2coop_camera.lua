-- Remote Arisen animation camera tracks must not drive the local player's camera.
-- Match live instances, never the CharacterID shared by all Arisen.
if _G.dd2coop_camera then return end
local M = { enabled=true, blocked=0, hooks=0, errors=0, message='' }
_G.dd2coop_camera = M

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

local td=sdk.find_type_definition('app.SkillCameraTrack')
local method=td and td:get_method('update(app.Character)')
if method then
    sdk.hook(method,function(args)
        if not M.enabled then return end
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

re.on_draw_ui(function()
    if not imgui.tree_node('DD2 Co-op: camera local') then return end
    local changed,value=imgui.checkbox('Isolar camera das copias',M.enabled)
    if changed then M.enabled=value end
    imgui.text('Trilhas remotas bloqueadas: '..M.blocked..' | hooks: '..M.hooks..' | erros: '..M.errors)
    if M.message~='' then imgui.text(M.message) end
    imgui.tree_pop()
end)
log.info('[dd2coop_camera] remote SkillCameraTrack isolation; hooks='..M.hooks)
