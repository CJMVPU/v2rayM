#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('selector', Path(__file__).with_name('select-macos-signing-identity.py'))
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class IdentityTests(unittest.TestCase):
    identity = 'A1' * 20
    certificate = '-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----'
    def choose(self, name, team='3AJ5WULVWJ', usable=True):
        identities = f'  1) {self.identity} "{name}"' if usable else '0 valid identities found'
        details = 'sha1 Fingerprint=' + ':'.join(['A1'] * 20) + '\nsubject=\n    OU = ' + team + '\n    CN = ' + name
        return selector.select_identity('3AJ5WULVWJ', identities, self.certificate, lambda _: details)
    def test_development_common_name_identifier_is_not_team(self):
        self.assertEqual(self.choose('Apple Development: Test (PERSONALID)'), self.identity)
    def test_matching_name_cannot_spoof_wrong_team(self):
        with self.assertRaisesRegex(RuntimeError, '没有匹配团队'):
            self.choose('Apple Development: Test (3AJ5WULVWJ)', team='OTHERTEAM')
    def test_certificate_without_usable_private_key_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, '系统未列出'):
            self.choose('Apple Development: Test', usable=False)
    def test_expired_certificate_not_in_valid_identity_list_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, '没有匹配团队'):
            selector.select_identity('3AJ5WULVWJ', f'1) {"B2" * 20} "Other"', self.certificate,
                                     lambda _: 'sha1 Fingerprint=' + self.identity + '\n    OU = 3AJ5WULVWJ')


if __name__ == '__main__':
    unittest.main()
