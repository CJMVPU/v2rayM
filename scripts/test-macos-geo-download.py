#!/usr/bin/env python3
"""Offline download regressions: client identification and pinned-input rejection."""
import hashlib
import http.server
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

spec = importlib.util.spec_from_file_location('geo', Path(__file__).with_name('prepare-macos-geo.py'))
geo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(geo)


class GeoDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='v2raym-geo-download-test-')
        self.root = Path(self.temp.name)
        self.payload = b'pinned fixture archive\n' * 100000
        payload = self.payload

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/denied' or not self.headers.get('User-Agent', '').startswith('v2rayM-build/'):
                    self.send_error(403)
                    return
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'
        (self.root / 'contracts').mkdir()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def pin(self, checksum):
        (self.root / 'contracts/macos-build-inputs.json').write_text(json.dumps({
            'geolocation': {'file': 'fixture.gz', 'sourceURL': self.url + '/archive', 'sha256': checksum},
        }))

    def test_identified_client_downloads_complete_content_where_default_is_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as failure:
            urllib.request.urlopen(self.url + '/archive', timeout=5)
        self.assertEqual(failure.exception.code, 403)
        destination = self.root / 'download.gz'
        geo.download(self.url + '/archive', destination)
        self.assertEqual(destination.read_bytes(), self.payload)

    def test_http_errors_are_not_accepted_as_archives(self):
        destination = self.root / 'denied.gz'
        with self.assertRaises(urllib.error.HTTPError) as failure:
            geo.download(self.url + '/denied', destination)
        self.assertEqual(failure.exception.code, 403)
        self.assertFalse(destination.exists())

    def test_downloaded_checksum_mismatch_blocks_converter(self):
        self.pin('0' * 64)
        with patch.object(geo, 'ROOT', self.root), patch('sys.argv', ['prepare-macos-geo.py']), \
                patch.object(geo.subprocess, 'run') as converter:
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                geo.main()
            converter.assert_not_called()

    def test_matching_checksum_allows_conversion_then_verifies_outputs(self):
        self.pin(hashlib.sha256(self.payload).hexdigest())
        with patch.object(geo, 'ROOT', self.root), patch('sys.argv', ['prepare-macos-geo.py']), \
                patch.object(geo.subprocess, 'run') as converter, patch.object(geo, 'verify') as verify:
            geo.main()
            converter.assert_called_once()
            self.assertTrue(converter.call_args.kwargs['check'])
            verify.assert_called_once()

    def test_explicit_source_still_requires_checksum_and_does_not_download(self):
        self.pin('0' * 64)
        source = self.root / 'local.gz'
        source.write_bytes(self.payload)
        with patch.object(geo, 'ROOT', self.root), patch('sys.argv', ['prepare-macos-geo.py', '--source', str(source)]), \
                patch.object(geo, 'download') as download, patch.object(geo.subprocess, 'run') as converter:
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                geo.main()
            download.assert_not_called()
            converter.assert_not_called()


if __name__ == '__main__':
    unittest.main()
