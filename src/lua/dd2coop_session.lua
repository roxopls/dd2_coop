-- DD2 Co-op: sessao host/cliente pelo lobby da Steam.
-- Host: "Hospedar sessao" cria um lobby so para amigos. Cliente: "Entrar no amigo" entra no
-- lobby que o amigo esta hospedando (versao do protocolo conferida pelo plugin).
-- Com um par no lobby, a sessao faz sozinha, em ordem:
--   1. SteamID do par no puppet (P2P);
--   2. envia o proprio perfil (aparencia + vocacao/armas) ao par;
--   3. com o perfil do par recebido e sem jogador 2, cria o jogador 2 com o avatar dele;
--   4. jogador 2 pronto: fonte do input = rede P2P (ele aparece quando chegam dados).
-- Par saiu: input parado (a regra de conexao do puppet o deixa invisivel).
-- O dono do lobby e o host da sessao (autoridade de mundo nas proximas etapas).
local M = { status = nil, frame = 0, auto = true, peer = nil, sent_to = nil, spawned_for = nil,
    friend = "", message = "" }
_G.dd2coop_session = M

local REQ, STATUS = "dd2coop_lobby_req.json", "dd2coop_lobby_status.json"

local function request(action, friend)
    local req = { id = math.floor(os.time() * 1000 + (os.clock() * 1000) % 1000), action = action, friend = friend or "" }
    local ok, r = pcall(json.dump_file, REQ, req)
    M.message = ok and r ~= false and ("pedido: " .. action) or "falha ao gravar pedido"
end
M.request = request

-- todos os outros membros, na ordem do lobby; o primeiro vira o jogador 2 (puppet) e os
-- demais, as cópias extras (dd2coop_extra)
local function other_members(ls)
    local out = {}
    if type(ls) ~= "table" or type(ls.members) ~= "table" then return out end
    for _, m in ipairs(ls.members) do
        if type(m) == "table" and type(m.id) == "string" and m.id ~= ls.me and #out < 3 then out[#out + 1] = m.id end
    end
    return out
end
M.peers = {}
M.owner = nil

local function step()
    local s, A = _G.dd2coop_p2, _G.dd2coop_avatar
    if not (s and A) then return end
    local ls = M.status
    local active = ls and (ls.role == "host" or ls.role == "cliente")
    local peers = active and other_members(ls) or {}
    M.owner = active and ls.owner or nil
    -- o jogador 2 continua com o par atual enquanto ele estiver na sessão
    local peer = nil
    for _, id in ipairs(peers) do if id == M.peer then peer = id end end
    peer = peer or peers[1]
    local key = table.concat(peers, ",")
    if key ~= table.concat(M.peers, ",") then
        M.peers, M.sent_to = peers, nil -- alguém entrou ou saiu: reenvia o perfil para todos
        log.info("[dd2coop_session] jogadores na sessao: " .. (key ~= "" and key or "nenhum"))
    end
    if peer ~= M.peer then
        M.peer, M.sent_to = peer, nil
        if peer then
            s.set_peer(peer)
            log.info("[dd2coop_session] par na sessao: " .. peer)
        elseif s.source_idx == 4 then
            s.set_source(1)
            log.info("[dd2coop_session] par saiu; jogador 2 parado")
        end
    end
    if not (peer and M.auto) then return end
    if M.sent_to ~= key then
        A.send_mode = 2
        if A.send_profile() then M.sent_to = key end
        return
    end
    -- avatar do jogador 2 = o perfil do par dele (com vários na sessão, não o último recebido)
    local b = A.peer_bundle and A.peer_bundle(peer)
    if b then A.peer = b end
    if s.state == "nenhum" and A.peer then
        A.source = "peer"
        A.armed = A.source_data() ~= nil
        if A.armed and s.spawn() then M.spawned_for = peer end
        return
    end
    if s.state == "pronto" and s.source_idx ~= 4 and not s.hidden then
        s.set_source(4)
    end
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    M.frame = M.frame + 1
    if M.frame % 60 ~= 0 then return end
    local ok, ls = pcall(json.load_file, STATUS)
    if ok and type(ls) == "table" then M.status = ls end
    local okstep, err = pcall(step)
    if not okstep then M.message = "erro na sessao: " .. tostring(err) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: sessao (host/cliente)") then return end
    local ls = M.status
    imgui.text("papel: " .. tostring(ls and ls.role or "?") .. "   versao: " .. tostring(ls and ls.version or "?"))
    if ls and ls.error and ls.error ~= "" then imgui.text("erro: " .. ls.error) end
    if ls and type(ls.members) == "table" then
        for _, m in ipairs(ls.members) do
            imgui.text(string.format("  %s %s%s", tostring(m.name), tostring(m.id), m.id == ls.owner and "  (host)" or ""))
        end
    end
    local role = ls and ls.role or "nenhum"
    if role == "nenhum" then
        if imgui.button("Hospedar sessao") then request("host") end
        if M.friend == "" and _G.dd2coop_p2 then M.friend = _G.dd2coop_p2.get_peer() or "" end
        local changed, v = imgui.input_text("SteamID64 do host", M.friend)
        if changed then M.friend = v:gsub("%s", "") end
        if imgui.button("Entrar no amigo") then request("join", M.friend) end
    else
        if imgui.button("Sair da sessao") then request("leave") end
    end
    local c, a = imgui.checkbox("Preparar o jogador 2 sozinho (perfil, criacao, P2P)", M.auto)
    if c then M.auto = a end
    if M.message ~= "" then imgui.text(M.message) end
    imgui.tree_pop()
end)

log.info("[dd2coop_session] sessao carregada")
