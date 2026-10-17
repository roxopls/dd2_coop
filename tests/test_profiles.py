from pathlib import Path
import sys
import unittest
ROOT = Path(__file__).parent
if ROOT.name == 'tests': ROOT = ROOT.parent
sys.path.insert(0, str(ROOT / 'vendor'))
from lupa.lua54 import LuaRuntime
from test_session import MOCKS

PROFILE_MOCKS = r'''
clone_requests, restores, releases = 0, 0, 0
local field_names = {'_Species','_Gender','_HeadStyle','_TopsStyle','_PantsStyle','_Nested'}
local function configure_meta(meta)
    function meta:set_field(name, value) self.methods[name] = value end
    function meta:release() self.refs = self.refs - 1; releases = releases + 1 end
    function meta:get_type_definition()
        local fields = {}
        for _, name in ipairs(field_names) do
            local enum = {is_enum=function() return true end, get_fields=function()
                local values = name == '_TopsStyle' and {100,200,300} or name == '_PantsStyle' and {400,500} or {0,1,12}
                local items = {}
                for _, value in ipairs(values) do
                    items[#items+1] = {is_static=function() return true end, get_data=function() return value end}
                end
                return items
            end}
            fields[#fields+1] = {get_name=function() return name end,
                is_static=function() return false end, get_type=function() return enum end}
        end
        return {get_fields=function() return fields end}
    end
    meta.methods.clone = function()
        clone_requests = clone_requests + 1
        local values = {}; for _, name in ipairs(field_names) do values[name] = meta.methods[name] end
        return configure_meta(obj(values))
    end
    return meta
end
function prepare(ch)
    ch.methods.get_RightWeaponID = 1001
    ch.methods.get_LeftWeaponID = 0
    ch.methods.get_AppearanceRightWeaponID = 1002
    ch.methods.get_AppearanceLeftWeaponID = 0
    ch.methods.get_IsEquipRightWeapon = true
    ch.methods.get_IsEquipLeftWeapon = false
    local sw = ch.methods.get_HumanPartSwapper
    sw.methods['requestSwap()'] = function() end
    local meta = configure_meta(sw.methods._Meta)
    meta.methods._Species, meta.methods._Gender = 2501532887, 1910070090
    meta.methods._TopsStyle, meta.methods._PantsStyle = 100, 400
    sw.methods['restore(app.CharacterEditDefine.MetaData, app.CharacterEditDefine.VisorSwitch)'] = function(detached)
        restores = restores + 1
        for _, name in ipairs(field_names) do meta.methods[name] = detached.methods[name] end
    end
    return ch
end
prepare(original)
clone = prepare(character()); world = {original,clone}
dd2coop_p2 = {state='pronto',orig=original,clone=clone,source_idx=1,instance='game1',net_status={save_hooks=6}}
files['dd2coop_visual_backup.json'] = {}
'''


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCKS + PROFILE_MOCKS)
        path = ROOT / 'dd2coop_profiles.lua'
        if not path.exists(): path = ROOT / 'src/lua/dd2coop_profiles.lua'
        self.lua.execute(path.read_text(encoding='utf-8'))
        self.g = self.lua.globals()
        self.m = self.g.dd2coop_profiles

    def profile(self):
        return self.m.capture(self.g.original)

    def load_session(self):
        path = ROOT / 'dd2coop_puppet.lua'
        if not path.exists(): path = ROOT / 'src/lua/dd2coop_puppet.lua'
        self.lua.execute("files['dd2coop_session.json'] = {version=1,instance='game1',phase='pronto',original=key(original),clone=key(clone)}")
        self.lua.execute(path.read_text(encoding='utf-8'))
        self.g.ticks(1)
        self.assertEqual(self.g.dd2coop_p2.state, 'pronto')

    def test_local_mirror_allows_different_vocation_and_weapons(self):
        self.load_session()
        self.g.clone.methods.get_RightWeaponID = 999
        self.g.clone.methods.get_HumanActionSelector.methods.get_SelectorFor = 2
        self.assertTrue(self.g.dd2coop_p2.set_source(2))
        self.assertEqual(self.g.dd2coop_p2.source_idx, 2)
        self.assertTrue(self.g.clone.processor.enabled)

    def test_local_echo_accepts_matching_characters(self):
        self.load_session()
        self.assertTrue(self.g.dd2coop_p2.set_source(3))
        self.assertEqual(self.g.dd2coop_p2.source_idx, 3)

    def test_pending_outfit_prevents_starting_playback(self):
        self.load_session()
        self.assertTrue(self.m.apply_outfit(self.profile()))
        self.assertFalse(self.g.dd2coop_p2.set_source(3))
        self.g.ticks(15)
        self.assertTrue(self.g.dd2coop_p2.set_source(3))

    def test_capture_distinguishes_physical_and_visual_weapon_and_false(self):
        p = self.profile()
        self.assertEqual(p.weapons.right.id, 1001)
        self.assertEqual(p.weapons.right.appearance_id, 1002)
        self.assertFalse(p.weapons.left.equipped)
        self.assertEqual(p.species, 2501532887)

    def test_schema_accepts_legacy_and_uint32_body_ids(self):
        p = self.profile(); p.version = 1; p.weapons = None
        normalized = self.m.validate(p)
        self.assertEqual(normalized.version, 2)
        self.assertEqual(normalized.source_version, 1)

    def test_schema_rejects_foreign_versions_nan_and_nested_styles(self):
        for code in ["p.game='other'", 'p.version=500', 'p.vocation=0/0',
                     'p.styles._TopsStyle={bad=true}', 'p.styles._Gender=123']:
            self.g.p = self.profile(); self.lua.execute(code)
            result = self.m.validate(self.g.p)
            self.assertIsNone(result[0], code)

    def test_incompatibility_detects_vocation_and_weapon_changes(self):
        a = self.profile(); b = self.profile()
        b.vocation = 2; b.weapons.right.id = 999
        result = self.m.compare(a, b)
        self.assertTrue(result.blocked)
        self.assertIn('vocation', list(result.mismatches.values()))
        self.assertIn('weapons.right.id', list(result.mismatches.values()))

    def test_missing_data_is_unknown_not_verified(self):
        a = self.profile(); b = self.profile(); b.weapons.left.equipped = None
        result = self.m.compare(a, b)
        self.assertFalse(result.blocked)
        self.assertFalse(result.verified)
        self.assertIn('weapons.left.equipped', list(result.unknown.values()))

    def test_export_and_load_do_not_modify_characters(self):
        self.assertTrue(self.m.export_original())
        self.assertTrue(self.m.load_profile())
        self.assertEqual(self.g.restores, 0)
        self.assertEqual(self.m.imported.weapons.right.id, 1001)

    def test_outfit_changes_clone_only_and_preserves_actual_loadout(self):
        p = self.profile(); p.styles['_TopsStyle'] = 200
        p.vocation = 9; p.weapons.right.id = 9999
        self.assertTrue(self.m.apply_outfit(p))
        self.assertEqual(self.m.capture(self.g.clone).styles['_TopsStyle'], 200)
        self.assertEqual(self.m.capture(self.g.original).styles['_TopsStyle'], 100)
        self.assertEqual(self.m.capture(self.g.clone).vocation, 7)
        self.assertEqual(self.m.capture(self.g.clone).weapons.right.id, 1001)
        self.assertEqual(self.g.releases, 1)
        self.g.ticks(15)
        self.assertIsNone(self.m.pending)

    def test_unknown_outfit_id_rejected_before_any_write(self):
        p = self.profile(); p.styles['_TopsStyle'] = 999999
        self.assertFalse(self.m.apply_outfit(p))
        self.assertEqual((self.g.restores, self.g.clone_requests), (0, 0))

    def test_wrong_body_rejected_before_any_write(self):
        p = self.profile(); p.gender = 123; p.styles['_Gender'] = 123
        self.assertFalse(self.m.apply_outfit(p))
        self.assertEqual(self.g.restores, 0)

    def test_playing_replica_cannot_change_wardrobe(self):
        self.g.dd2coop_p2.source_idx = 3
        self.assertFalse(self.m.apply_outfit(self.profile()))
        self.assertEqual(self.g.restores, 0)

    def test_shared_metadata_blocks_outfit_change(self):
        self.lua.execute('clone.methods.get_HumanPartSwapper.methods._Meta = original.methods.get_HumanPartSwapper.methods._Meta')
        self.assertFalse(self.m.apply_outfit(self.profile()))
        self.assertEqual(self.g.restores, 0)

    def test_clone_method_returning_original_is_rejected(self):
        self.lua.execute('clone.methods.get_HumanPartSwapper.methods._Meta.methods.clone = function() return original.methods.get_HumanPartSwapper.methods._Meta end')
        self.assertFalse(self.m.apply_outfit(self.profile()))
        self.assertEqual(self.g.restores, 0)

    def test_undo_preserves_first_backup_across_multiple_changes(self):
        p = self.profile(); p.styles['_TopsStyle'] = 200
        self.assertTrue(self.m.apply_outfit(p)); self.g.ticks(15)
        p.styles['_TopsStyle'] = 300
        self.assertTrue(self.m.apply_outfit(p)); self.g.ticks(15)
        self.assertTrue(self.m.undo_outfit()); self.g.ticks(15)
        self.assertEqual(self.m.capture(self.g.clone).styles['_TopsStyle'], 100)

    def test_previous_process_backup_cannot_change_replica(self):
        p = self.profile(); p.styles['_TopsStyle'] = 200
        self.assertTrue(self.m.apply_outfit(p)); self.g.ticks(15)
        self.g.files['dd2coop_visual_backup.json'].instance = 'old_game'
        self.assertFalse(self.m.undo_outfit())
        self.assertEqual(self.g.restores, 1)

    def test_pending_check_stops_when_replica_disappears(self):
        self.assertTrue(self.m.apply_outfit(self.profile()))
        self.lua.execute('world = {original}')
        self.g.ticks(15)
        self.assertIsNone(self.m.pending)
        self.assertEqual(self.g.restores, 1)


if __name__ == '__main__': unittest.main(verbosity=2)
