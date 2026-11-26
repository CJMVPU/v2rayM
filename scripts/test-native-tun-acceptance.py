#!/usr/bin/env python3
"""Offline acceptance-driver regressions, independent of host networking."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('acceptance', Path(__file__).with_name('test-macos-tun-local.py'))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class AcceptanceTests(unittest.TestCase):
    def test_snapshot_rebases_file_nodes_and_excludes_secrets_and_recovery(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = root / 'source/guiConfigs'
            (config / 'profiles').mkdir(parents=True)
            (root / 'temporary').mkdir()
            (config / 'profiles/node.yaml').write_text('{"routing":{}}')
            (root / 'outside').write_text('private')
            (config / 'link').symlink_to(root / 'outside')
            for name in ['webapi-auth.json', 'native-pending-edit.json']:
                (config / name).write_text('{}')
            settings = {'IndexId': 'selected', 'TunModeItem': {'EnableTun': True}, 'Inbound': [{'LocalPort': 3}]}
            (config / 'guiNConfig.json').write_text(json.dumps(settings))
            addresses = ['profiles/node.yaml', str(config / 'profiles/node.yaml'), 'missing.json', 'link']
            with sqlite3.connect(config / 'guiNDB.db') as db:
                db.execute('CREATE TABLE ProfileItem(Address TEXT, ConfigType INTEGER)')
                db.executemany('INSERT INTO ProfileItem VALUES (?,2)', [(a,) for a in addresses])
            copy = acceptance.copy_config(config.parent, root / 'temporary')
            self.assertFalse(copy['TunModeItem']['EnableTun'])
            self.assertEqual(json.loads((config / 'guiNConfig.json').read_text()), settings)
            staged = root / 'temporary/guiConfigs'
            with sqlite3.connect(staged / 'guiNDB.db') as db:
                staged_names = [r[0] for r in db.execute('SELECT Address FROM ProfileItem ORDER BY rowid')]
            self.assertEqual([(staged / name).is_file() for name in staged_names], [True, True, False, False])
            self.assertEqual((staged / staged_names[0]).read_bytes(), (staged / staged_names[1]).read_bytes())
            self.assertFalse((staged / 'native-pending-edit.json').exists())
            self.assertFalse((staged / 'webapi-auth.json').exists())

    def test_existing_split_tunnel_rejected_with_physical_default_route(self):
        with self.assertRaisesRegex(RuntimeError, 'utun'):
            acceptance.check_no_existing_proxy({'testRoute': ['interface: en0'],
                                                'gatewayAndTunnelRoutes': [['10/8', 'link#22', 'UCS', 'utun4']]})


if __name__ == '__main__':
    unittest.main()
