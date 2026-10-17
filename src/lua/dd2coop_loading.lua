-- DD2 Co-op: tela de "sincronizando" quando alguém entra na sessão.
-- Criar a cópia Arisen e aplicar aparência/vocação trava o jogo por um instante (e quem estava
-- em combate apanhava durante a travada). Quando a lista de jogadores da sessão ganha alguém:
--   * tela preta com aviso por cima do jogo;
--   * o próprio jogador fica invencível e sem controle;
--   * some quando todos os jogadores têm cópia pronta (jogador 2: dd2coop_puppet pronto com o
--     avatar aplicado; 3 e 4: slot do dd2coop_extra pronto) e, no cliente, chegou o primeiro
--     estado dos inimigos do host; mais SETTLE s para a travada passar. No máximo TIMEOUT s.
local M = { active = false, since = 0, ready_at = nil, known = {}, message = "", shown = 0, test = false }
_G.dd2coop_loading = M

local TIMEOUT = 30
local SETTLE = 1.5

local function me() return sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer") end

local function hold(on)
    pcall(function()
        local p = me()
        if not p then return end
        local R = _G.dd2coop_revive
        if R and R.downed then return end -- caído: o reviver controla vida e input
        p:call("get_Hit"):call("set_IsInvincible", on)
        p:call("get_InputProcessor"):call("set_IsEnable", not on)
    end)
end

-- cópia pronta para o jogador sid?
local function copy_ready(sid)
    local P = _G.dd2coop_p2
    if P and P.get_peer and P.get_peer() == sid then
        return P.state == "pronto" and P.clone ~= nil and P.avatar_applied == true
    end
    local X = _G.dd2coop_extra
    for _, s in ipairs(X and X.slots or {}) do
        if s.peer == sid then return s.state == "pronto" and s.clone ~= nil end
    end
    return false
end

local function all_ready()
    local S = _G.dd2coop_session
    for _, sid in ipairs(S and S.peers or {}) do
        if not copy_ready(sid) then return false, "criando jogador " .. sid end
    end
    local ls = S and S.status
    local E = _G.dd2coop_enemies
    if ls and ls.role == "cliente" and E and E.last_in < 0 then return false, "recebendo o mundo do host" end
    return true
end

local function start()
    M.active, M.since, M.ready_at, M.shown = true, os.clock(), nil, M.shown + 1
    hold(true)
    log.info("[dd2coop_loading] sincronizando")
end

local function stop(why)
    M.active = false
    hold(false)
    log.info("[dd2coop_loading] pronto (" .. why .. ")")
end

local frame = 0
re.on_pre_application_entry("LateUpdateBehavior", function()
    frame = frame + 1
    if frame % 10 ~= 0 then return end
    local ok, err = pcall(function()
        local S = _G.dd2coop_session
        local peers = S and S.peers or {}
        -- alguém novo na sessão: começa
        local now_known, joined = {}, false
        for _, sid in ipairs(peers) do
            now_known[sid] = true
            if not M.known[sid] then joined = true end
        end
        M.known = now_known
        if (joined or M.test) and not M.active then start(); M.test = false end
        if not M.active then return end
        if #peers == 0 and os.clock() - M.since > 2 then stop("sessao vazia"); return end
        local ready, step = all_ready()
        M.message = step or ""
        if ready then
            M.ready_at = M.ready_at or os.clock()
            if os.clock() - M.ready_at >= SETTLE then stop("todos prontos") end
        else
            M.ready_at = nil
        end
        if M.active and os.clock() - M.since > TIMEOUT then stop("tempo esgotado: " .. M.message) end
    end)
    if not ok then M.message = "erro: " .. tostring(err); if M.active then stop("erro") end end
end)

re.on_frame(function()
    if not M.active then return end
    pcall(function()
        local w, h = 1920, 1080
        local ok, size = pcall(imgui.get_display_size)
        if ok and size then w, h = size.x, size.y end
        draw.filled_rect(0, 0, w, h, 0xFF000000)
        local dots = string.rep(".", math.floor(os.clock() * 2) % 4)
        draw.text("Sincronizando com os outros jogadores" .. dots, w * 0.5 - 170, h * 0.5 - 10, 0xFFFFFFFF)
        if M.message ~= "" then draw.text(M.message, w * 0.5 - 170, h * 0.5 + 14, 0xFFAAAAAA) end
    end)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: tela de sincronizar") then return end
    imgui.text((M.active and "ATIVA " or "inativa ") .. "vezes=" .. M.shown .. " " .. M.message)
    if imgui.button("Testar (mostra ate todos prontos ou 30 s)") then M.test = true end
    imgui.tree_pop()
end)

log.info("[dd2coop_loading] tela de sincronizar carregada")
