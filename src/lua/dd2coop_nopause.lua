-- DD2 Co-op: com outros jogadores na sessão, o menu não pausa o jogo (como no Seamless Coop).
-- Menu de pausa, inventário e mapa pedem PauseManager.requestPause(true, InGame(5), "GuiManager");
-- esse pedido é ignorado enquanto houver par na sessão. Cutscene, diálogo, warp, acampamento
-- etc. usam outros tipos e continuam pausando.
local M = { skipped = 0, test = false }
_G.dd2coop_nopause = M

local IN_GAME = 5

local function in_session()
    if M.test then return true end
    local S = _G.dd2coop_session
    local ls = S and S.status
    return ls and (ls.role == "host" or ls.role == "cliente") and S.peers and #S.peers > 0
end

local m = sdk.find_type_definition("app.PauseManager"):get_method("requestPause")
if m then
    sdk.hook(m, function(args)
        local on = (sdk.to_int64(args[3]) & 1) == 1
        if not on or (sdk.to_int64(args[4]) & 0xFFFFFFFF) ~= IN_GAME then return end
        local ok, name = pcall(function() return sdk.to_managed_object(args[5]):call("ToString") end)
        if not ok or name ~= "GuiManager" then return end
        if in_session() then
            M.skipped = M.skipped + 1
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end, function(r) return r end)
end

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: menu sem pausa") then return end
    imgui.text("com jogadores na sessao o menu nao pausa; pausas evitadas=" .. M.skipped)
    local c, v = imgui.checkbox("Teste sem sessao", M.test)
    if c then M.test = v end
    imgui.tree_pop()
end)

log.info("[dd2coop_nopause] menu sem pausa em sessao")
