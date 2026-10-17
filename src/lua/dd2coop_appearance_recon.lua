-- DD2 Co-op: bounded, read-only trace of the replica's initial build.
local M={lines={},hooks=0,frame=0,dirty=false,message="aguardando geracao da copia"}
_G.dd2coop_appearance_recon=M
local function add(line)
    if #M.lines>=300 then table.remove(M.lines,1) end
    M.lines[#M.lines+1]=os.date("%H:%M:%S").." "..line
    M.dirty=true
end
local td=sdk.find_type_definition("app.CharacterEditManager")
for _,method in ipairs(td and td:get_methods() or {}) do
    local name=method:get_name()
    if name:match("^requestBuild") or name=="requestCharaBuild" then
        local params=method:get_param_types()
        local signature={}
        for _,p in ipairs(params)do signature[#signature+1]=p:get_full_name() end
        local label=name.."("..table.concat(signature,",")..")"
        sdk.hook(method,function(args)
            local s=_G.dd2coop_p2
            if not s or s.state~="gerando" then return end
            pcall(function()
                local values={label}
                for i,p in ipairs(params) do
                    local pn=p:get_full_name()
                    if pn=="via.GameObject" or pn:match("Context$") then
                        local ob=sdk.to_managed_object(args[i+2])
                        values[#values+1]=pn.."="..(ob and string.format("0x%X",ob:get_address())or"nil")
                        if ob and pn=="via.GameObject" then values[#values+1]=ob:call("get_Name") end
                    elseif pn=="app.CharacterID" then values[#values+1]="CharacterID="..sdk.to_int64(args[i+2]) end
                end
                add(table.concat(values," "))
                M.message="montagem inicial capturada"
            end)
        end,function(ret)return ret end)
        M.hooks=M.hooks+1
    end
end
local last_clone
re.on_pre_application_entry("LateUpdateBehavior",function()
    M.frame=M.frame+1
    if M.frame%30~=0 then return end
    local s=_G.dd2coop_p2
    if s and s.state=="pronto" and s.clone then
        pcall(function()
            local address=s.clone:get_address()
            if address~=last_clone then
                last_clone=address
                local p=_G.dd2coop_profiles and _G.dd2coop_profiles.capture(s.clone)
                add(string.format("clone pronto 0x%X vocacao=%s cabelo=%s cabeca=%s",address,
                    tostring(p and p.vocation),tostring(p and p.styles._HairStyle),tostring(p and p.styles._HeadStyle)))
            end
        end)
    end
    if M.dirty then
        local ok,result=pcall(fs.write,"dd2coop_appearance_trace.txt",table.concat(M.lines,"\n"))
        if ok and result~=false then M.dirty=false end
    end
end)
re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: montagem da aparencia (registro)")then return end
    imgui.text("Somente leitura; nao modifica o corpo nem o rosto.")
    imgui.text("hooks="..M.hooks.."  "..M.message)
    imgui.text("Registro: reframework/data/dd2coop_appearance_trace.txt")
    imgui.tree_pop()
end)
add("recon carregado; hooks="..M.hooks)
