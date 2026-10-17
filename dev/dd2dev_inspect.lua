-- DD2 Co-op: inspeção sob demanda (ferramenta de desenvolvimento; NÃO vai no pacote).
-- Instalar à mão em reframework\autorun. O nome não começa com dd2coop_ para o launcher não
-- apagá-lo ao atualizar.
-- A cada ~1 s lê reframework\data\dd2coop_req.json:
--   { "id": <número>, "types": ["app.Tipo", ...], "filter": "padrão lua opcional",
--     "lua": "trecho opcional, executado antes; out(...) escreve uma linha" }
-- Quando o id muda, grava reframework\data\dd2coop_dump.txt com campos e métodos de cada
-- tipo (só os membros cujo nome casa com filter, se houver) e "id=<n> pronto" no fim.

log.info("[dd2coop] inspecao carregada")

local REQ, OUT = "dd2coop_req.json", "dd2coop_dump.txt"
local last_id = nil
local frame = 0

local function tname(t)
    if t == nil then return "?" end
    local ok, n = pcall(function() return t:get_full_name() end)
    return ok and n or "?"
end

local function dump_type(td, out, filter)
    out[#out + 1] = "TYPE " .. tname(td) .. "  : " .. tname(td:get_parent_type())
    for _, f in ipairs(td:get_fields() or {}) do
        local ok, line = pcall(function()
            if filter and not f:get_name():match(filter) then return nil end
            return "  F " .. (f:is_static() and "static " or "") .. tname(f:get_type()) .. " " .. f:get_name()
        end)
        if ok and line then out[#out + 1] = line end
    end
    for _, m in ipairs(td:get_methods() or {}) do
        local ok, line = pcall(function()
            if filter and not m:get_name():match(filter) then return nil end
            local ps = {}
            for _, p in ipairs(m:get_param_types() or {}) do ps[#ps + 1] = tname(p) end
            return "  M " .. (m:is_static() and "static " or "") .. tname(m:get_return_type()) .. " "
                .. m:get_name() .. "(" .. table.concat(ps, ", ") .. ")"
        end)
        if ok and line then out[#out + 1] = line end
    end
end

re.on_frame(function()
    frame = frame + 1
    if frame % 60 ~= 0 then return end
    local ok, req = pcall(json.load_file, REQ)
    if not ok or type(req) ~= "table" or req.id == nil or req.id == last_id then return end
    last_id = req.id
    local out = {}
    -- "lua": trecho executado com uma função out(...) que acrescenta uma linha ao dump
    if type(req.lua) == "string" then
        local env = setmetatable({ out = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            out[#out + 1] = table.concat(parts, " ")
        end }, { __index = _G })
        local chunk, err = load(req.lua, "dd2coop_req", "t", env)
        if chunk then
            local okc, errc = pcall(chunk)
            if not okc then out[#out + 1] = "ERRO " .. tostring(errc) end
        else
            out[#out + 1] = "ERRO DE SINTAXE " .. tostring(err)
        end
        out[#out + 1] = ""
    end
    for _, n in ipairs(req.types or {}) do
        local td = sdk.find_type_definition(n)
        if td then pcall(dump_type, td, out, req.filter) else out[#out + 1] = "NAO ACHADO " .. n end
        out[#out + 1] = ""
    end
    out[#out + 1] = "id=" .. tostring(req.id) .. " pronto"
    pcall(fs.write, OUT, table.concat(out, "\n"))
end)
