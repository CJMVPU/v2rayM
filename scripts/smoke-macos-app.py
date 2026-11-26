#!/usr/bin/env python3
"""Exercise the native client against loopback fixtures, without changing system proxy settings."""
import argparse
import base64
import io
import zipfile
import http.server
import json
import sqlite3
import os
import random
from pathlib import Path
import select
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time


def free_port():
    # The checker also binds adjacent settings/metrics ports. Avoid the macOS
    # ephemeral client range: a health request can otherwise claim port + 4
    # between fixture setup and a core restart.
    for _ in range(100):
        port = random.SystemRandom().randrange(20000, 45000)
        sockets = []
        try:
            for offset in range(6):
                for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
                    sock = socket.socket(socket.AF_INET, kind)
                    sockets.append(sock)
                    sock.bind(('127.0.0.1', port + offset))
            return port
        except OSError:
            pass
        finally:
            for sock in sockets:
                sock.close()
    raise RuntimeError('No free loopback fixture port block')


def receive(sock, count):
    result = b''
    while len(result) < count:
        value = sock.recv(count - len(result))
        if not value:
            raise ConnectionError('Unexpected fixture EOF')
        result += value
    return result


def check_host_fixture(app, checker, root, inbound, peer, target):
    config = root / 'data/guiConfigs'
    config.mkdir(parents=True)
    defaults = app / 'Contents/Resources/V2rayMNative_V2rayMKit.bundle/Contents/Resources/RuntimeDefaults/settings.json'
    settings = json.loads(defaults.read_text())
    settings['Inbound'][0].update(LocalPort=inbound, AllowLANConn=False)
    settings['IndexId'] = 'fixture'
    (config / 'guiNConfig.json').write_text(json.dumps(settings))
    with sqlite3.connect(config / 'guiNDB.db') as db:
        db.execute('CREATE TABLE ProfileItem (IndexId varchar PRIMARY KEY, ConfigType int, Remarks varchar, Address varchar, Port int)')
        db.execute("INSERT INTO ProfileItem VALUES ('fixture',4,'Local peer','127.0.0.1',?)", [peer])
        db.execute('CREATE TABLE RoutingItem (Id varchar PRIMARY KEY, Remarks varchar, RuleSet varchar, IsActive int)')
        db.execute("INSERT INTO RoutingItem VALUES ('route','Fixture',?,1)",
                   [json.dumps([dict(id='fixture', enabled=True, port='1-65535', outboundTag='proxy')])])
    command = [str(checker), '--serve-host-fixture', str(root / 'data'), 'fixture', str(app.resolve())]
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as host:
        try:
            if not select.select([host.stdout], [], [], 30)[0]:
                raise RuntimeError('Timed out waiting for the restored native Xray session')
            pid = host.stdout.readline().strip()
            if not pid.isdigit():
                host.stdin.close()
                raise RuntimeError('Native fixture startup failed: ' + host.stderr.read())
            if int(pid) != host.pid or subprocess.run(['/usr/bin/pgrep', '-P', pid, '-x', 'xray'], stdout=subprocess.DEVNULL).returncode != 1:
                raise RuntimeError('Ordinary forwarding did not stay in the host PID')
            body = subprocess.check_output(['/usr/bin/curl', '--fail', '--silent', '--max-time', '10', '--noproxy', '',
                                            '--proxy', f'http://127.0.0.1:{inbound}', f'http://native-check.invalid:{target}/traffic'])
            if body != b'v2rayM-local-traffic-ok':
                raise RuntimeError('Unexpected loopback response')
        finally:
            host.stdin.close()
            try:
                host.wait(timeout=20)
            except subprocess.TimeoutExpired:
                host.kill()
                host.wait()
                raise
        if host.returncode:
            raise RuntimeError(host.stderr.read())
    if subprocess.run(['/bin/ps', '-p', pid], stdout=subprocess.DEVNULL).returncode == 0:
        raise RuntimeError('Fixture child survived shutdown')
    if list((root / 'data/guiTemps/xray').glob('*/config.json')):
        raise RuntimeError('Fixture configuration survived shutdown')


def check_custom_fixture(app, checker, root, inbound, peer, target, refused_port):
    config = root / 'guiConfigs'
    config.mkdir(parents=True)
    defaults = app / 'Contents/Resources/V2rayMNative_V2rayMKit.bundle/Contents/Resources/RuntimeDefaults/settings.json'
    settings = json.loads(defaults.read_text())
    settings['Inbound'][0].update(LocalPort=inbound, AllowLANConn=False)
    internal = free_port()
    while abs(internal - inbound) < 20:
        internal = free_port()
    settings['SpeedTestItem'].update(SpeedPingTestUrl=f'http://native-check.invalid:{target}/probe',
                                     SpeedTestUrl=f'http://native-check.invalid:{target}/download',
                                     IPAPIUrl=f'http://native-check.invalid:{target}/ipinfo')
    (config / 'guiNConfig.json').write_text(json.dumps(settings))
    document = dict(dns=dict(hosts={'legacy-custom.invalid': '127.0.0.1'}, servers=['localhost']),
                    log=dict(loglevel='warning', access=str(root / 'custom-access.log')),
                    inbounds=[dict(tag='entry', protocol='socks', listen='127.0.0.1', port=internal, settings=dict(auth='noauth'))],
                    outbounds=[dict(tag='again', protocol='loopback', settings=dict(inboundTag='second-pass')),
                               dict(tag='peer', protocol='socks', settings=dict(address='127.0.0.1', port=peer)),
                               dict(tag='direct', protocol='freedom', settings=dict(domainStrategy='ForceIPv4')),
                               dict(tag='deny', protocol='blackhole')],
                    routing=dict(domainStrategy='AsIs', rules=[dict(type='field', inboundTag='unused,other', outboundTag='deny'),
                                        dict(type='field', inboundTag='entry', outboundTag='again'),
                                        dict(type='field', domain=['full:legacy-custom.invalid'], outboundTag='direct'),
                                        dict(type='field', network='tcp', outboundTag='peer')]))
    (config / 'custom.json').write_text(json.dumps(document))
    with sqlite3.connect(config / 'guiNDB.db') as db:
        db.execute('CREATE TABLE ProfileItem (IndexId varchar PRIMARY KEY, ConfigType int, CoreType int, Address varchar, PreSocksPort int, Port int)')
        db.execute("INSERT INTO ProfileItem VALUES ('custom',2,2,'custom.json',?,0)", [internal])
        db.executemany("INSERT INTO ProfileItem VALUES (?,4,2,'127.0.0.1',NULL,?)", [('probe-good', peer), ('probe-bad', refused_port)])
        db.execute('ALTER TABLE ProfileItem ADD ConfigVersion int')
        db.execute('ALTER TABLE ProfileItem ADD ProtoExtra varchar')
        db.execute('ALTER TABLE ProfileItem ADD Remarks varchar')
        for name, mode in [('leastping', 0), ('fallback', 1), ('random', 2), ('rr', 3), ('leastload', 4)]:
            # Non-health-based groups use two reachable members. A health-aware
            # group must identify the working exit despite the first member failing.
            first = 'probe-good' if mode in (2, 3) else 'probe-bad'
            extra = json.dumps(dict(MultipleLoad=mode, ChildItems=f'{first},probe-good'))
            db.execute("INSERT INTO ProfileItem(IndexId,ConfigType,CoreType,ConfigVersion,ProtoExtra,Remarks) VALUES (?,101,2,4,?,?)",
                       ['group-' + name, extra, name])
        db.execute("CREATE TABLE ProfileExItem (IndexId varchar PRIMARY KEY, Delay integer, Speed float)")
        db.execute("INSERT INTO ProfileExItem VALUES ('probe-bad',10,234.5)")
        db.execute('CREATE TABLE RoutingItem (Id varchar PRIMARY KEY, RuleSet varchar, IsActive int)')
        db.execute("INSERT INTO RoutingItem VALUES ('route',?,1)",
                   [json.dumps([dict(enabled=True, port='1-65535', outboundTag='proxy')])])
    subprocess.run([str(checker), '--check-custom-fixture', str(app.resolve()), str(root), str(target), str(inbound)], check=True, timeout=50)
    with sqlite3.connect(config / 'guiNDB.db') as db:
        good = db.execute("SELECT Delay, Speed, IpInfo FROM ProfileExItem WHERE IndexId='probe-good'").fetchone()
        bad = db.execute("SELECT Delay, Speed FROM ProfileExItem WHERE IndexId='probe-bad'").fetchone()
        if not good or not good[0] > 0 or not (good[1] or 0) > 0 or good[2] != "🇯🇵(JP) 192.0.2.7" or bad != (-1, 0):
            raise RuntimeError(f'Wrong diagnostic results for selected nodes: good={good} bad={bad}')
    if list((root / 'guiTemps/xray').glob('*/config.json')):
        raise RuntimeError('Custom configuration survived shutdown')


def check(app, checker, host_fixture_only=False):
    subprocess.run([sys.executable, str(Path(__file__).with_name("test-active-group-edits.py")), str(app), str(checker)], check=True, timeout=60)
    visited_socks = []
    class Socks(socketserver.BaseRequestHandler):
        def handle(self):
            client = self.request
            client.settimeout(15)
            try:
                version, count = receive(client, 2)
                methods = receive(client, count)
                if version != 5 or 0 not in methods:
                    return
                client.sendall(b'\x05\x00')
                version, command, _, kind = receive(client, 4)
                if kind == 1:
                    host = socket.inet_ntoa(receive(client, 4))
                elif kind == 3:
                    host = receive(client, receive(client, 1)[0]).decode()
                elif kind == 4:
                    host = socket.inet_ntop(socket.AF_INET6, receive(client, 16))
                else:
                    return
                port = int.from_bytes(receive(client, 2), 'big')
                if command != 1 or host not in {'native-check.invalid', '127.0.0.1'} or port != http_server.server_address[1]:
                    client.sendall(b'\x05\x02\x00\x01' + bytes(6))
                    return
                visited_socks.append(host)
                with socket.create_connection(('127.0.0.1', port), timeout=10) as remote:
                    client.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01' + port.to_bytes(2, 'big'))
                    while True:
                        readable, _, _ = select.select([client, remote], [], [], 10)
                        if not readable:
                            return
                        for source in readable:
                            data = source.recv(65536)
                            if not data:
                                return
                            (remote if source is client else client).sendall(data)
            except (OSError, ConnectionError):
                return
    class HTTP(http.server.BaseHTTPRequestHandler):
        dat_downloads = 0

        dav_files = {}
        dav_reads = 0

        def dav_allowed(self):
            auth = 'Basic ' + base64.b64encode(b'fixture:local-only').decode()
            if self.headers.get('Authorization') == auth and self.path.startswith('/dav/fixture'):
                return True
            self.send_error(403)
            return False

        def do_MKCOL(self):
            if self.dav_allowed():
                self.send_response(405)
                self.end_headers()

        def do_PUT(self):
            if self.dav_allowed():
                HTTP.dav_files[self.path] = self.rfile.read(int(self.headers['Content-Length']))
                self.send_response(201)
                self.end_headers()

        def do_DELETE(self):
            if self.dav_allowed():
                del HTTP.dav_files[self.path]
                self.send_response(204)
                self.end_headers()

        def do_HEAD(self):
            if self.path == '/probe':
                self.send_response(204)
                self.end_headers()
            else:
                self.send_error(404)

        def do_GET(self):
            def hold_geo(name):
                folder = root / 'geo-data'
                (folder / (name + '-start')).touch()
                deadline = time.monotonic() + 20
                while not (folder / (name + '-release')).exists() and time.monotonic() < deadline:
                    time.sleep(0.05)

            payload = (f'socks://127.0.0.1:{socks_server.server_address[1]}#Subscription%20fixture'.encode()
                       if self.path == '/subscription' else b'v2rayM-local-traffic-ok')
            if self.path == '/probe':
                time.sleep(0.015)
            elif self.path == '/ipinfo':
                payload = b'{"clientIp":"192.0.2.7","location":{"country_code":"JP"}}'
            elif self.path == '/download':
                payload = bytes(256 * 1024)
            elif self.path == '/hold-routes':
                hold_geo('fixture-route')
                payload = b'{"version":"fixture","routingItems":[]}'
            if self.path in {'/dat/geoip.dat', '/dat/geosite.dat'}:
                HTTP.dat_downloads += 1
                dat = app / 'Contents/Resources/Backend/bin' / self.path.rsplit('/', 1)[1]
                payload = dat.read_bytes()
                if HTTP.dat_downloads == 3:
                    hold_geo('fixture-busy-geo')
                if HTTP.dat_downloads == 9:
                    (root / 'geo-data/fixture-geo-started').touch()
                    deadline = time.monotonic() + 15
                    while not (root / 'geo-data/fixture-geo-release').exists() and time.monotonic() < deadline:
                        time.sleep(0.05)
                if 5 <= HTTP.dat_downloads <= 6:
                    # Valid first tag, truncated trailing protobuf record. A first-tag-only probe accepts it.
                    payload += b'\x0a\x05\x0a\x01X\x12'
                elif 7 <= HTTP.dat_downloads <= 8:
                    # A valid one-country dataset passes the DAT check but lacks tags used
                    # by the serving config. Xray must reject that config and restore service.
                    end = 1
                    length = 0
                    for shift in range(0, 35, 7):
                        byte = payload[end]
                        end += 1
                        length |= (byte & 127) << shift
                        if byte < 128:
                            break
                    payload = payload[:end + length]
                elif dat.name == 'geoip.dat':
                    # Only one file differs from the bundled pair. The next pair repeats it exactly.
                    payload += b'\x0a\x09\x0a\x07FIXTURE'
            if self.path.startswith(('/regional/russia/', '/regional/iran/')):
                _, _, region, name = self.path.split('/')
                if name in ('geoip.dat', 'geosite.dat'):
                    payload = (app / 'Contents/Resources/Backend/bin' / name).read_bytes()
                elif name == 'simple_dns.json':
                    payload = json.dumps(dict(DirectDNS='127.0.0.1', RemoteDNS='127.0.0.1', Hosts='fixture.example 127.0.0.1')).encode()
                elif name == 'v2ray.json':
                    payload = b'{"UseSystemHosts":false}'
                elif name == 'template.json':
                    rules_url = f'http://127.0.0.1:{http_server.server_address[1]}/regional/{region}/rules.json'
                    payload = json.dumps(dict(version=region, routingItems=[dict(remarks='loopback', url=rules_url)])).encode()
                elif name == 'rules.json':
                    rules = [dict(enabled=True, port='1-65535', outboundTag='proxy')]
                    if region == 'iran':
                        rules.insert(0, dict(enabled=True, ip=['geoip:v2raym-nonexistent-fixture'], outboundTag='block'))
                    payload = json.dumps(rules).encode()
            if self.path == '/dav/fixture/backup.zip':
                if not self.dav_allowed():
                    return
                HTTP.dav_reads += 1
                payload = HTTP.dav_files[self.path]
                if HTTP.dav_reads == 2:
                    # Valid old archive format, but this listener belongs to the fixture server.
                    changed = io.BytesIO()
                    with zipfile.ZipFile(io.BytesIO(payload)) as original, zipfile.ZipFile(changed, 'w') as replacement:
                        for entry in original.infolist():
                            content = original.read(entry)
                            if entry.filename.endswith('/guiNConfig.json'):
                                settings = json.loads(content)
                                settings['Inbound'][0]['LocalPort'] = http_server.server_address[1]
                                content = json.dumps(settings).encode()
                            replacement.writestr(entry, content)
                    payload = changed.getvalue()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        def log_message(self, *_):
            pass
    class Threaded(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True
    with Threaded(('127.0.0.1', 0), Socks) as socks_server, http.server.ThreadingHTTPServer(('127.0.0.1', 0), HTTP) as http_server:
        threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in (socks_server, http_server)]
        for thread in threads:
            thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix='v2raym-native-check-') as temporary:
                root = Path(temporary)
                proxy_port = free_port()
                if host_fixture_only:
                    check_host_fixture(app, checker, root, proxy_port, socks_server.server_address[1], http_server.server_address[1])
                    if visited_socks != ['native-check.invalid']:
                        raise RuntimeError('Expected exactly one traversal of the selected SOCKS node')
                    print('Native host fixture passed: active edit, rollback, peer traversal, shutdown and reopen.')
                    return
                try:
                    with socket.socket() as refused:
                        refused.bind(('127.0.0.1', 0))
                        check_custom_fixture(app, checker, root / "custom-data", proxy_port, socks_server.server_address[1],
                                             http_server.server_address[1], refused.getsockname()[1])
                    result = subprocess.run([str(checker), str(app.resolve()), str(root / 'data'),
                                    str(http_server.server_address[1]), str(proxy_port), str(socks_server.server_address[1])],
                                   check=True, timeout=180, stderr=subprocess.PIPE, text=True)
                    if result.stderr:
                        print(result.stderr, end='', flush=True)
                    if len(visited_socks) < 2:
                        raise RuntimeError('Each selected node must forward traffic through the SOCKS fixture.')
                    # Copy only the runtime inputs needed for this flow. Any attempt to execute
                    # a bundled Xray during validation, reconnect or rollback will fail this test.
                    geo_bundle = root / 'geo-fixture.app'
                    for relative in ('Contents/Frameworks/libV2rayMXray.dylib',
                                     'Contents/Resources/Backend/bin/geoip.dat', 'Contents/Resources/Backend/bin/geosite.dat'):
                        link = geo_bundle / relative
                        link.parent.mkdir(parents=True, exist_ok=True)
                        link.symlink_to((app / relative).resolve())
                    subprocess.run([str(checker), '--check-geo-fixture', str(geo_bundle), str(root / 'geo-data'),
                                    str(http_server.server_address[1]), str(proxy_port), str(socks_server.server_address[1])],
                                   check=True, timeout=120)
                except BaseException as error:
                    log = root / 'data/guiLogs/native-xray.log'
                    if log.is_file():
                        # Fixture inputs contain no real subscription tokens or credentials.
                        print(log.read_text(errors='replace')[-12000:])
                    # Keep the checker's actual failure after the backend diagnostic
                    # tail, where it remains visible next to the subprocess traceback.
                    if isinstance(error, subprocess.CalledProcessError) and error.stderr:
                        print(error.stderr, end='', flush=True)
                        if os.environ.get('GITHUB_ACTIONS') == 'true':
                            message = error.stderr.strip().replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
                            print(f'::error title=Native product check failed::{message}', flush=True)
                    raise
        finally:
            socks_server.shutdown()
            http_server.shutdown()
    print('Native app smoke passed; no system-wide proxy settings were changed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('checker', type=Path)
    parser.add_argument('--host-fixture-only', action='store_true', help='Exercise native session ownership, edit rollback and loopback forwarding')
    arguments = parser.parse_args()
    check(arguments.app, arguments.checker, arguments.host_fixture_only)
