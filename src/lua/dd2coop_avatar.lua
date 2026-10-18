-- DD2 Co-op: aparencia completa (avatar) aplicada ANTES da primeira montagem da copia.
-- Exporta os cinco contextos de edicao do original (MetaData, corpo, Pretender, rosto e
-- BodyDetail) para reframework/data/dd2coop_avatar.json. Com "aplicar na proxima criacao"
-- ligado, o pre-hook de CharacterEditManager.requestBuildFromContext escreve o arquivo
-- nos contextos da copia que esta nascendo (estado "gerando", GameObject diferente do
-- original), uma unica vez. Valores de corpo/rosto vao para os EditValue que a copia ja tem,
-- por setEditValue do jogo (nenhum objeto criado); nenhum objeto do original e escrito (a
-- aplicacao aborta antes de escrever se algum alvo pertencer ao original). Tatuagens/cicatrizes: os 10 SlotData de cada sao escritos
-- no lugar, nos slots da propria copia.
local M = { version = 1, armed = false, message = "", last = nil, verify = nil, frame = 0 }
_G.dd2coop_avatar = M

local FILE, LOG = "dd2coop_avatar.json", "dd2coop_avatar_log.txt"
local EDIT_T = "app.CharacterEditDefine.EditValue"
-- estado de edicao/UI, nao aparencia (o slider de escala e um objeto do editor)
local SKIP = { ["<IsStore>k__BackingField"] = true, RestoredType = true,
    ["<ScaleSlider>k__BackingField"] = true, ["<EditMode>k__BackingField"] = true,
    ["<HasPropertyChanged>k__BackingField"] = true, ["<HasStyleChanged>k__BackingField"] = true }
local CONTEXTS = { "human", "body", "pretender", "face", "detail" }
-- ordem dos contextos nos parametros 2..6 de requestBuildFromContext
local BUILD_ORDER = { "human", "body", "face", "detail", "pretender" }
local log_lines = {}

local function note(line)
    log_lines[#log_lines + 1] = os.date("%H:%M:%S ") .. line
    if #log_lines > 200 then table.remove(log_lines, 1) end
    pcall(fs.write, LOG, table.concat(log_lines, "\n"))
    log.info("[dd2coop_avatar] " .. line)
end

local function tname(td) return td and td:get_full_name() or "?" end

-- campos de instancia do tipo e dos pais (sem System.Object)
local function fields_of(td)
    local list = {}
    while td and tname(td) ~= "System.Object" do
        for _, f in ipairs(td:get_fields() or {}) do
            if not f:is_static() and not SKIP[f:get_name()] then list[#list + 1] = f end
        end
        td = td:get_parent_type()
    end
    return list
end

local function find_field(td, name)
    for _, f in ipairs(fields_of(td)) do if f:get_name() == name then return f end end
end

local function is_scalar(ft)
    if ft:is_enum() then return true end
    local n = tname(ft)
    return n == "System.Single" or n == "System.Boolean" or n == "System.Byte" or n == "System.SByte"
        or n == "System.UInt16" or n == "System.Int16" or n == "System.UInt32" or n == "System.Int32"
end

-- contextos de um personagem
local function contexts_of(ch)
    local sw = ch:call("get_HumanPartSwapper")
    local be, fe = sw:get_field("_BodyEditor"), sw:get_field("_FaceEditor")
    local bd = sw:get_field("<BodyDetailEditor>k__BackingField")
    return { human = sw:get_field("_HumanContext"), body = be:get_field("_BodyEditContext"),
        pretender = be:get_field("_PretenderContext"), face = fe:get_field("_Context"),
        detail = bd:get_field("_Context") }
end

-- captura -----------------------------------------------------------------------------

local function capture_node(o, depth)
    local td = o:get_type_definition()
    local node = { t = tname(td), f = {} }
    for _, f in ipairs(fields_of(td)) do
        local name, ft = f:get_name(), f:get_type()
        local fn = tname(ft)
        if is_scalar(ft) then
            local v = o:get_field(name)
            if type(v) == "boolean" then node.f[name] = v else node.f[name] = tonumber(v) end
        elseif fn == "via.Color" then
            node.f[name] = { c = o:read_dword(f:get_offset_from_base()) }
        elseif fn == EDIT_T .. "[]" then
            local arr, list = o:get_field(name), {}
            for i = 0, (arr and arr:call("get_Length") or 0) - 1 do
                local e = arr:call("Get", i)
                if e then list[#list + 1] = { e:get_field("_EditKeyHash"), e:get_field("_Value") } end
            end
            node.f[name] = { e = list }
        elseif fn:sub(-2) == "[]" and depth < 6 then
            -- arrays de objetos (SlotData de tatuagens/cicatrizes): um no por elemento
            local arr, list = o:get_field(name), {}
            for i = 0, (arr and arr:call("get_Length") or 0) - 1 do
                local e = arr:call("Get", i)
                list[#list + 1] = e and capture_node(e, depth + 1) or false
            end
            node.f[name] = { a = list }
        elseif not ft:is_value_type() and depth < 6 then
            local v = o:get_field(name)
            if v then node.f[name] = capture_node(v, depth + 1) end
        end
    end
    return node
end

function M.capture(ch)
    local ctx, out = contexts_of(ch), {}
    for _, k in ipairs(CONTEXTS) do
        if not ctx[k] then return nil, "contexto ausente: " .. k end
        out[k] = capture_node(ctx[k], 0)
    end
    return out
end

function M.validate(raw)
    if type(raw) ~= "table" or raw.kind ~= "dd2coop_avatar" or raw.version ~= 1 or type(raw.contexts) ~= "table" then
        return nil, "arquivo de avatar ausente ou de versao desconhecida"
    end
    for _, k in ipairs(CONTEXTS) do
        local n = raw.contexts[k]
        if type(n) ~= "table" or type(n.t) ~= "string" or type(n.f) ~= "table" then return nil, "contexto invalido: " .. k end
    end
    return raw
end

function M.export(ch, label)
    local contexts, err = M.capture(ch)
    if not contexts then M.message = err; return false end
    local data = { kind = "dd2coop_avatar", version = 1, source = label, contexts = contexts }
    local ok, result = pcall(json.dump_file, FILE, data)
    M.message = ok and result ~= false and "aparencia completa gravada em " .. FILE or "falha ao gravar " .. FILE
    note(M.message)
    return ok and result ~= false
end

function M.load()
    local ok, raw = pcall(json.load_file, FILE)
    return M.validate(ok and raw or nil)
end

-- aplicacao ---------------------------------------------------------------------------

-- enderecos de todos os objetos alcancaveis a partir dos contextos do original
local function collect(o, set, depth)
    if not o or depth > 8 then return end
    local a = o:get_address()
    if set[a] then return end
    set[a] = true
    for _, f in ipairs(fields_of(o:get_type_definition())) do
        local ft = f:get_type()
        if not ft:is_value_type() then
            local ok, v = pcall(function() return o:get_field(f:get_name()) end)
            if ok and type(v) == "userdata" and v.get_address then
                if tname(ft):sub(-2) == "[]" then
                    set[v:get_address()] = true
                    for i = 0, v:call("get_Length") - 1 do
                        local e = v:call("Get", i)
                        if type(e) == "userdata" and e.get_address then set[e:get_address()] = true end
                    end
                else collect(v, set, depth + 1) end
            end
        end
    end
end

-- o arquivo pode vir do amigo: so numeros finitos e inteiros de 32 bits onde cabem
local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function uint32(v) return finite(v) and v % 1 == 0 and v >= 0 and v <= 4294967295 end

-- fase 1: confere tipos, valores e independencia e monta a lista de escritas, sem escrever nada
local function plan(o, node, ops, foreign, path)
    if select(2, path:gsub("%.", "")) > 8 then return false, path .. ": aninhamento demais" end
    if type(node) ~= "table" or type(node.t) ~= "string" then return false, path .. ": no invalido" end
    if foreign[o:get_address()] then return false, path .. ": objeto pertence ao original" end
    local td = o:get_type_definition()
    if tname(td) ~= node.t then return false, path .. ": tipo " .. tname(td) .. " ~= " .. node.t end
    for name, v in pairs(node.f or {}) do
        local f = find_field(td, name)
        if not f then return false, path .. "." .. name .. ": campo inexistente" end
        local ft = f:get_type()
        if type(v) ~= "table" then
            if not is_scalar(ft) then return false, path .. "." .. name .. ": nao e escalar" end
            if type(v) == "number" and not finite(v) then return false, path .. "." .. name .. ": numero invalido" end
            if type(v) ~= "number" and type(v) ~= "boolean" then return false, path .. "." .. name .. ": valor invalido" end
            ops[#ops + 1] = { kind = "scalar", o = o, name = name, v = v }
        elseif v.c then
            if tname(ft) ~= "via.Color" then return false, path .. "." .. name .. ": nao e cor" end
            if not uint32(v.c) then return false, path .. "." .. name .. ": cor invalida" end
            ops[#ops + 1] = { kind = "color", o = o, off = f:get_offset_from_base(), v = v.c }
        elseif v.e then
            if tname(ft) ~= EDIT_T .. "[]" then return false, path .. "." .. name .. ": nao e EditValue[]" end
            if type(v.e) ~= "table" or #v.e > 512 then return false, path .. "." .. name .. ": lista invalida" end
            for _, kv in ipairs(v.e) do
                if type(kv) ~= "table" or not uint32(kv[1]) or not finite(kv[2]) or math.abs(kv[2]) > 1e6 then
                    return false, path .. "." .. name .. ": EditValue invalido"
                end
            end
            -- valores gravados no array que a cópia já tem, por setEditValue(hash, valor) do jogo; ele
            -- não pode ser do original (mudaria a aparência dele)
            if not td:get_method("setEditValue") then return false, path .. "." .. name .. ": sem setEditValue" end
            local cur = o:get_field(name)
            if not cur then return false, path .. "." .. name .. ": nulo na copia" end
            if foreign[cur:get_address()] then return false, path .. "." .. name .. ": array pertence ao original" end
            for i = 0, cur:call("get_Length") - 1 do
                local e = cur:call("Get", i)
                if e and foreign[e:get_address()] then return false, path .. "." .. name .. ": EditValue pertence ao original" end
            end
            ops[#ops + 1] = { kind = "edit", o = o, name = name, v = v.e, path = path .. "." .. name }
        elseif v.a then
            -- slots da propria copia, escritos no lugar; o tamanho tem de bater
            if tname(ft):sub(-2) ~= "[]" or type(v.a) ~= "table" then return false, path .. "." .. name .. ": nao e array" end
            local arr = o:get_field(name)
            local n = arr and arr:call("get_Length") or 0
            if n ~= #v.a then return false, path .. "." .. name .. ": tamanho " .. n .. " ~= " .. #v.a end
            for i, item in ipairs(v.a) do
                local e = arr:call("Get", i - 1)
                if item and not e then return false, path .. "." .. name .. "[" .. (i - 1) .. "]: nulo na copia" end
                if item and e then
                    local ok, why = plan(e, item, ops, foreign, path .. "." .. name .. "[" .. (i - 1) .. "]")
                    if not ok then return false, why end
                end
            end
        else
            local child = o:get_field(name)
            if not child then return false, path .. "." .. name .. ": nulo na copia" end
            local ok, why = plan(child, v, ops, foreign, path .. "." .. name)
            if not ok then return false, why end
        end
    end
    return true
end

local function apply_ops(ops)
    local n = 0
    for _, op in ipairs(ops) do
        if op.kind == "scalar" then op.o:set_field(op.name, op.v)
        elseif op.kind == "color" then op.o:write_dword(op.off, op.v)
        else
            -- NUNCA criar objetos (create_instance/create_managed_array) para a cópia: array e
            -- EditValue novos, gravados por set_field ou por set_EditValues, faziam o coletor do jogo
            -- achar objeto liberado ~1 s depois (DD2.exe+0x524feb4/+0x5236168/+0x52345ae, 2026-10-17)
            for _, kv in ipairs(op.v) do op.o:call("setEditValue", kv[1], kv[2]) end
        end
        n = n + 1
    end
    return n
end

-- MetaData do avatar (estilos de corpo e roupa) no contexto de montagem: clone da MetaData
-- (objeto novo do próprio jogo) com os valores do avatar, entregue com set_Meta. Gravar dentro
-- da MetaData que já estava no contexto fazia o jogo crashar ao criar a cópia ou ao abrir o
-- menu (coletor do jogo, 2026-10-18); HumanPartSwapper.restore depois da montagem só troca a
-- roupa (cabelo, pele e gênero ficavam os genéricos).
local function plan_meta(ctx, human)
    local mf = human and human.f and human.f._Meta and human.f._Meta.f
    if type(mf) ~= "table" then return nil, "human._Meta ausente" end
    local td = sdk.find_type_definition("app.CharacterEditDefine.MetaData")
    local values = {}
    for name, v in pairs(mf) do
        local f = find_field(td, name)
        if not f or not is_scalar(f:get_type()) then return nil, "human._Meta." .. name .. ": campo invalido" end
        if not uint32(v) then return nil, "human._Meta." .. name .. ": valor invalido" end
        values[name] = v
    end
    if not ctx:get_type_definition():get_method("set_Meta") then return nil, "PartSwapHumanContext sem set_Meta" end
    return values
end

local function apply_meta(ctx, values)
    local old = ctx:call("get_Meta")
    local det = old:call("clone")
    if not det then error("clone da MetaData falhou") end
    -- a montagem pode já ter guardado o ponteiro da MetaData antiga sem contar referência: depois
    -- do set_Meta ela era liberada e a montagem usava o objeto morto ~1 s depois (crash em
    -- DD2.exe+0x524feb4 em parte das criações, 2026-10-18). Fica viva para sempre (um objeto
    -- pequeno por cópia criada).
    if old.add_ref_permanent then old:add_ref_permanent() else old:add_ref() end
    det:add_ref()
    local ok, err = pcall(function()
        for name, v in pairs(values) do det:set_field(name, v) end
        ctx:call("set_Meta", det)
    end)
    det:release()
    if not ok then error(err) end
end

-- contexts: tabela human/body/pretender/face/detail da copia; original: app.Character
function M.apply_to(contexts, original, data)
    local foreign = {}
    for _, c in pairs(contexts_of(original)) do collect(c, foreign, 0) end
    local ops = {}
    for _, k in ipairs(CONTEXTS) do
        if not contexts[k] then return false, "contexto da copia ausente: " .. k end
        -- human (MetaData) não passa pelo plan: vai inteira por plan_meta/apply_meta
        if k ~= "human" then
            local ok, why = plan(contexts[k], data.contexts[k], ops, foreign, k)
            if not ok then return false, why end
        end
    end
    local meta, why = plan_meta(contexts.human, data.contexts.human)
    if not meta then return false, why end
    local n = apply_ops(ops)
    apply_meta(contexts.human, meta)
    for _ in pairs(meta) do n = n + 1 end
    return true, n
end

-- diferencas entre o arquivo e um personagem vivo (campos escalares, cores e EditValues)
local function diff(a, b, path, out)
    for name, v in pairs(a.f or {}) do
        local w = b and b.f and b.f[name]
        local p = path .. "." .. name
        if type(v) ~= "table" then
            if type(v) == "number" and type(w) == "number" then
                if math.abs(v - w) > 1e-4 then out[#out + 1] = p end
            elseif v ~= w then out[#out + 1] = p end
        elseif v.c then if not w or w.c ~= v.c then out[#out + 1] = p end
        elseif v.e then
            local got = {}
            for _, kv in ipairs(w and w.e or {}) do got[kv[1]] = kv[2] end
            for _, kv in ipairs(v.e) do
                if got[kv[1]] == nil or math.abs(got[kv[1]] - kv[2]) > 1e-4 then out[#out + 1] = p .. "[" .. kv[1] .. "]" end
            end
        elseif v.a then
            for i, item in ipairs(v.a) do
                local other = w and w.a and w.a[i]
                if item and other then diff(item, other, p .. "[" .. (i - 1) .. "]", out)
                elseif item ~= other then out[#out + 1] = p .. "[" .. (i - 1) .. "]" end
            end
        else diff(v, w, p, out) end
    end
end

-- EditValues da copia que sao os mesmos objetos do original
local function shared_entries(clone, original)
    local foreign, mine, n = {}, {}, 0
    for _, c in pairs(contexts_of(original)) do collect(c, foreign, 0) end
    for _, c in pairs(contexts_of(clone)) do collect(c, mine, 0) end
    for a in pairs(mine) do if foreign[a] then n = n + 1 end end
    return n
end

function M.check(clone, original, data)
    if not data then return nil, "sem avatar aplicado" end
    local now = M.capture(clone)
    local out = {}
    for _, k in ipairs(CONTEXTS) do diff(data.contexts[k], now[k], k, out) end
    return { differences = #out, sample = table.concat(out, " ", 1, math.min(#out, 8)),
        shared = shared_entries(clone, original) }
end

-- perfil do amigo pela Steam --------------------------------------------------------------
-- Pacote: { kind = "dd2coop_bundle", version = 1, avatar = <avatar>, profile = <perfil v2> }.
-- O plugin envia dd2coop_profile_out.json e grava o recebido em dd2coop_peer_profile.json.

M.source = "own"     -- "own": dd2coop_avatar.json | "peer": avatar recebido do amigo
M.peer = nil         -- pacote recebido e validado
M.net_message = ""
M.send_mode = 1      -- 1 eco (teste local), 2 p2p
local SEND_MODES = { "eco (teste neste PC)", "p2p (amigo)" }
local last_rx_hash

local function settings_peer()
    local ok, s = pcall(json.load_file, "dd2coop_settings.json")
    return ok and type(s) == "table" and type(s.peer) == "string" and s.peer or ""
end

function M.validate_bundle(raw)
    if type(raw) ~= "table" or raw.kind ~= "dd2coop_bundle" or raw.version ~= 1 then
        return nil, "pacote de perfil de versao desconhecida"
    end
    local avatar, why = M.validate(raw.avatar)
    if not avatar then return nil, why end
    local profile
    if raw.profile ~= nil and _G.dd2coop_profiles then
        profile, why = _G.dd2coop_profiles.validate(raw.profile)
        if not profile then return nil, "vocacao/armas: " .. tostring(why) end
    end
    return { avatar = avatar, profile = profile }
end

function M.send_profile()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    local s = _G.dd2coop_p2
    local ch = s and s.orig or (cm and cm:call("get_ManualPlayer"))
    if not ch then M.net_message = "sem player"; return false end
    local contexts, err = M.capture(ch)
    if not contexts then M.net_message = err; return false end
    local bundle = { kind = "dd2coop_bundle", version = 1,
        avatar = { kind = "dd2coop_avatar", version = 1, source = "remoto", contexts = contexts } }
    local profiles = _G.dd2coop_profiles
    if profiles then
        local p = profiles.validate(profiles.capture(ch))
        if p then bundle.profile = p end
    end
    -- sessão com vários jogadores: manda para todos de uma vez (o plugin confirma um a um)
    local S = _G.dd2coop_session
    local peer = S and S.peers and #S.peers > 0 and table.concat(S.peers, ",") or settings_peer()
    if M.send_mode == 2 and peer == "" then M.net_message = "preencha o SteamID64 do amigo no painel do jogador 2"; return false end
    local ok, result = pcall(json.dump_file, "dd2coop_profile_out.json", bundle)
    if not ok or result == false then M.net_message = "falha ao gravar dd2coop_profile_out.json"; return false end
    local req = { id = math.floor(os.time() * 1000 + (os.clock() * 1000) % 1000),
        mode = M.send_mode == 1 and "eco" or "p2p", peer = peer, peers = peer }
    ok, result = pcall(json.dump_file, "dd2coop_profile_req.json", req)
    M.net_message = ok and result ~= false and "perfil enviado; aguardando confirmacao" or "falha ao pedir envio"
    note(M.net_message .. " (" .. req.mode .. ")")
    return true
end

-- perfis por jogador: dd2coop_peer_profile_<SteamID>.json (o plugin grava um por remetente)
M.peers = {}
local function load_peer(sid)
    local ok, raw = pcall(json.load_file, "dd2coop_peer_profile_" .. sid .. ".json")
    if not ok or raw == nil then return end
    local bundle, why = M.validate_bundle(raw)
    if bundle then M.peers[sid] = bundle else note("perfil de " .. sid .. " invalido: " .. tostring(why)) end
end
function M.peer_bundle(sid) return sid and M.peers[sid] or nil end

local function poll_peer(status)
    if not status or status.prof_rx_hash == nil or status.prof_rx_hash == 0 or status.prof_rx_hash == last_rx_hash then return end
    last_rx_hash = status.prof_rx_hash
    local S = _G.dd2coop_session
    for _, sid in ipairs(S and S.peers or {}) do pcall(load_peer, sid) end
    -- jogador 2 (puppet): o perfil do par dele; sem sessão, o último recebido (formato de um par)
    local p2 = _G.dd2coop_p2
    local main = p2 and p2.get_peer and p2.get_peer()
    local bundle, why = main and M.peers[main], nil
    if not bundle then
        local ok, raw = pcall(json.load_file, "dd2coop_peer_profile.json")
        bundle, why = M.validate_bundle(ok and raw or nil)
    end
    if not bundle then M.peer = nil; M.net_message = "perfil recebido invalido: " .. tostring(why); note(M.net_message); return end
    M.peer = bundle
    local voc = bundle.profile and bundle.profile.vocation
    M.net_message = "perfil do amigo recebido" .. (voc and (" (vocacao " .. tostring(voc) .. ")") or "")
    note(M.net_message)
end

function M.source_data()
    if M.source == "peer" then
        if not M.peer then return nil, "nenhum perfil do amigo recebido" end
        return M.peer.avatar
    end
    return M.load()
end

-- hook da primeira montagem -----------------------------------------------------------

local build_m
for _, m in ipairs(sdk.find_type_definition("app.CharacterEditManager"):get_methods()) do
    if m:get_name() == "requestBuildFromContext" and m:get_num_params() == 9 then build_m = m end
end

if build_m then
    sdk.hook(build_m, function(args)
        local job = M.next_build -- cópia extra (dd2coop_extra): avatar do jogador dela
        if job then
            local okj, errj = pcall(function()
                local go = sdk.to_managed_object(args[3])
                if not go or go:call("get_Name") ~= "ch000000_00" then return end
                if job.skip and job.skip[go:get_address()] then return end
                M.next_build = nil
                local contexts = {}
                for i, k in ipairs(BUILD_ORDER) do contexts[k] = sdk.to_managed_object(args[3 + i]) end
                local applied, result = M.apply_to(contexts, job.original, job.data)
                note(string.format("copia extra: avatar %s (%s, go=0x%X)", applied and "aplicado" or "NAO aplicado",
                    tostring(result), go:get_address()))
                if job.done then job.done(applied, go) end
            end)
            if not okj then M.next_build = nil; note("erro no avatar da copia extra: " .. tostring(errj)) end
            return
        end
        if not M.armed then return end
        local s = _G.dd2coop_p2
        if not s or s.state ~= "gerando" or not s.orig then return end
        local ok, err = pcall(function()
            local go = sdk.to_managed_object(args[3])
            if not go or go:call("get_Name") ~= "ch000000_00" then return end
            if go:get_address() == s.orig:call("get_GameObject"):get_address() then return end
            M.armed = false -- uma unica tentativa por criacao, com ou sem sucesso
            local data, why = M.source_data()
            if not data then M.message = why; note("montagem sem avatar: " .. why); return end
            local contexts = {}
            for i, k in ipairs(BUILD_ORDER) do contexts[k] = sdk.to_managed_object(args[3 + i]) end
            local applied, result = M.apply_to(contexts, s.orig, data)
            if applied then
                s.avatar_applied = true
                M.applied = { data = data, profile = M.source == "peer" and M.peer and M.peer.profile or nil }
                M.message = "avatar " .. (M.source == "peer" and "do amigo" or "proprio") ..
                    " aplicado antes da montagem: " .. result .. " escritas"
            else
                M.message = "avatar NAO aplicado: " .. tostring(result)
            end
            note(string.format("%s (go=0x%X)", M.message, go:get_address()))
        end)
        if not ok then M.armed = false; M.message = "erro ao aplicar avatar: " .. tostring(err); note(M.message) end
    end, function(ret) return ret end)
end

-- copia pronta: confere o avatar e, com perfil do amigo, prepara vocacao e armas dele
local checked_clone
re.on_pre_application_entry("LateUpdateBehavior", function()
    M.frame = M.frame + 1
    if M.frame % 60 ~= 0 then return end
    local s = _G.dd2coop_p2
    pcall(poll_peer, s and s.net_status)
    if not (s and s.state == "pronto" and s.clone and s.avatar_applied and M.applied) then return end
    local a = s.clone:get_address()
    if a == checked_clone then return end
    checked_clone = a
    local ok, r = pcall(M.check, s.clone, s.orig, M.applied.data)
    M.verify = ok and r or { error = tostring(r) }
    if ok and r then
        note(string.format("copia pronta: diferencas=%d compartilhados=%d %s", r.differences, r.shared, r.sample))
    else note("verificacao falhou: " .. tostring(r)) end
    local profile = M.applied.profile
    if profile and _G.dd2coop_loadout and _G.dd2coop_profiles then
        _G.dd2coop_profiles.imported = profile
        local started = _G.dd2coop_loadout.apply(profile)
        note("vocacao/armas do amigo: " .. (started and "preparacao iniciada" or tostring(_G.dd2coop_loadout.message)))
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: aparencia completa (avatar)") then return end
    if not build_m then imgui.text("requestBuildFromContext nao encontrado"); imgui.tree_pop(); return end
    local s = _G.dd2coop_p2
    if imgui.button("Exportar aparencia completa do original") then
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local ch = s and s.orig or (cm and cm:call("get_ManualPlayer"))
        if ch then pcall(M.export, ch, "original") else M.message = "sem player" end
    end
    imgui.text("Perfil pela Steam (aparencia + vocacao/armas):")
    local cm_, mode = imgui.combo("Envio", M.send_mode, SEND_MODES)
    if cm_ then M.send_mode = mode end
    if imgui.button("Enviar meu perfil") then pcall(M.send_profile) end
    local st_ = s and s.net_status
    if st_ and st_.prof_req ~= nil then
        imgui.text(string.format("perfil: enviados=%s confirmado=%s recebidos=%s rejeitados=%s %s",
            tostring(st_.prof_sent), tostring(st_.prof_acked), tostring(st_.prof_received),
            tostring(st_.prof_rejected), tostring(st_.prof_error or "")))
    end
    if M.net_message ~= "" then imgui.text(M.net_message) end
    local sources = { "meu dd2coop_avatar.json", "perfil recebido do amigo" }
    local cs, si = imgui.combo("Aparencia do jogador 2", M.source == "peer" and 2 or 1, sources)
    if cs then M.source = si == 2 and "peer" or "own" end
    local changed, v = imgui.checkbox("Aplicar na proxima criacao do jogador 2", M.armed)
    if changed then
        local data, why = M.source_data()
        M.armed = v and data ~= nil
        if v and not M.armed then M.message = tostring(why) end
    end
    imgui.text("Corpo, rosto, proporcoes, pele, cabelo, olhos, maquiagem e roupa. Inclui tatuagens e cicatrizes.")
    if M.message ~= "" then imgui.text(M.message) end
    if M.verify then
        imgui.text(M.verify.error or string.format("conferencia: diferencas=%d  objetos compartilhados com o original=%d",
            M.verify.differences, M.verify.shared))
    end
    imgui.tree_pop()
end)

note("avatar carregado; hook=" .. tostring(build_m ~= nil))
