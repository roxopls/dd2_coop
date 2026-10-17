-- DD2 Co-op: mundo do host (autoridade) -> cliente, pelo barramento do plugin (canal 9).
-- Host (dono do lobby): publica a cada 2 s o horario (dia/hora/minuto) e o clima atual.
-- Cliente: acerta o relogio quando a diferenca passa de 15 min de jogo e fixa o clima do
-- host na area atual (fixAreaWeather) enquanto conectado; ao sair da sessao, solta o clima.
-- Formato do barramento: { seq, mode, peer, msgs = { {t="time",...}, {t="weather",...} } }.
-- Proximas etapas usam o mesmo barramento (quests com credito compartilhado, itens, inimigos).
local M = { frame = 0, seq = 0, last_in = -1, applied_time = 0, applied_weather = 0, fixed_area = nil,
    eco = false, message = "" }
_G.dd2coop_world = M

local OUT, IN = "dd2coop_bus_out.json", "dd2coop_bus_in.json"
-- assinatura real: setTime(hora, minuto, dia, bool) (testado: a ordem dia/hora/minuto pulou 50 dias)
local SET_TIME = "setTime(System.Int32, System.Int32, System.Int32, System.Boolean)"
local TIME_TOLERANCE = 15 -- minutos de jogo
-- climas normais do mundo (Back*/Void/eventos ficam com o jogo do cliente)
local NORMAL_WEATHER = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [11] = true, [12] = true, [13] = true }

local function session_role()
    local S = _G.dd2coop_session
    local ls = S and S.status
    -- lista de todos os jogadores (o plugin manda para cada um)
    local peers = S and S.peers and #S.peers > 0 and table.concat(S.peers, ",") or (S and S.peer)
    return ls and ls.role or "nenhum", peers
end

local function now_time()
    local tm = sdk.get_managed_singleton("app.TimeManager")
    return tm:call("get_InGameDay"), tm:call("get_InGameHour"), tm:call("get_InGameMinute")
end

-- quests (credito compartilhado): o host registra cada resultado de passo de quest; o
-- cliente guarda num registro e, so com o switch ligado, aplica nas quests que tambem tem
-- ativas. Desligado por padrao: aplicar passo de quest fora de contexto pode travar a quest.
M.quest_events = {}   -- host: ultimos 50 eventos { id, q, key, result }
M.quest_seen = {}     -- cliente: ids ja registrados
M.quest_ledger = {}
M.apply_quests = false
M.quest_applied = 0
local QUEST_RESULT = "onUpdateProcessorResult(app.QuestDefine.ID, System.UInt32, System.Int32)"
local applying_quest = false
do
    local td = sdk.find_type_definition("app.QuestManager")
    local m = td and td:get_method(QUEST_RESULT)
    if m then
        sdk.hook(m, function(args)
            if applying_quest or session_role() ~= "host" then return end
            local q, key, result = sdk.to_int64(args[3]) & 0xFFFFFFFF, sdk.to_int64(args[4]) & 0xFFFFFFFF, sdk.to_int64(args[5]) & 0xFFFFFFFF
            if result >= 0x80000000 then result = result - 0x100000000 end
            if q >= 0x80000000 then q = q - 0x100000000 end
            M.quest_events[#M.quest_events + 1] = { id = os.time() * 1000 + #M.quest_events, q = q, key = key, result = result }
            if #M.quest_events > 50 then table.remove(M.quest_events, 1) end
        end, function(r) return r end)
    end
end

local function quest_active(q)
    local qm = sdk.get_managed_singleton("app.QuestManager")
    local list = qm and qm:get_field("CurrentActiveQuestIDList")
    if not list then return false end
    for i = 0, list:call("get_Count") - 1 do if list:call("get_Item", i) == q then return true end end
    return false
end

local function quest_credit(ev)
    if M.quest_seen[ev.id] then return end
    M.quest_seen[ev.id] = true
    local entry = { id = ev.id, q = ev.q, key = ev.key, result = ev.result, applied = false }
    if M.apply_quests and quest_active(ev.q) then
        applying_quest = true
        local ok = pcall(function()
            sdk.get_managed_singleton("app.QuestManager"):call(QUEST_RESULT, ev.q, ev.key, ev.result)
        end)
        applying_quest = false
        entry.applied = ok
        if ok then M.quest_applied = M.quest_applied + 1 end
    end
    M.quest_ledger[#M.quest_ledger + 1] = entry
    pcall(json.dump_file, "dd2coop_quest_credit.json", M.quest_ledger)
    log.info(string.format("[dd2coop_world] quest do host: %d passo %d resultado %d (%s)", ev.q, ev.key, ev.result,
        entry.applied and "aplicado" or "registrado"))
end

-- vida do proprio personagem (os dois lados publicam): o outro esconde o jogador 2 enquanto
-- este estiver morto e mostra de novo quando voltar (o plugin reposiciona pelo warp)
local function my_vitals()
    local p = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
    if not p then return nil end
    local function b(n) local ok, v = pcall(function() return p:call(n) end); return ok and v == true end
    local carry = false -- agarrando/carregando alguém (diagnóstico do carregar o outro jogador)
    pcall(function() carry = p:call("get_CatchController"):call("get_IsActive") == true end)
    return { t = "vitals", dead = b("get_IsDead") or b("get_IsFallDead"), hp = p:call("get_Hp"), carry = carry }
end

local function publish(peer, host)
    local wm = sdk.get_managed_singleton("app.WeatherManager")
    local d, h, mi = now_time()
    M.seq = M.seq + 1
    local data = { seq = M.seq, mode = M.eco and "eco" or "p2p", peer = peer or "", msgs = {} }
    local v = my_vitals()
    if v then data.msgs[#data.msgs + 1] = v end
    if host then -- so o host manda no mundo
        data.msgs[#data.msgs + 1] = { t = "time", day = d, hour = h, minute = mi }
        data.msgs[#data.msgs + 1] = { t = "weather", w = wm:call("get_NowWeatherEnum") }
        data.msgs[#data.msgs + 1] = { t = "quests", list = M.quest_events }
    end
    pcall(json.dump_file, OUT, data)
end

local function unfix()
    if M.fixed_area == nil then return end
    pcall(function() sdk.get_managed_singleton("app.WeatherManager"):call("unfixAreaWeather", M.fixed_area) end)
    M.fixed_area = nil
end

local function apply(data, follow_world, sender)
    for _, msg in ipairs(type(data.msgs) == "table" and data.msgs or {}) do
        if msg.t == "vitals" then
            -- morte de cada jogador vai para a cópia dele (jogador 2 no puppet, 3 e 4 no extra)
            local X = _G.dd2coop_extra
            local P = _G.dd2coop_p2
            local main = P and P.get_peer and P.get_peer()
            if X and sender and sender ~= main and sender ~= "0" then X.set_dead(sender, msg.dead == true) end
            local s = (not sender or sender == main or sender == "0") and P or nil
            if s and s.remote_dead ~= (msg.dead == true) then
                s.remote_dead = msg.dead == true
                log.info("[dd2coop_world] amigo " .. (s.remote_dead and "morreu: jogador 2 escondido" or "voltou: jogador 2 visivel"))
            end
            if M.remote_carry ~= (msg.carry == true) then
                M.remote_carry = msg.carry == true
                log.info("[dd2coop_world] amigo " .. (M.remote_carry and "agarrou/carrega algo" or "soltou"))
            end
        elseif not follow_world then
            -- host: horario/clima/quests do cliente nao valem aqui
        elseif msg.t == "time" and type(msg.day) == "number" and type(msg.hour) == "number" and type(msg.minute) == "number" then
            local d, h, mi = now_time()
            -- so hora/minuto seguem o host: o dia e do mundo de cada jogador (prazos, comida)
            local diff = (h * 60 + mi) - (msg.hour * 60 + msg.minute)
            if diff > 720 then diff = diff - 1440 elseif diff < -720 then diff = diff + 1440 end
            if math.abs(diff) > TIME_TOLERANCE then
                sdk.get_managed_singleton("app.TimeManager"):call(SET_TIME, msg.hour, msg.minute, d, false)
                M.applied_time = M.applied_time + 1
                log.info(string.format("[dd2coop_world] horario do host: %02d:%02d (diferenca %d min)",
                    msg.hour, msg.minute, diff))
            end
        elseif msg.t == "quests" and type(msg.list) == "table" then
            for _, ev in ipairs(msg.list) do
                if type(ev) == "table" and type(ev.id) == "number" and type(ev.q) == "number" and
                    type(ev.key) == "number" and type(ev.result) == "number" then quest_credit(ev) end
            end
        elseif msg.t == "weather" and NORMAL_WEATHER[msg.w] then
            local wm = sdk.get_managed_singleton("app.WeatherManager")
            if wm:call("get_NowWeatherEnum") ~= msg.w then
                local area = wm:call("get_NowArea")
                wm:call("fixAreaWeather", area, msg.w)      -- a agenda de clima nao desfaz
                wm:call("changeWeatherLook", msg.w, area)   -- troca visivel na hora
                M.fixed_area = area
                M.applied_weather = M.applied_weather + 1
                log.info("[dd2coop_world] clima do host: " .. tostring(msg.w))
            end
        end
    end
end

M.apply, M.unfix = apply, unfix

re.on_pre_application_entry("LateUpdateBehavior", function()
    M.frame = M.frame + 1
    if M.frame % 60 ~= 0 then return end
    local role, peer = session_role()
    -- os dois lados publicam (o cliente tambem precisa registrar o par no plugin, senao
    -- o plugin dele rejeita o que chega do host); so o host leva horario/clima/quests
    if role == "host" or role == "cliente" or M.eco then
        if M.frame % 120 == 0 then pcall(publish, peer, role == "host" or M.eco) end
    end
    if role == "host" or role == "cliente" or M.eco then
        -- um arquivo por jogador; horário/clima/quests só do host (dono do lobby)
        local S = _G.dd2coop_session
        local senders = M.eco and { "0" } or (S and S.peers or {})
        M.last_by = M.last_by or {}
        for _, sid in ipairs(senders) do
            local ok, data = pcall(json.load_file, "dd2coop_bus_in_" .. sid .. ".json")
            if ok and type(data) == "table" and type(data.seq) == "number" and data.seq ~= M.last_by[sid] then
                M.last_by[sid] = data.seq
                M.last_in = data.seq
                local follow = M.eco or (role == "cliente" and S and sid == S.owner)
                local okapply, err = pcall(apply, data, follow, sid)
                if not okapply then M.message = "erro ao aplicar mundo: " .. tostring(err) end
            end
        end
    elseif M.fixed_area ~= nil then
        unfix()
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: mundo do host") then return end
    local role = session_role()
    imgui.text("papel: " .. role .. "  (host publica horario e clima; cliente segue)")
    local ok, d, h, mi = pcall(now_time)
    if ok then imgui.text(string.format("agora: dia %d %02d:%02d", d, h, mi)) end
    imgui.text(string.format("enviados seq=%d  recebido seq=%s  horario aplicado=%d  clima aplicado=%d",
        M.seq, tostring(M.last_in), M.applied_time, M.applied_weather))
    imgui.text(string.format("quests: eventos do host=%d  registrados=%d  aplicados=%d", #M.quest_events, #M.quest_ledger, M.quest_applied))
    local cq, vq = imgui.checkbox("Aplicar credito de quest do host (experimental; so quests ativas)", M.apply_quests)
    if cq then M.apply_quests = vq end
    local c, v = imgui.checkbox("Teste local (eco: publica e aplica neste PC)", M.eco)
    if c then M.eco = v end
    if M.message ~= "" then imgui.text(M.message) end
    imgui.tree_pop()
end)

log.info("[dd2coop_world] mundo do host carregado")
