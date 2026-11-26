#!/usr/bin/env python3
"""Exercise staged edits through the native host, an isolated SQLite store and loopback SOCKS peers."""
import argparse
from contextlib import ExitStack
import http.client
import http.server
import socketserver
import json
from pathlib import Path
import select
import socket
import sqlite3
import subprocess
import tempfile
import threading


class Marker(socketserver.StreamRequestHandler):
    def handle(self):
        read = self.rfile.read
        assert read(1) == b'\x05'
        read(read(1)[0])
        self.wfile.write(b'\x05\x00')
        assert read(3) == b'\x05\x01\x00'
        kind = read(1)
        if kind == b'\x01':
            address = socket.inet_ntop(socket.AF_INET, read(4))
        else:
            assert kind == b'\x03'
            address = read(read(1)[0]).decode()
        port = int.from_bytes(read(2), 'big')
        if address != '127.0.0.1' or port != 1:
            self.wfile.write(b'\x05\x02\x00\x01' + bytes(6))
            return
        self.wfile.write(b'\x05\x00\x00\x01' + bytes(6))
        assert self.rfile.readline().startswith(b'GET /marker')
        while self.rfile.readline() not in (b'\r\n', b''):
            pass
        data = self.server.label.encode()
        self.wfile.write(b'HTTP/1.0 200 OK\r\nContent-Length: ' + str(len(data)).encode() + b'\r\n\r\n' + data)


def seed(db, ports, inbound, nested_type):
    with db:
        db.execute("INSERT INTO ProfileItem(IndexId,ConfigType,CoreType,ConfigVersion,Remarks,Address) "
                   "VALUES ('broken',2,2,4,'Invalid core fixture','broken.json')")
        db.execute("INSERT INTO SubItem(Id,Remarks) VALUES ('sub','Subscription fixture')")
        db.executemany("INSERT INTO ProfileItem(IndexId,ConfigType,CoreType,ConfigVersion,Remarks,Address,Port,Subid) "
                       "VALUES (?,4,2,4,?,'127.0.0.1',?,'sub')",
                       [('member', 'Active one', ports[0]), ('reserve', 'Reserve', ports[0]), ('other', 'Other', ports[0])])
        db.executemany("INSERT INTO ProfileItem(IndexId,ConfigType,CoreType,ConfigVersion,Remarks) VALUES (?,?,2,2,?)",
                       [('parent', 203 - nested_type, 'Parent'), ('inner', nested_type, 'Nested')])
        db.execute("INSERT INTO ProfileGroupItem(IndexId,ChildItems) VALUES ('parent','inner')")
        db.execute("INSERT INTO ProfileGroupItem(IndexId,SubChildItems,Filter) VALUES ('inner','sub','^Active')")
        template = {'log': {'loglevel': 'none'},
                    'inbounds': [{'tag': 'fixture', 'protocol': 'http', 'listen': '127.0.0.1', 'port': inbound}],
                    'outbounds': [], 'routing': {'rules': [{'inboundTag': ['fixture'], 'outboundTag': 'proxy'}]}}
        db.execute('UPDATE FullConfigTemplateItem SET Enabled=1,Config=? WHERE CoreType=2', (json.dumps(template),))
        db.execute("CREATE TRIGGER fixture_edit_failure BEFORE UPDATE ON ProfileItem "
                   f"WHEN OLD.IndexId='reserve' AND NEW.Port={int(ports[2])} BEGIN SELECT RAISE(ABORT,'fixture'); END")


def verify(app, checker, nested_type):
    with ExitStack() as stack:
        files = Path(stack.enter_context(tempfile.TemporaryDirectory()))
        ports = []
        for label in ['old', 'new', 'rejected']:
            peer = stack.enter_context(socketserver.ThreadingTCPServer(('127.0.0.1', 0), Marker))
            peer.daemon_threads = True
            peer.label = label
            threading.Thread(target=peer.serve_forever, daemon=True).start()
            stack.callback(peer.shutdown)
            ports.append(peer.server_address[1])
        with socket.socket() as free:
            free.bind(('127.0.0.1', 0))
            inbound = free.getsockname()[1]
        host = subprocess.Popen([checker, '--serve-group-edit-fixture', app, files], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, text=True)

        def response():
            assert select.select([host.stdout], [], [], 12)[0], 'fixture timed out'
            line = host.stdout.readline()
            assert line, host.poll()
            return json.loads(line)

        expected_root = "parent"

        def change(action, id, error=None, **options):
            host.stdin.write(json.dumps(dict(action=action, id=id, **options)) + '\n')
            host.stdin.flush()
            result = response()
            assert result['error'] == error and result['running'] == expected_root and result['session'], result
            return result['session']

        def probe(label):
            conn = http.client.HTTPConnection('127.0.0.1', inbound, timeout=4)
            try:
                conn.request('GET', 'http://127.0.0.1:1/marker')
                result = conn.getresponse()
                assert result.status == 200 and result.read().decode() == label, label
            finally:
                conn.close()

        try:
            assert response() == 'ready'
            db = sqlite3.connect(files / 'guiConfigs/guiNDB.db')
            stack.callback(db.close)
            folder = files / 'guiConfigs'
            (folder / 'broken.json').write_text(json.dumps({'outbounds': [{'protocol': 'invalid-fixture-protocol'}]}))
            settings_path = folder / 'guiNConfig.json'
            settings = json.loads(settings_path.read_text())
            settings['SpeedTestItem']['SpeedPingTestUrl'] = 'http://127.0.0.1:2/ping'
            settings_path.write_text(json.dumps(settings))
            seed(db, ports, inbound, nested_type)
            first = change('select', 'parent')
            probe('old')
            assert change('edit', 'other', field='port', value=ports[1]) == first
            assert change('delete', 'other') == first
            second = change('edit', 'member', field='port', value=ports[1])
            assert second != first
            probe('new')
            assert change('delete', 'inner', 'profile_in_use_by_group') == second
            assert change('delete', 'member', 'profile_group_empty') == second
            assert change('move', 'member', 'profile_group_empty', value='') == second
            with db:
                db.execute("INSERT INTO ProfileExItem(IndexId,Delay) VALUES ('member',-1)")
            assert change('clean', 'member', 'profile_group_empty') == second
            assert change('edit', 'member', 'profile_group_empty', field='remarks', value='Does not match') == second
            assert db.execute("SELECT Remarks FROM ProfileItem WHERE IndexId='member'").fetchone() == ('Active one',)
            probe('new')
            third = change('edit', 'reserve', field='remarks', value='Active reserve')
            assert third != second
            moved = change('move', 'member', value='')
            assert moved != third
            probe('old')
            returned = change('move', 'member', value='sub')
            assert returned != moved
            fourth = change('clean' if nested_type == 101 else 'delete', 'member')
            assert fourth != returned and not db.execute("SELECT 1 FROM ProfileItem WHERE IndexId='member'").fetchone()
            probe('old')
            rollback = change('edit', 'reserve', 'database_operation_failed', field='port', value=ports[2])
            assert fourth != rollback and db.execute("SELECT Port FROM ProfileItem WHERE IndexId='reserve'").fetchone() == (ports[0],)
            probe('old')
            recovered = change('delete', 'parent', 'core_start_failed')
            assert recovered != rollback and db.execute("SELECT Remarks FROM ProfileItem WHERE IndexId='parent'").fetchone() == ('Parent',)
            probe('old')

            def start_feed():
                class Feed(http.server.BaseHTTPRequestHandler):
                    def do_GET(self):
                        body = self.server.feeds[self.path].encode()
                        self.send_response(200)
                        self.send_header('Content-Length', str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)

                    def log_message(self, *args):
                        pass

                feed = stack.enter_context(http.server.ThreadingHTTPServer(('127.0.0.1', 0), Feed))
                feed.feeds = {}
                threading.Thread(target=feed.serve_forever, daemon=True).start()
                stack.callback(feed.shutdown)
                return feed

            feed = start_feed()
            base = f'http://127.0.0.1:{feed.server_port}/'
            with db:
                db.execute("UPDATE SubItem SET Url=?, Enabled=1 WHERE Id='sub'", (base+'sub',))
                db.execute("UPDATE ProfileItem SET IsSub=1 WHERE IndexId='reserve'")
                db.executemany("INSERT INTO SubItem(Id,Remarks,Url,Enabled) VALUES (?,?,?,1)",
                               [(key, key, base+key) for key in ('other-sub','files')])
            feed.feeds['/other-sub'] = f'socks://127.0.0.1:{ports[0]}#Unrelated'
            assert change('refreshSubscription', 'other-sub') == recovered
            assert db.execute("SELECT COUNT(*) FROM ProfileItem WHERE Subid='other-sub'").fetchone() == (1,)
            feed.feeds['/sub'] = f'socks://127.0.0.1:{ports[1]}#Active%20reserve'
            refreshed = change('refreshSubscription', 'sub')
            assert refreshed != recovered
            assert db.execute("SELECT Port FROM ProfileItem WHERE IndexId='reserve'").fetchone() == (ports[1],)
            probe('new')
            assert change('refreshSubscription', 'sub') == refreshed
            feed.feeds['/sub'] = f'socks://127.0.0.1:{ports[2]}#Active%20reserve'
            restored = change('refreshSubscription', 'sub')
            assert restored != refreshed
            assert db.execute("SELECT Port FROM ProfileItem WHERE IndexId='reserve'").fetchone() == (ports[1],)
            probe('new')

            expected_root = 'reserve'
            ordinary = change('select', expected_root)
            feed.feeds['/sub'] = f'socks://127.0.0.1:{ports[0]}#Active%20reserve'
            assert change('refreshSubscription', 'sub') != ordinary
            probe('old')

            file_config = {'remarks':'File fixture', 'inbounds':[{'listen':'127.0.0.1','port':inbound,'protocol':'http'}],
                           'outbounds':[{'tag':'proxy','protocol':'socks','settings':{'servers':[{'address':'127.0.0.1','port':ports[1]}]}}]}
            feed.feeds['/files'] = json.dumps(file_config)
            change('refreshSubscription', 'files')
            expected_root, old_file = db.execute("SELECT IndexId,Address FROM ProfileItem WHERE Subid='files'").fetchone()
            serving_file = change('select', expected_root)
            probe('new')
            # The candidate must fail to start (another live socket owns this TCP port).
            file_config['inbounds'][0]['port'] = ports[2]
            feed.feeds['/files'] = json.dumps(file_config)
            assert change('refreshSubscription', 'files') != serving_file
            assert db.execute("SELECT Address FROM ProfileItem WHERE IndexId=?", (expected_root,)).fetchone() == (old_file,)
            assert sorted(path.name for path in folder.glob('v2raym-import-*.json')) == [old_file]
            probe('new')
            print(f'PASS subscription {nested_type}: active group and ordinary node changed peers; unrelated and identical feeds kept session; database and file startup failures restored previous forwarding')
        finally:
            host.stdin.close()
            try:
                host.wait(timeout=8)
            except subprocess.TimeoutExpired:
                host.kill()
                host.wait()
            host.stdout.close()
        assert host.returncode == 0
        print(f'PASS nested group {nested_type}: member edits, moves and deletions reached updated peers; invalid edits kept the session; write and Xray startup failures restored data and forwarding')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('checker', type=Path)
    args = parser.parse_args()
    for kind in [101, 102]:
        verify(args.app.resolve(), args.checker.resolve(), kind)
