from pathlib import Path
import sys
import unittest
ROOT = Path(__file__).parent
if ROOT.name == 'tests': ROOT = ROOT.parent
sys.path.insert(0, str(ROOT / 'vendor'))
from lupa.lua54 import LuaRuntime

MOCKS = r'''
files, callbacks, hooks = {}, {}, {}
dd2coop_party = {away=function() return true end, send_away=function() end}
files.dd2coop_net_status_json = nil
files['dd2coop_net_status.json'] = { instance = 'game1', lua_epoch = 0, save_hooks = 6, me = '76561198000000001' }
local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}; for k, value in pairs(v) do out[k] = copy(value) end; return out
end
json = { load_file = function(path) return copy(files[path]) end,
    dump_file = function(path, data) files[path] = copy(data); return true end }
log = { info = function() end, error = function() end }
imgui = { tree_node = function() return false end }
thread = { get_hook_storage = function() return hook_storage end }
hook_storage = {}
local addr = 100
function obj(methods)
    addr = addr + 1
    local value = { addr = addr, methods = methods or {}, refs = 0 }
    function value:get_address() return self.addr end
    function value:add_ref() self.refs = self.refs + 1; return self end
    function value:call(name, ...)
        local member = self.methods[name]
        if member == nil then error('unsupported call ' .. name) end
        if type(member) == 'function' then return member(...) end
        return member
    end
    function value:get_field(name) return self.methods[name] end
    return value
end
function method(owner, name, count, first, fn, boolean)
    return { owner = owner, get_name = function() return name end,
        get_num_params = function() return count or 0 end,
        get_param_types = function() return { {get_full_name = function() return first end} } end,
        is_static = function() return false end,
        get_return_type = function() return {get_full_name = function() return boolean and 'System.Boolean' or 'System.Void' end} end,
        call = function(_, self, ...) if fn then return fn(...) end end }
end
function character()
    local input = obj()
    function input:get_field() return 0 end
    local processor = obj()
    processor.enabled = true
    processor.methods.set_IsEnable = function(v) processor.enabled = v end
    local geninfo = obj()
    local xf = obj({ get_UniversalPosition = function() return {x=10,y=20,z=30} end,
        get_Rotation = function() return setmetatable({x=0,y=0,z=0,w=1},
            {__mul = function() return {x=0,y=0,z=1} end}) end })
    local go = obj({get_Transform = xf, get_Name = 'ch000000_00',
        get_Components = function() return {get_elements = function() return {} end} end })
    go.draw = true
    go.methods.set_DrawSelf = function(v) go.draw = v end
    go.methods.get_Draw = function() return go.draw end
    local meta = obj({_Species=0, _Gender=1, _HeadStyle=12, _Nested={}})
    function meta:get_type_definition()
        local fields = {}
        for _, name in ipairs({'_Species','_Gender','_HeadStyle','_Nested'}) do
            fields[#fields+1] = {get_name=function() return name end, is_static=function() return false end}
        end
        return {get_fields=function() return fields end}
    end
    local sw = obj({_Meta = meta})
    sw.methods['restore(app.CharacterEditDefine.MetaData, app.CharacterEditDefine.VisorSwitch)'] = function() end
    sw.methods.get_VisorSwitch = 0
    sw.methods.requestSwap = function() end
    local ch = obj({ get_CharaID = 2891076981, get_Input = input, get_InputProcessor = processor,
        get_GameObject = go, get_GenerateInfo = geninfo, get_HumanPartSwapper = sw,
        get_HumanActionSelector = obj({get_SelectorFor=7}) })
    ch.processor, ch.go = processor, go
    return ch
end
world, spawn_requests = {}, 0
original = character(); world = { original }; manual = original
manager = obj({ get_ManualPlayer = function() return manual end,
    set_ManualPlayer = function(ch) manual = ch end })
holder = obj({getAllCharacters = function()
    return obj({get_Count = function() return #world end, get_Item = function(i) return world[i+1] end})
end})
local gm_methods = {
    method('GM', 'createGeneratorIDNoUsePool', 2, 'System.Guid', function() return obj() end),
    method('GM', 'createUniqueIDNoUsePool', 2, 'System.Guid', function() return obj() end),
    method('GM', 'getPoolGenerateInfoContainerForCharacter', 9, '', function() return obj() end),
    method('GM', 'safeRequestCreateInstance', 3, '', function() spawn_requests = spawn_requests + 1; return 2 end),
}
gm = obj()
function gm:get_type_definition() return {get_methods = function() return gm_methods end} end
local types = {
    ['app.SaveDataManager'] = {method('Save', 'requestSaveAuto', 0, '', nil, true)},
    ['app.MainFlowManager'] = {method('Main', 'requestSaveGameData', 0, '', nil, true)},
    ['app.GenerateInfo'] = {method('Generate', 'update', 0), method('Generate', 'lateUpdate', 0)},
}
sdk = { get_managed_singleton = function(name)
        if name == 'app.CharacterManager' then return manager end
        if name == 'app.CharacterListHolder' then return holder end
        if name == 'app.GenerateManager' then return gm end
        return nil
    end,
    get_native_singleton = function() return nil end,
    call_native_func = function() return nil end,
    find_type_definition = function(name)
        if name == 'System.Guid' then return { get_method = function() return method('Guid', 'NewGuid', 0, '', function() return 'guid' end) end } end
        return { get_methods = function() return types[name] or {} end,
            get_method = function() return method(name, 'update', 2) end }
    end,
    hook = function(m, pre, post) hooks[m.owner .. ':' .. m:get_name()] = { pre = pre, post = post } end,
    to_int64 = function(v) return v end, to_ptr = function(v) return v end,
    PreHookResult = {SKIP_ORIGINAL = 1} }
Vector3f = {new = function(x,y,z) return {x=x,y=y,z=z} end}
re = { on_pre_application_entry = function(stage, fn)
        callbacks[stage] = callbacks[stage] or {}; table.insert(callbacks[stage], fn)
    end, on_draw_ui = function(fn) callbacks.ui = fn end,
    on_script_reset = function(fn) callbacks.reset = fn end }
function ticks(n)
    for _=1,n do
        for _,stage in ipairs({'UpdateBehavior','LateUpdateBehavior'}) do
            for _,fn in ipairs(callbacks[stage] or {}) do fn() end
        end
    end
end
function key(ch) return string.format('0x%X', ch.addr) end
'''


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCKS)
        self.g = self.lua.globals()
        path = ROOT / 'dd2coop_puppet.lua'
        if not path.exists(): path = ROOT / 'src' / 'lua' / 'dd2coop_puppet.lua'
        self.source = path.read_text(encoding='utf-8')

    def load(self):
        self.lua.execute(self.source)

    def ready_pair(self):
        self.load()
        self.g.ticks(1)
        self.g.dd2coop_p2.create()
        self.lua.execute('clone = character(); world = {original, clone}; manual = clone')
        self.g.ticks(10)
        self.assertEqual(self.g.dd2coop_p2.state, 'pronto')

    def reload(self):
        self.g.callbacks.reset()
        self.lua.execute("files['dd2coop_net_status.json'].lua_epoch = files['dd2coop_net_status.json'].lua_epoch + 1; callbacks = {}; hooks = {}")
        self.load()
        self.g.ticks(1)

    def test_initial_verification_locks_save_until_single_arisen_confirmed(self):
        self.load()
        self.assertEqual(self.g.hooks['Save:requestSaveAuto'].pre(None), 1)
        self.assertTrue(self.g.files['dd2coop_net_cfg.json'].save_lock)
        self.g.ticks(1)
        self.assertEqual(self.g.dd2coop_p2.state, 'nenhum')
        self.assertFalse(self.g.files['dd2coop_net_cfg.json'].save_lock)

    def test_creation_and_duplicate_prevention(self):
        self.ready_pair()
        self.assertEqual(self.g.manual.addr, self.g.original.addr)
        self.assertFalse(self.g.clone.processor.enabled)
        self.g.dd2coop_p2.create()
        self.assertEqual(self.g.spawn_requests, 1)
        self.assertTrue(self.g.files['dd2coop_net_cfg.json'].save_lock)

    def test_reset_restores_identity_visibility_and_stops_input(self):
        self.ready_pair()
        self.g.dd2coop_p2.set_source(3)
        self.g.dd2coop_p2.toggle_hidden()
        self.reload()
        self.assertEqual(self.g.dd2coop_p2.orig.addr, self.g.original.addr)
        self.assertEqual(self.g.dd2coop_p2.clone.addr, self.g.clone.addr)
        self.assertEqual(self.g.dd2coop_p2.source_idx, 1)
        self.assertTrue(self.g.dd2coop_p2.hidden)
        self.assertFalse(self.g.clone.go.draw)
        self.assertFalse(self.g.clone.processor.enabled)
        self.assertEqual(self.g.files['dd2coop_net_cfg.json'].lua_epoch, 1)
        self.assertTrue(self.g.files['dd2coop_net_cfg.json'].save_lock)
        self.assertEqual(self.g.spawn_requests, 1)

    def test_unregistered_duplicates_require_explicit_original_choice(self):
        self.lua.execute('clone = character(); world = {original, clone}; manual = clone')
        self.load(); self.g.ticks(1)
        self.assertEqual(self.g.dd2coop_p2.state, 'recuperacao')
        self.assertIsNone(self.g.dd2coop_p2.orig)
        self.assertEqual(self.g.manual.addr, self.g.clone.addr)
        self.assertFalse(self.g.original.processor.enabled)
        self.assertTrue(self.g.dd2coop_p2.confirm_original(self.g.key(self.g.original)))
        self.assertEqual(self.g.manual.addr, self.g.original.addr)
        self.assertTrue(self.g.original.processor.enabled)
        self.assertFalse(self.g.clone.processor.enabled)

    def test_previous_process_cannot_restore_reused_addresses(self):
        self.lua.execute("files['dd2coop_session.json'] = {instance='old_game', phase='pronto', original=key(original), clone='0x999'}")
        self.load(); self.g.ticks(1)
        self.assertEqual(self.g.dd2coop_p2.state, 'nenhum')

    def test_reset_during_pending_spawn_adopts_late_clone(self):
        self.load(); self.g.ticks(1); self.g.dd2coop_p2.create()
        self.reload()
        self.assertEqual(self.g.dd2coop_p2.state, 'aguardando')
        self.assertTrue(self.g.files['dd2coop_net_cfg.json'].save_lock)
        self.lua.execute('clone = character(); world = {original, clone}; manual = clone')
        self.g.ticks(10)
        self.assertEqual(self.g.dd2coop_p2.state, 'pronto')
        self.assertEqual(self.g.spawn_requests, 1)

    def test_missing_clone_keeps_guard_and_stops_network(self):
        self.ready_pair(); self.g.dd2coop_p2.set_source(3)
        self.lua.execute('world = {original}')
        self.g.ticks(60)
        self.assertEqual(self.g.dd2coop_p2.state, 'recuperacao')
        self.assertEqual(self.g.files['dd2coop_net_cfg.json'].mode, 'off')
        self.assertTrue(self.g.files['dd2coop_net_cfg.json'].save_lock)

    def test_reloaded_save_with_new_player_allows_new_session(self):
        self.ready_pair()
        self.lua.execute('dd2coop_p2.guard_until=0; original = character(); world = {original}; manual = original')
        self.g.ticks(60)
        self.assertEqual(self.g.dd2coop_p2.state, 'nenhum')
        self.assertFalse(self.g.files['dd2coop_net_cfg.json'].save_lock)

    def test_generation_preparation_precedes_native_spawn(self):
        self.load(); self.g.ticks(1)
        self.lua.execute('''
            order = {}
            dd2coop_replica_id = {
                id_for=function() return 260732951 end,
                failed=function() return false end, ensure=function() return true end,
                retain_generation_id=function(o) o:add_ref(); table.insert(order,'id') end,
                prepare_container=function(c)
                    assert(spawn_requests==0); table.insert(order,'prepare'); return true
                end,
                arm_classification=function(id)
                    assert(id==260732951 and order[3]=='prepare')
                    table.insert(order,'arm')
                end
            }
        ''')
        self.g.dd2coop_p2.create()
        self.assertEqual(self.g.spawn_requests, 1)
        self.assertEqual(self.lua.eval("table.concat(order,',')"), 'id,id,prepare,arm')

    def test_failed_generation_preparation_never_spawns(self):
        self.load(); self.g.ticks(1)
        self.lua.execute('''
            dd2coop_replica_id = {
                id_for=function() return nil end,
                retain_generation_id=function(o) o:add_ref() end,
                prepare_container=function() return false,'invalid HumanInfo' end
            }
        ''')
        self.g.dd2coop_p2.create()
        self.assertEqual(self.g.spawn_requests, 0)
        self.assertEqual(self.g.dd2coop_p2.state, 'recuperacao')
        self.assertTrue(self.g.files['dd2coop_net_cfg.json'].save_lock)

    def test_missing_original_stops_remaining_replica_input(self):
        self.ready_pair(); self.g.dd2coop_p2.set_source(3)
        self.lua.execute('world = {clone}; manual = clone')
        self.g.ticks(60)
        self.assertEqual(self.g.dd2coop_p2.state, 'recuperacao')
        self.assertEqual(self.g.dd2coop_p2.source_idx, 1)
        self.assertFalse(self.g.clone.processor.enabled)
        self.assertTrue(self.g.files['dd2coop_net_cfg.json'].save_lock)

    def test_settings_clamp_and_invalid_peer_does_not_connect(self):
        self.lua.execute("files['dd2coop_settings.json'] = {delay=-1,jitter=200,snap_dist=99,peer='invalid'}")
        self.ready_pair()
        self.assertFalse(self.g.dd2coop_p2.set_source(4))
        self.g.dd2coop_p2.net_off()
        settings = self.g.files['dd2coop_settings.json']
        self.assertEqual((settings.delay, settings.jitter, settings.snap_dist), (1, 60, 6))
        self.assertEqual(self.g.files['dd2coop_net_cfg.json'].mode, 'off')

    def test_hidden_clone_cannot_start_input(self):
        self.ready_pair(); self.g.dd2coop_p2.toggle_hidden()
        self.assertFalse(self.g.dd2coop_p2.set_source(2))
        self.assertEqual(self.g.dd2coop_p2.source_idx, 1)

    def test_missing_plugin_instance_does_not_unlock_or_spawn(self):
        self.lua.execute("files['dd2coop_net_status.json'].instance = nil")
        self.load(); self.g.ticks(1); self.g.dd2coop_p2.create()
        self.assertEqual(self.g.spawn_requests, 0)
        self.assertTrue(self.g.files['dd2coop_net_cfg.json'].save_lock)

    def test_valid_peer_is_persisted_but_reset_does_not_reconnect(self):
        self.lua.execute("files['dd2coop_settings.json'] = {peer='76561198000000002', jitter=8}")
        self.ready_pair()
        self.assertTrue(self.g.dd2coop_p2.set_source(4))
        self.assertEqual(self.g.files['dd2coop_net_cfg.json'].peer, '76561198000000002')
        self.reload()
        self.assertEqual(self.g.files['dd2coop_net_cfg.json'].mode, 'off')
        self.assertEqual(self.g.files['dd2coop_settings.json'].peer, '76561198000000002')

    def test_profile_exports_original_and_skips_nested_objects(self):
        self.ready_pair()
        self.lua.execute("clone.methods.get_HumanPartSwapper.methods._Meta.methods._HeadStyle = 25")
        self.assertTrue(self.g.dd2coop_p2.export_profile())
        profile = self.g.files['dd2coop_profile.json']
        self.assertEqual((profile.vocation, profile.species, profile.gender), (7, 0, 1))
        self.assertEqual(profile.styles['_HeadStyle'], 12)
        self.assertIsNone(profile.styles['_Nested'])

    def test_save_hook_returns_false_only_while_locked(self):
        self.load()
        hook = self.g.hooks['Save:requestSaveAuto']
        self.assertEqual(hook.pre(None), 1)
        self.assertEqual(hook.post(1), 0)
        self.g.ticks(1)
        self.assertIsNone(hook.pre(None))
        self.assertEqual(hook.post(1), 1)


if __name__ == '__main__': unittest.main(verbosity=2)
