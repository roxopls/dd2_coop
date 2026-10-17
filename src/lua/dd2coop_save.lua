-- DD2 Co-op: escolha do save (vanilla ou co-op).
-- Com o save co-op, o plugin troca "win64_save/" por "win64_coop/" em toda chamada do
-- ISteamRemoteStorage: o jogo le e grava so a copia co-op, e o save vanilla fica intocado.
-- Na primeira vez a copia co-op nasce do vanilla. A tela titulo le os saves logo no inicio,
-- entao a escolha vale a partir do proximo inicio do jogo.
local M = { status = nil, frame = 0 }
_G.dd2coop_save = M

local MODE, STATUS = "dd2coop_save_mode.json", "dd2coop_save_status.json"

local function wanted()
    local ok, m = pcall(json.load_file, MODE)
    return ok and type(m) == "table" and m.coop == true
end
M.want = wanted()

re.on_pre_application_entry("LateUpdateBehavior", function()
    M.frame = M.frame + 1
    if M.frame % 120 ~= 0 then return end
    local ok, s = pcall(json.load_file, STATUS)
    if ok and type(s) == "table" then M.status = s end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("DD2 Co-op: save") then return end
    local s = M.status
    imgui.text("agora: " .. (s and tostring(s.status) or "sem status do plugin"))
    local changed, v = imgui.checkbox("Usar o save co-op (vale no proximo inicio do jogo)", M.want)
    if changed then
        M.want = v
        pcall(json.dump_file, MODE, { coop = v })
    end
    if s and M.want ~= (s.coop == true) then imgui.text("reinicie o jogo para trocar de save") end
    imgui.text("Save co-op: Steam remote\\win64_coop. Save vanilla: win64_save (nao e alterado no modo co-op).")
    imgui.tree_pop()
end)
