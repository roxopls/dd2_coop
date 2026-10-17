-- DD2 Co-op: com outros jogadores na sessão, o menu não pausa o jogo (como no Seamless Coop).
-- Menu de pausa, inventário e mapa passam por GuiManager.requestGUIPause(true), que liga
-- IsRequestGUIPause e pede PauseManager.requestPause(true, InGame(5), "GuiManager"). A chamada
-- inteira é ignorada com par na sessão (ignorar só o requestPause deixava IsRequestGUIPause preso
-- e o menu nunca mais pausava, nem depois da sessão). Cutscene, diálogo, warp, acampamento etc.
-- usam outros caminhos e continuam pausando.
local M = { skipped = 0, test = false }
_G.dd2coop_nopause = M

local function in_session()
    if M.test then return true end
    local S = _G.dd2coop_session
    local ls = S and S.status
    return ls and (ls.role == "host" or ls.role == "cliente") and S.peers and #S.peers > 0
end

local m = sdk.find_type_definition("app.GuiManager"):get_method("requestGUIPause")
if m then
    -- Ignorada a abertura, o GuiManager não liga IsRequestGUIPause e o fechamento não manda o
    -- requestGUIPause(false): pausa e soltura continuam balanceadas. Nunca chamar
    -- requestPause/requestGUIPause(false) por fora: um "soltar" a mais deixa CallCount negativo e
    -- o jogo congela pausado (visto em 2026-10-17).
    sdk.hook(m, function(args)
        if (sdk.to_int64(args[3]) & 1) == 1 and in_session() then
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
