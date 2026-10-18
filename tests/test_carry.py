"""Exercise the real carry hook's ownership, damage guards and restoration."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
for vendor in (ROOT / 'vendor', ROOT.parent / 'dd2coop-dev' / 'vendor'):
    if vendor.is_dir():
        sys.path.insert(0, str(vendor))
from lupa.lua54 import LuaRuntime

SOURCE = ROOT / 'src/lua/dd2coop_carry.lua'


class CarryTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            function actor(a) return {get_address=function()return a end}end
            function hit(ch,a)
                local h={ch=ch,address=a,invincible=true,nodie=true,writes={}}
                function h:get_address()return self.address end
                function h:get_field(n)
                    assert(n=='<CachedCharacter>k__BackingField');return self.ch
                end
                function h:call(n,v)
                    if n=='get_IsNoDie'then return self.nodie end
                    if n=='get_IsInvincible'then return self.invincible end
                    if n=='set_IsInvincible'then
                        self.invincible=v; self.writes[#self.writes+1]=v;return
                    end
                    error(n)
                end
                return h
            end
            local local_ch,clone_ch=actor(10),actor(20)
            dd2coop_p2={orig=local_ch,clone=clone_ch,state='pronto',source_idx=4}
            dd2coop_extra={slots={{clone=actor(30),active=true,state='pronto'}}}
            local_hit=hit(local_ch,100);clone_hit=hit(clone_ch,200)
            attack={flags=258,damage=0}
            function attack:get_field(n)
                if n=='AttackFlag'then return self.flags end
                if n=='DamageValue'then return self.damage end
                error(n)
            end
            info={source=local_hit,attack=attack,values={}}
            function info:call(n)
                if n=='get_AttackOwnerHitController'then return self.source end
                if n=='get_AttackHitController'then return self.fallback end
                if n=='get_AttackUserData'then return self.attack end
                error(n)
            end
            function info:get_field(n)
                if self.fail then error('metadata unavailable')end
                return self.values[n] or 0
            end
            storage={}
            thread={get_hook_storage=function()return storage end}
            sdk={to_managed_object=function(v)return v end,
                find_type_definition=function(n)
                    if n=='app.AttackUserData.AttackFlagEnum'then
                        return {get_field=function(_,name)
                            return {get_data=function()return name=='Catch'and 2 or 256 end}
                        end}
                    end
                    assert(n=='app.HitController')
                    return {get_method=function(_,name)
                        assert(name=='damageProc')
                        return {get_param_types=function()return {{get_full_name=function()
                            return 'app.HitController.DamageInfo'end}}end}
                    end}
                end,
                hook=function(_,pre,post)carry_pre=pre;carry_post=post end}
            re={on_draw_ui=function()end};log={info=function()end}
            function begin(target)carry_pre({[2]=target or clone_hit,[3]=info})end
            function finish()return carry_post(123)end
        ''')
        self.lua.execute(SOURCE.read_text(encoding='utf-8'))

    def test_catch_only_relaxes_protection_during_call(self):
        self.lua.execute('begin()')
        self.assertFalse(self.lua.eval('clone_hit.invincible'))
        self.assertTrue(self.lua.eval('clone_hit.nodie'))
        self.assertEqual(self.lua.eval('finish()'), 123)
        self.assertTrue(self.lua.eval('clone_hit.invincible'))
        self.assertEqual(self.lua.eval('dd2coop_carry.allowed'), 1)
        self.assertEqual(self.lua.eval('dd2coop_carry.restored'), 1)

    def test_original_npc_and_enemy_attacks_untouched(self):
        for setup in ('target=local_hit', 'target=hit(actor(99),990)',
                      'info.source=hit(actor(99),990);target=clone_hit'):
            with self.subTest(setup=setup):
                self.setUp()
                self.lua.execute(setup + ';begin(target);finish()')
                self.assertEqual(self.lua.eval('#clone_hit.writes'), 0)
                self.assertEqual(self.lua.eval('#local_hit.writes'), 0)

    def test_normal_attacks_and_nonzero_damage_rejected(self):
        cases = ['attack.flags=0', 'attack.flags=256', 'attack.flags=2',
                 'attack.damage=1', 'attack.damage=0/0']
        cases += [f'info.values.{n}=1' for n in (
            'Damage', 'FixedDamage', 'SlashDamage', 'BlowDamage', 'ShootDamage',
            'MagicDamage', 'EnchantDamage', 'NonMagicElementDamage', 'StaminaDamage')]
        for setup in cases:
            with self.subTest(setup=setup):
                self.setUp()
                self.lua.execute(setup + ';begin();finish()')
                self.assertEqual(self.lua.eval('#clone_hit.writes'), 0)

    def test_unprotected_and_inactive_replicas_untouched(self):
        for setup in ('clone_hit.nodie=false','clone_hit.invincible=false',
                      'dd2coop_p2.hidden=true','dd2coop_p2.source_idx=1',
                      "dd2coop_p2.state='gerando'", 'dd2coop_carry.enabled=false',
                      'dd2coop_p2.clone=dd2coop_p2.orig;clone_hit.ch=dd2coop_p2.orig'):
            with self.subTest(setup=setup):
                self.setUp()
                self.lua.execute(setup + ';begin();finish()')
                self.assertEqual(self.lua.eval('#clone_hit.writes'), 0)

    def test_extra_replica_and_echo_supported(self):
        self.lua.execute('dd2coop_p2.source_idx=3;clone_hit.ch=dd2coop_extra.slots[1].clone;begin()')
        self.assertFalse(self.lua.eval('clone_hit.invincible'))
        self.lua.execute('finish()')
        self.assertTrue(self.lua.eval('clone_hit.invincible'))

    def test_restore_even_if_disabled_or_registry_changes_mid_call(self):
        self.lua.execute('begin();dd2coop_carry.enabled=false;dd2coop_p2=nil;finish()')
        self.assertTrue(self.lua.eval('clone_hit.invincible'))
        self.assertEqual(self.lua.eval('dd2coop_carry.restored'), 1)

    def test_missing_metadata_fails_closed(self):
        self.lua.execute('info.fail=true;begin();finish()')
        self.assertEqual(self.lua.eval('#clone_hit.writes'), 0)
        self.assertEqual(self.lua.eval('dd2coop_carry.errors'), 1)

    def test_no_duplicate_hooks(self):
        self.lua.execute('sdk.hook=function()error("duplicate")end')
        self.lua.execute(SOURCE.read_text(encoding='utf-8'))
        self.assertEqual(self.lua.eval('dd2coop_carry.hooks'), 1)


if __name__ == '__main__':
    unittest.main()
