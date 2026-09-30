#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('rebuild',Path(__file__).with_name('rebuild-arcane.py'))
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)

class SafetyTests(unittest.TestCase):
    def test_default_selection_does_not_start_tunnels_or_stopped_projects(self):
        m={'stacks':[{'name':'app','enabled':True,'exposure_gate':False}, {'name':'tunnel','enabled':True,'exposure_gate':True}, {'name':'stopped','enabled':False,'exposure_gate':False}]}
        self.assertEqual([s['name'] for s in r.choose(m,[])],['app'])
        self.assertEqual([s['name'] for s in r.choose(m,['stopped'])],['stopped'])
        with self.assertRaises(ValueError):r.choose(m,['typo'])
    def test_explicit_dependency_order_is_preserved(self):
        m={'stacks':[{'name':'app'},{'name':'db'}]}
        self.assertEqual([s['name'] for s in r.choose(m,['db','app','db'])],['db','app'])
    def test_conflicting_definition_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as d:
            target=Path(d);(target/'compose.yaml').write_text('existing unrelated data')
            s={'name':'arcane','target':d,'binds':[],'env_files':[]}
            with self.assertRaisesRegex(ValueError,'refusing overwrite'):r.check_paths([s])
            self.assertEqual((target/'compose.yaml').read_text(),'existing unrelated data')
    def test_restore_file_type_and_missing_env(self):
        with tempfile.TemporaryDirectory() as d:
            s={'name':'arcane','target':d,'binds':[{'path':d,'kind':'file','profiles':[]}],'env_files':[{'path':d+'/missing.env'}]}
            with self.assertRaises(ValueError) as ctx:r.check_paths([s])
            self.assertIn('expected file',str(ctx.exception));self.assertIn('restore private application env file',str(ctx.exception))
    def test_subprocess_errors_do_not_expose_output(self):
        with self.assertRaises(RuntimeError) as ctx:r.run(['python3','-c','import sys;print("PRIVATE_VALUE");sys.exit(1)'])
        self.assertNotIn('PRIVATE_VALUE',str(ctx.exception))

if __name__=='__main__':unittest.main()
