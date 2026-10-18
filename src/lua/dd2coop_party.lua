-- DD2 Co-op: sem pawns enquanto há outro jogador na sessão ou alguma cópia Arisen no mundo.
-- Com par na sessão: PawnManager.standbyPartyPawn(true, false, true, 0) descarrega os pawns do grupo (o
-- mesmo "esperar" que o jogo usa em quests). Sem par e sem cópia: comebackPartyPawn(posição,
-- rotação) os traz ao lado do jogador. (comebackPartyPawn(false) com os pawns descarregados
-- crashou em InstanceInfoController.autoDestroyCharaInstance.)
-- Jogador + pawns + cópias passam do limite do grupo: criar a cópia com os 3 pawns no mundo
-- crasha logo depois do safeRequestCreateInstance, e trazer os pawns com a cópia ainda viva
-- crashou o amigo em autoDestroyCharaInstance (2026-10-17). Por isso M.away() é exigido antes
-- de criar cópia e os pawns só voltam sem nenhuma cópia.
-- Trazer os pawns com o jogo rodando (comebackPartyPawn com ou sem posição) crasha em
-- InstanceInfoController.autoDestroyCharaInstance, 2 min ou 0,7 s depois de descarregar
-- (amigo e host, 2026-10-17). Só funcionou logo depois de carregar um save: os pawns voltam
-- nos primeiros LOAD_WINDOW s de uma carga (jogador novo no CharacterManager), sem sessão e
-- sem cópia; fora disso ficam descarregados até a próxima carga.
-- A marca dd2coop_party.json {"standby":true} sobrevive a fechar/crashar: na próxima carga
-- sem sessão os pawns voltam.
local M = { frame = 0, standby = false, message = "", loaded_at = nil }
local LOAD_WINDOW = 30
local last_me = nil -- nil: script recém-carregado; false: jogador ausente (carregando); endereço: jogador presente
_G.dd2coop_party = M

local MARK = "dd2coop_party.json"
local STANDBY = "standbyPartyPawn(System.Boolean, System.Boolean, System.Boolean, app.TalkDefine.PawnStandbyAreaType)"
local COMEBACK = "comebackPartyPawn(via.vec3, via.Quaternion)"

do
    local ok, mark = pcall(json.load_file, MARK)
    M.standby = ok and type(mark) == "table" and mark.standby == true
end

local function mark(v)
    M.standby = v
    pcall(json.dump_file, MARK, { standby = v })
end

local function in_game()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    return cm and cm:call("get_ManualPlayer")
end

-- algum pawn (CharaKind 2) ainda na lista de personagens?
local function pawns_in_world()
    local list = sdk.get_managed_singleton("app.CharacterListHolder"):call("getAllCharacters")
    for i = 0, (list and list:call("get_Count") or 0) - 1 do
        local ch = list:call("get_Item", i)
        local ok, kind = pcall(function() return ch:call("get_Context"):call("get_CharaKind") end)
        if ok and kind == 2 then return true end
    end
    return false
end

-- pawns fora do mundo (descarregados ou nenhum no grupo) há AWAY_SETTLE s. IsStandbyUnload fica
-- true na hora do standby, mas os pawns ainda estão sendo desmontados: criar a cópia 5 s depois
-- crashou lendo um objeto já liberado (cabeçalho = 0x3f80000000000000, dado de vetor; 2026-10-17).
local AWAY_SETTLE = 3
function M.away()
    local pm = sdk.get_managed_singleton("app.PawnManager")
    if not pm then return false end
    local gone = (pm:call("get_IsStandbyUnload") or pm:call("get_PartyPawnList"):call("get_Count") == 0)
        and not pawns_in_world()
    if not gone then M.clear_since = nil; return false end
    M.clear_since = M.clear_since or os.clock()
    return os.clock() - M.clear_since >= AWAY_SETTLE
end

local function send_away()
    local pm = sdk.get_managed_singleton("app.PawnManager")
    if not pm or pm:call("get_IsStandby") then return end
    if pm:call("get_PartyPawnList"):call("get_Count") == 0 then return end
    -- 3º argumento true: descarrega na hora (some da CharacterListHolder em ~4 s); com false eles
    -- saem andando e só somem ~85 s depois. (true, true, false) os traz de volta: não usar.
    pm:call(STANDBY, true, false, true, 0)
    mark(true)
    log.info("[dd2coop_party] pawns descarregados")
end
M.send_away = function() M.back_ok = false; return pcall(send_away) end

local function bring_back(me)
    local pm = sdk.get_managed_singleton("app.PawnManager")
    if not pm then return end
    if pm:call("get_IsStandbyUnload") then
        local xf = me:call("get_GameObject"):call("get_Transform")
        pm:call(COMEBACK, xf:call("get_Position"), xf:call("get_Rotation"))
        log.info("[dd2coop_party] pawns de volta")
    end
    mark(false)
end

-- alguma cópia Arisen existe ou está sendo criada?
local function copies_alive()
    local P = _G.dd2coop_p2
    if P and P.state ~= "nenhum" then return true end
    local X = _G.dd2coop_extra
    if X and X.busy then return true end
    for _, s in ipairs(X and X.slots or {}) do
        if s.clone or (s.state and s.state ~= "nenhum") then return true end
    end
    return false
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    M.frame = M.frame + 1
    if M.frame % 60 ~= 0 then return end
    local me = in_game()
    if not me then last_me = false; return end
    -- carga de save: o jogador some (tela de carregamento/título) e volta. Só então os pawns
    -- descarregados por uma sessão anterior podem voltar. Reset de scripts no meio do jogo não
    -- conta (last_me começa nil, não false), nem a cópia tomando o ManualPlayer.
    if last_me == false then
        M.loaded_at, M.back_ok = os.clock(), M.standby
    end
    last_me = me:get_address()
    local S = _G.dd2coop_session
    local ls = S and S.status
    local with_player = ls and (ls.role == "host" or ls.role == "cliente") and S.peer ~= nil
    local in_window = M.loaded_at ~= nil and os.clock() - M.loaded_at < LOAD_WINDOW
    local ok, err
    if with_player or (copies_alive() and not in_window) then
        ok, err = pcall(send_away)
        M.back_ok = false
    elseif copies_alive() then
        ok = true -- logo depois da carga o puppet ainda pode estar com o estado antigo: espera
    elseif M.standby and M.back_ok and in_window then
        ok, err = pcall(bring_back, me)
    else
        ok = true
    end
    if not ok then M.message = "erro nos pawns: " .. tostring(err) end
    pcall(M.away) -- mantém a contagem de "pawns fora há N s" em dia
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: pawns") then return end
    imgui.text(M.standby and "pawns descarregados (voltam ao carregar o save, sem sessao e sem copias)" or "pawns no grupo")
    if M.message ~= "" then imgui.text(M.message) end
    imgui.tree_pop()
end)

log.info("[dd2coop_party] pawns carregado")
