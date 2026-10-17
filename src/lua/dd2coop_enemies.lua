-- DD2 Co-op: personagens do mundo (inimigos, NPCs, animais) com autoridade do host, pelo
-- barramento de inimigos do plugin (canal 10).
-- Cada PC gera os inimigos do próprio mundo; o mesmo inimigo é achado nos dois pela chave
-- "variante@ponto de spawn" (GenerateInfo: _ObjectID + _InitialPosition, que vêm dos dados do
-- jogo; o UniqueID dos que vagam é sorteado na hora e não serve).
-- Host: a cada 6 quadros publica os inimigos perto dele { k, x, y, z, hp, d }.
-- Cliente: o inimigo local com a mesma chave segue o host: vida igual à do host, não morre
-- sozinho (IsNoDie) e morre quando o host diz; afastado mais que WARP_DIST, é teleportado.
-- O dano do cliente chega ao host pelo jogador 2 (o host simula os ataques dele), então a vida
-- do host já inclui os golpes dos dois.
-- Formato: dd2coop_enemy_out.json { seq, mode, peer, e = { {k,x,y,z,hp,d}, ... } }.
local M = { frame = 0, seq = 0, last_in = -1, eco = false, sent = 0, matched = 0, unmatched = 0,
    remote = 0, killed = 0, warped = 0, hp_set = 0, message = "" }
_G.dd2coop_enemies = M

local OUT, IN = "dd2coop_enemy_out.json", "dd2coop_enemy_in.json"
local RANGE = 150      -- m: inimigos publicados ao redor do host
local MAX_SEND = 80     -- cidades têm dezenas de NPCs
local WARP_DIST = 4.0  -- m: deriva que o cliente corrige por teleporte
local KILL = "killAndSetDieLoop(app.Character.KillAndSetDieLoopOption)"
local SET_HP = "setHp(System.Single, System.Boolean, System.Int32)"
local WARP = "warp(via.Position, via.Quaternion, app.CharacterWarpOption)"

local keys = {}        -- endereço do Character -> chave (o ponto de spawn não muda)
local nodie = {}       -- endereço -> Character em que o cliente ligou IsNoDie
local last_warp = {}   -- endereço -> quadro do último teleporte (no máx. 1 por segundo cada)

local function session()
    local S = _G.dd2coop_session
    local ls = S and S.status
    local peers = S and S.peers and #S.peers > 0 and table.concat(S.peers, ",") or (S and S.peer)
    return ls and ls.role or "nenhum", peers, S and S.owner
end

local function key_of(ch, cl)
    local a = ch:get_address()
    local k = keys[a]
    if k then return k end
    local ok, r = pcall(function()
        local id = ch:call("get_CharaID")
        if cl and cl:call("isUniqueCharacter(app.CharacterID)", id) then return "U:" .. tostring(id) end
        local c = ch:call("get_GenerateInfo"):call("get_Container"):call("get_CommonInfo")
        local p = c:get_field("_InitialPosition")
        return string.format("%s@%d,%d,%d", tostring(c:get_field("_ObjectID"):call("ToString")),
            math.floor(p.x * 2 + 0.5), math.floor(p.y * 2 + 0.5), math.floor(p.z * 2 + 0.5))
    end)
    k = ok and r or false
    keys[a] = k
    return k
end

-- todos os personagens do mundo menos Arisen (jogadores e jogador 2) e pawns (não existem com
-- jogadores na sessão): NPCs, monstros e animais. NPC único (com nome) pela CharacterID; os
-- demais pelo ponto de spawn. { ch, k }: vários do mesmo ponto (bando) levam #2, #3... na ordem
-- da lista.
local SKIP_KIND = { [0] = true, [1] = true, [2] = true, [32] = true }
local function enemies()
    local cl = sdk.get_managed_singleton("app.CharacterListHolder")
    local list = cl and cl:call("getAllCharacters")
    local out, seen = {}, {}
    if not list then return out end
    for i = 0, list:call("get_Count") - 1 do
        local ch = list:call("get_Item", i)
        local okk, kind = pcall(function() return ch:call("get_Context"):call("get_CharaKind") end)
        if ch and okk and not SKIP_KIND[kind] then
            local k = key_of(ch, cl)
            if k then
                seen[k] = (seen[k] or 0) + 1
                if seen[k] > 1 then k = k .. "#" .. seen[k] end
            end
            out[#out + 1] = { ch = ch, k = k }
        end
    end
    return out
end

local function upos(ch)
    return ch:call("get_GameObject"):call("get_Transform"):call("get_UniversalPosition")
end

local function publish(peer)
    local me = sdk.get_managed_singleton("app.CharacterManager"):call("get_ManualPlayer")
    if not me then return end
    local mp = upos(me)
    local list = {}
    for _, en in ipairs(enemies()) do
        local ch, k = en.ch, en.k
        if k then
            local ok = pcall(function()
                local p = upos(ch)
                local dx, dy, dz = p.x - mp.x, p.y - mp.y, p.z - mp.z
                if dx * dx + dy * dy + dz * dz > RANGE * RANGE then return end
                local hit = ch:call("get_Hit")
                list[#list + 1] = { k = k, x = p.x, y = p.y, z = p.z, hp = hit:call("get_Hp"),
                    d = ch:call("get_IsDead") or hit:call("get_IsDie") or nil }
            end)
            if not ok then keys[ch:get_address()] = nil end
            if #list >= MAX_SEND then break end
        end
    end
    M.seq = M.seq + 1
    M.sent = #list
    pcall(json.dump_file, OUT, { seq = M.seq, mode = M.eco and "eco" or "p2p", peer = peer or "", e = list })
end

local function follow(ch, s)
    local hit = ch:call("get_Hit")
    local a = ch:get_address()
    if ch:call("get_IsDead") or hit:call("get_IsDie") then return end
    if s.d then
        if nodie[a] then hit:call("set_IsNoDie", false); nodie[a] = nil end
        ch:call(KILL, nil)
        M.killed = M.killed + 1
        return
    end
    if not nodie[a] then hit:call("set_IsNoDie", true); nodie[a] = ch end
    if type(s.hp) == "number" and s.hp > 0 and math.abs(hit:call("get_Hp") - s.hp) > 0.5 then
        hit:call(SET_HP, s.hp, false, 0)
        M.hp_set = M.hp_set + 1
    end
    if type(s.x) == "number" and type(s.y) == "number" and type(s.z) == "number" then
        local xf = ch:call("get_GameObject"):call("get_Transform")
        local p = xf:call("get_UniversalPosition")
        local dx, dy, dz = p.x - s.x, p.y - s.y, p.z - s.z
        if dx * dx + dy * dy + dz * dz > WARP_DIST * WARP_DIST and M.frame - (last_warp[a] or -1000) >= 60 then
            last_warp[a] = M.frame
            local np = ValueType.new(sdk.find_type_definition("via.Position"))
            np:set_field("x", s.x); np:set_field("y", s.y); np:set_field("z", s.z)
            ch:call(WARP, np, xf:call("get_Rotation"), nil)
            M.warped = M.warped + 1
        end
    end
end

local function apply(data)
    if type(data.e) ~= "table" then return end
    local by_key = {}
    for _, s in ipairs(data.e) do
        if type(s) == "table" and type(s.k) == "string" then by_key[s.k] = s end
    end
    M.remote = #data.e
    local matched, unmatched = 0, 0
    for _, en in ipairs(enemies()) do
        local ch, k = en.ch, en.k
        local s = k and by_key[k]
        if s then
            matched = matched + 1
            local ok, err = pcall(follow, ch, s)
            if not ok then M.message = "erro ao seguir inimigo: " .. tostring(err) end
        else
            unmatched = unmatched + 1
        end
    end
    M.matched, M.unmatched = matched, unmatched
end

-- fim da sessão: os inimigos voltam a poder morrer sozinhos
local function release()
    for a, ch in pairs(nodie) do
        pcall(function() ch:call("get_Hit"):call("set_IsNoDie", false) end)
        nodie[a] = nil
    end
end
M.release = release
M.apply, M.publish, M.key_of, M.enemies = apply, publish, key_of, enemies

re.on_pre_application_entry("LateUpdateBehavior", function()
    M.frame = M.frame + 1
    if M.frame % 6 ~= 0 then return end
    if M.frame % 600 == 0 then keys, last_warp = {}, {} end -- inimigos descarregados liberam o endereço
    local role, peer, owner = session()
    local host = role == "host" and peer ~= nil
    local client = (role == "cliente" and owner ~= nil) or M.eco
    if host or M.eco then pcall(publish, peer) end
    if client then
        -- só o estado do host vale (arquivo do remetente = dono do lobby; eco: 0)
        local ok, data = pcall(json.load_file, "dd2coop_enemy_in_" .. (M.eco and "0" or owner) .. ".json")
        if ok and type(data) == "table" and type(data.seq) == "number" and data.seq ~= M.last_in then
            M.last_in = data.seq
            local okapply, err = pcall(apply, data)
            if not okapply then M.message = "erro ao aplicar inimigos: " .. tostring(err) end
        end
    elseif next(nodie) then
        release()
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: personagens do host (inimigos, NPCs)") then return end
    imgui.text("papel: " .. session() .. "  (host publica; cliente segue)")
    imgui.text(string.format("publicados=%d  recebidos=%d  casados=%d  sem par=%d", M.sent, M.remote, M.matched, M.unmatched))
    imgui.text(string.format("mortes aplicadas=%d  teleportes=%d  vida acertada=%d", M.killed, M.warped, M.hp_set))
    local c, v = imgui.checkbox("Teste local (eco: publica e aplica neste PC)", M.eco)
    if c then M.eco = v; if not v then release() end end
    if M.message ~= "" then imgui.text(M.message) end
    imgui.tree_pop()
end)

log.info("[dd2coop_enemies] inimigos do host carregado")
