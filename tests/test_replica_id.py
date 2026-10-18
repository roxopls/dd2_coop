"""Native generation ownership contract; no fabricated REFramework managed objects."""
from pathlib import Path
import unittest
from test_session import MOCKS, LuaRuntime, ROOT


class ReplicaGenerationTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCKS)
        self.lua.execute('''
            local find = sdk.find_type_definition
            local function human(meta)
                local h = obj({get_Meta=function() return meta end})
                function h:get_type_definition()
                    return {get_full_name=function() return 'app.GenerateInfo.HumanInfoData' end}
                end
                return h
            end
            copy_mode = 'normal'
            sdk.find_type_definition=function(name)
                if name~='System.Object' then return find(name) end
                return {get_method=function(_,m)
                    assert(m=='MemberwiseClone')
                    return {call=function(_,source)
                        if copy_mode=='nil' then return nil end
                        if copy_mode=='alias' then return source end
                        return human(source:call('get_Meta'))
                    end}
                end}
            end
            shared_meta=obj()
            shared_human=human(shared_meta)
            function container()
                local req=obj({_GenID=obj(),_UniqID=obj()})
                local status=obj({['<BreakRegionID>k__BackingField']=obj(),
                                  ['<IgnoreRegionID>k__BackingField']=obj()})
                local c=obj({_CommonInfo=obj({_RequestID=req}),_StatusInfo=status})
                c.human=shared_human
                c.methods.get_HumanInfo=function() return c.human end
                c.methods['set_HumanInfo(app.GenerateInfo.HumanInfoData)']=function(h)
                    if copy_mode~='setter_failure' then c.human=h end
                end
                return c
            end
        ''')
        self.lua.execute((ROOT/'src/lua/dd2coop_replica_id.lua').read_text(encoding='utf-8'))

    def test_each_request_owns_distinct_human_with_shallow_meta(self):
        self.lua.execute('''
            a,b=container(),container()
            assert(dd2coop_replica_id.prepare_container(a))
            assert(dd2coop_replica_id.prepare_container(b))
            assert(a.human~=b.human and a.human~=shared_human and b.human~=shared_human)
            assert(a.human:call('get_Meta')==shared_meta)
            collectgarbage('collect')
            assert(a.refs>0 and b.refs>0 and shared_human.refs>0 and shared_meta.refs>0)
            assert(a.human.refs>0 and b.human.refs>0)
            for _,c in ipairs({a,b}) do
                local common=c:get_field('_CommonInfo')
                local req=common:get_field('_RequestID')
                assert(common.refs>0 and req.refs>0)
                assert(req:get_field('_GenID').refs>0 and req:get_field('_UniqID').refs>0)
                local status=c:get_field('_StatusInfo')
                assert(status.refs>0 and status:get_field('<BreakRegionID>k__BackingField').refs>0)
                assert(status:get_field('<IgnoreRegionID>k__BackingField').refs>0)
            end
        ''')

    def test_invalid_copy_and_failed_setter_reject_preparation(self):
        for mode in ('nil', 'alias', 'setter_failure'):
            with self.subTest(mode=mode):
                self.lua.globals().copy_mode=mode
                self.lua.execute('ok,why=dd2coop_replica_id.prepare_container(container())')
                self.assertFalse(self.lua.globals().ok)
                self.assertTrue(self.lua.globals().why)

    def test_missing_source_rejects_preparation(self):
        self.lua.execute('c=container(); c.human=nil; ok=dd2coop_replica_id.prepare_container(c)')
        self.assertFalse(self.lua.globals().ok)

    def test_generation_ids_retained_before_container_exists(self):
        self.lua.execute('''
            id=obj()
            assert(dd2coop_replica_id.retain_generation_id(id)==id)
            collectgarbage('collect')
            assert(id.refs>0)
        ''')


if __name__ == '__main__':
    unittest.main()
