from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).parent
if ROOT.name == 'tests': ROOT = ROOT.parent
sys.path.insert(0, str(ROOT / 'vendor'))
from lupa.lua54 import LuaRuntime

MOCKS = r'''
callbacks, hooks, writes, dumps = {}, {}, {}, {}
log = { info = function() end }
fs = { write = function(path, value) writes[path] = value; return true end }
request = nil
json = { dump_file = function(path, value) dumps[path] = value; return true end,
    load_file = function() return request end }
re = { on_pre_application_entry = function(_, fn) callbacks.tick = fn end,
    on_draw_ui = function(fn) callbacks.ui = fn end,
    on_script_reset = function(fn) callbacks.reset = fn end }
imgui = { tree_node = function() return false end }
local action_hook = { get_num_params = function() return 3 end }
sdk = { find_type_definition = function()
    return { get_method = function() return action_hook end }
end, hook = function(_, pre, post) hooks.pre, hooks.post = pre, post end,
    get_managed_singleton = function() return manager end,
    to_int64 = function(v) return v end, to_managed_object = function(v) return v end }

local next_addr = 100
function object(kind, values)
    next_addr = next_addr + 1
    local obj = { values = values or {}, addr = next_addr }
    local td = { get_full_name = function() return kind end,
        get_parent_type = function() return nil end }
    function td:get_method(name)
        if obj.values[name] == nil then return nil end
        return { get_num_params = function() return name == 'getCurrentActionHash' and 1 or 0 end,
            is_static = function() return false end,
            call = function(_, self, ...)
                local value = self.values[name]
                if type(value) == 'function' then return value(...) end
                return value
            end }
    end
    function obj:get_address() return self.addr end
    function obj:get_type_definition() return td end
    return obj
end
function character()
    local am = object('ActionManager', { getCurrentActionHash = function(layer) return 900 + layer end })
    local pos = { x = 10, y = 20, z = 30 }
    local xf = object('Transform', { get_UniversalPosition = pos })
    local go = object('GameObject', { get_Transform = xf })
    local stamina = object('Stamina', { get_RemainingAmountProp = 80 })
    local status = object('Status', {})
    local human = object('Human', { get_ActionType = 0, get_MoveState = 1,
        get_UnbalanceType = 0, get_TimerSecDown = 0, get_IsRunningOutOfStamina = false,
        get_StaminaContext = stamina, get_StatusContext = status })
    return object('Character', { get_Hp = 100, get_OriginalMaxHp = 100,
        get_IsDead = false, get_IsDown = false, get_IsKneeDown = false,
        get_IsDamage = false, get_IsFallDead = false, get_IsUnbalance = false,
        get_CauseOfDeath = 0, get_CharaID = 2891076981, get_Human = human,
        get_ActionManager = am, get_GameObject = go })
end
function ready()
    dd2coop_p2 = { state = 'pronto', frame = 123, source_idx = 3,
        orig = character(), clone = character(),
        net_status = { mode = 'eco', sent = 100, received = 99, held = 2, remote_valid = false } }
    manager = object('Manager', { get_ManualPlayer = dd2coop_p2.orig })
end
function ticks(n) for _ = 1, n do callbacks.tick() end end
'''


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCKS)
        path = ROOT / 'dd2coop_diagnostics.lua'
        if not path.exists(): path = ROOT / 'src' / 'lua' / 'dd2coop_diagnostics.lua'
        self.lua.execute(path.read_text(encoding='utf-8'))
        self.g = self.lua.globals()

    def test_idle_without_puppet_and_reset(self):
        self.g.ticks(120)
        self.assertEqual(self.g.dd2coop_diagnostics.latest.state, 'script_missing')
        self.g.callbacks.reset()
        self.assertIsNotNone(self.g.dumps['dd2coop_diag_status.json'])

    def test_missing_optional_command_file_gets_initialized(self):
        self.g.ticks(60)
        self.assertEqual(self.g.dumps['dd2coop_diag_request.json'].command, 'idle')

    def test_distinct_characters_and_false_states_survive(self):
        self.g.ready()
        self.g.ticks(6)
        pair = self.g.dd2coop_diagnostics.latest
        self.assertNotEqual(pair.original.address, pair.clone.address)
        self.assertEqual(pair.original.character_id, pair.clone.character_id)
        self.assertFalse(pair.clone.flags.dead)
        self.assertFalse(pair.clone.flags.down)
        self.assertTrue(pair.manual_is_original)
        self.assertEqual(pair.original.actions.layer1, 901)
        self.assertEqual(pair.clone.stamina, 80)
        self.assertFalse(pair.network.remote_valid)

    def test_clone_down_is_logged_without_mutation(self):
        self.g.ready()
        self.g.ticks(6)
        self.lua.execute('dd2coop_p2.clone.values.get_IsDown = true')
        self.g.ticks(6)
        pair = self.g.dd2coop_diagnostics.latest
        self.assertTrue(pair.clone.flags.down)
        self.assertFalse(pair.original.flags.down)
        self.g.dd2coop_diagnostics.mark('clone caiu')
        lines = '\n'.join(self.g.writes[self.g.dd2coop_diagnostics.latest.session and
            self.g.dumps['dd2coop_diag_status.json'].history].splitlines())
        self.assertIn('owner=clone', lines)
        self.assertIn('flags.down=true', lines)
        self.assertIn('event=marker', lines)
        self.assertEqual(pair.clone.flags.hp, 100)

    def test_unsupported_getter_is_unknown_and_reported(self):
        self.g.ready()
        self.lua.execute('dd2coop_p2.orig.values.get_Hp = nil; dd2coop_p2.clone.values.get_Hp = nil')
        self.g.ticks(6)
        self.assertIsNone(self.g.dd2coop_diagnostics.latest.clone.flags.hp)
        self.assertEqual(self.g.dd2coop_diagnostics.errors['Character:get_Hp:0'], 'unsupported')

    def test_action_hook_observes_only_known_owners_and_preserves_result(self):
        self.g.ready()
        self.g.ticks(6)
        self.lua.execute('''
            local am = dd2coop_p2.clone.values.get_ActionManager
            local text = { call = function() return 'DmgStatusSleepDown' end }
            assert(hooks.pre({ [2] = am.addr, [4] = text, [5] = 0 }) == nil)
            assert(hooks.post(1234) == 1234)
        ''')
        self.g.ticks(6)
        req = self.g.dd2coop_diagnostics.latest.clone.last_requests.layer0
        self.assertEqual(req.name, 'DmgStatusSleepDown')
        self.assertIsNone(self.g.dd2coop_diagnostics.latest.original.last_requests)

    def test_pending_request_not_replayed_and_events_bounded(self):
        self.g.ready()
        self.lua.execute("request = { id = 1, command = 'mark', note = 'old' }")
        self.g.ticks(60)
        self.assertNotIn('event=marker', '\n'.join(self.g.dd2coop_diagnostics.events.values()))
        self.lua.execute("request = { id = 2, command = 'mark', note = 'new' }")
        self.g.ticks(60)
        self.assertIn('note=new', '\n'.join(self.g.dd2coop_diagnostics.events.values()))
        self.lua.execute('''for i = 1, 2100 do
            dd2coop_p2.clone.values.get_IsDown = i % 2 == 0
            ticks(6)
        end''')
        self.assertLessEqual(len(self.g.dd2coop_diagnostics.events), 2000)
        self.assertGreater(self.g.dd2coop_diagnostics.total, 2000)


if __name__ == '__main__':
    unittest.main(verbosity=2)
