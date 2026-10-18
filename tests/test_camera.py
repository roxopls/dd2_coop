"""Ownership filtering of the actual camera hook; no game/REFramework required."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
for vendor in (ROOT / 'vendor', ROOT.parent / 'dd2coop-dev' / 'vendor'):
    if vendor.is_dir():
        sys.path.insert(0, str(vendor))
from lupa.lua54 import LuaRuntime


class CameraTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            function actor(address) return {get_address=function() return address end} end
            sdk={PreHookResult={SKIP_ORIGINAL=1},to_int64=function(v)return v end,
                find_type_definition=function(t) return {get_method=function(_,name)
                    if t=='app.SkillCameraTrack' and name=='update(app.Character)' then return {} end end} end,
                hook=function(_,pre,post) camera_pre=pre; camera_post=post end}
            re={on_draw_ui=function()end,on_pre_application_entry=function(_,fn) camera_tick=fn end}; log={info=function()end}
            dd2coop_p2={state='pronto',orig=actor(10),clone=actor(20)}
            dd2coop_extra={slots={{state='pronto',clone=actor(30)},{state='pronto',clone=actor(40)}}}
            function run(address) return camera_pre({[3]=address}) end
        ''')
        source = Path(__file__).resolve().parents[1] / 'src/lua/dd2coop_camera.lua'
        self.lua.execute(source.read_text(encoding='utf-8'))
        self.assertEqual(self.lua.eval('dd2coop_camera.hooks'), 0)
        self.lua.execute('camera_tick()')

    def test_original_and_npcs_untouched(self):
        self.assertIsNone(self.lua.eval('run(10)'))
        self.assertIsNone(self.lua.eval('run(99)'))
        self.assertIsNone(self.lua.eval('run(0)'))

    def test_all_remote_instances_filtered(self):
        for address in (20, 30, 40):
            self.assertEqual(self.lua.eval(f'run({address})'), 1)
        self.assertEqual(self.lua.eval('dd2coop_camera.blocked'), 3)

    def test_toggle_preserves_original_calls(self):
        self.lua.execute('dd2coop_camera.enabled=false')
        self.assertIsNone(self.lua.eval('run(20)'))

    def test_local_identity_wins_over_ambiguous_clone(self):
        self.lua.execute('dd2coop_p2.clone=actor(10)')
        self.assertIsNone(self.lua.eval('run(10)'))

    def test_no_session_and_ownership_error_preserve_calls(self):
        self.lua.execute('dd2coop_p2=nil; dd2coop_extra=nil')
        self.assertIsNone(self.lua.eval('run(20)'))
        self.lua.execute('dd2coop_p2={state="pronto",clone={get_address=function() error("stale") end}}')
        self.assertIsNone(self.lua.eval('run(20)'))
        self.assertEqual(self.lua.eval('dd2coop_camera.errors'), 1)

    def test_camera_hook_bypassed_during_generation(self):
        self.lua.execute("dd2coop_extra.busy={}")
        self.assertIsNone(self.lua.eval('run(20)'))
        self.lua.execute("dd2coop_extra.busy=nil; dd2coop_p2.state='gerando'")
        self.assertIsNone(self.lua.eval('run(20)'))

    def test_no_duplicate_hooks_on_reexecution(self):
        self.lua.execute('sdk.hook=function() error("duplicate hook") end')
        source = Path(__file__).resolve().parents[1] / 'src/lua/dd2coop_camera.lua'
        self.lua.execute(source.read_text(encoding='utf-8'))
        self.assertEqual(self.lua.eval('dd2coop_camera.hooks'), 1)


if __name__ == '__main__':
    unittest.main()
