from pathlib import Path
import unittest
import test_profiles

ROOT = Path(__file__).parent
if ROOT.name == 'tests': ROOT = ROOT.parent

MOCK = r'''
job_requests, weapon_requests = 0, 0
local old_find=sdk.find_type_definition
sdk.find_type_definition=function(name)
    if name=='app.Character.JobEnum' or name=='app.WeaponID' then
        return {get_fields=function()
            local fields={}
            for _,v in ipairs(name=='app.Character.JobEnum' and {0,1,2,7,9} or {0,1001,1002,2001})do
                fields[#fields+1]={is_static=function()return true end,get_data=function()return v end}
            end
            return fields
        end}
    end
    return old_find(name)
end
function loadout_character(ch)
    local job=obj({get_Job=7})
    local changer=obj({Chara=ch,JobContext=job})
    changer.methods['requestChangeJob(app.Character.JobEnum)']=function(v)
        job_requests=job_requests+1;job.methods.get_Job=v
        ch.methods.get_HumanActionSelector.methods.get_SelectorFor=v
    end
    local human=obj({get_JobContext=job,get_JobChanger=changer})
    ch.methods.get_Human=human
    ch.methods.WeaponContext=obj()
    local holder=obj()
    for _,side in ipairs({'right','left'})do
        local label=side=='right' and 'Right' or 'Left'
        local slot=obj({get_WeaponID=side=='right' and 1002 or 0})
        if side=='right' then slot.methods.get_Weapon=obj() else slot.methods.get_Weapon=function()return nil end end
        slot.methods['requestEquipWeapon(app.WeaponID)']=function(id)
            weapon_requests=weapon_requests+1
            slot.methods.get_WeaponID=id;slot.methods.get_Weapon=obj()
            ch.methods['get_'..label..'WeaponID']=id
            return true
        end
        holder.methods['get_'..label..'Weapon']=slot
    end
    ch.methods.get_WeaponAndItemHolder=holder
end
loadout_character(original);loadout_character(clone)
'''

class LoadoutTests(unittest.TestCase):
    def setUp(self):
        fixture=test_profiles.ProfileTests();fixture.setUp()
        self.lua,self.g,self.profiles=fixture.lua,fixture.g,fixture.m
        self.lua.execute(MOCK)
        path=ROOT/'dd2coop_loadout.lua'
        if not path.exists(): path=ROOT/'src/lua/dd2coop_loadout.lua'
        self.lua.execute(path.read_text(encoding='utf-8'))
        self.m=self.g.dd2coop_loadout

    def profile(self): return self.profiles.capture(self.g.original)

    def test_profile_can_use_different_vocation_and_weapon_from_original(self):
        p=self.profile();p.vocation=2;p.weapons.right.id=2001;p.weapons.right.appearance_id=2001
        self.assertTrue(self.m.apply(p),self.m.message)
        self.g.ticks(30)
        self.assertIsNone(self.m.pending)
        self.assertEqual(self.profiles.capture(self.g.clone).vocation,2)
        self.assertEqual(self.profiles.capture(self.g.original).vocation,7)
        self.assertEqual(self.profiles.capture(self.g.original).weapons.right.id,1001)
        self.assertEqual(self.g.weapon_requests,1)

    def test_shared_job_context_rejected_before_write(self):
        self.lua.execute('clone.methods.get_Human.methods.get_JobContext=original.methods.get_Human.methods.get_JobContext')
        self.assertFalse(self.m.apply(self.profile()))
        self.assertEqual(self.g.job_requests,0)

    def test_shared_slot_rejected_before_write(self):
        self.lua.execute('clone.methods.get_WeaponAndItemHolder.methods.get_RightWeapon=original.methods.get_WeaponAndItemHolder.methods.get_RightWeapon')
        self.assertFalse(self.m.apply(self.profile()))
        self.assertEqual(self.g.weapon_requests,0)

    def test_unknown_weapon_does_not_change_vocation(self):
        p=self.profile();p.vocation=2;p.weapons.right.id=9999
        self.assertFalse(self.m.apply(p))
        self.assertEqual(self.g.job_requests,0)

    def test_playing_replica_rejected(self):
        self.g.dd2coop_p2.source_idx=4
        self.assertFalse(self.m.apply(self.profile()))

    def test_lost_replica_stops_pending_operation(self):
        self.assertTrue(self.m.apply(self.profile()))
        self.lua.execute('world={original}')
        self.g.ticks(15)
        self.assertIsNone(self.m.pending)
        self.assertEqual(self.g.weapon_requests,0)

    def test_original_change_interrupts_without_more_writes(self):
        p=self.profile();p.weapons.right.id=2001;p.weapons.right.appearance_id=2001
        self.assertTrue(self.m.apply(p))
        self.g.original.methods.get_RightWeaponID=2001
        self.g.ticks(15)
        self.assertIsNone(self.m.pending)
        self.assertEqual(self.g.weapon_requests,0)

    def test_backup_failure_stops_before_job_change(self):
        self.lua.execute('json.dump_file=function()return false end')
        p=self.profile();p.vocation=2
        self.assertFalse(self.m.apply(p))
        self.assertEqual(self.g.job_requests,0)

if __name__=='__main__':unittest.main(verbosity=2)
