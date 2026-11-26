#!/usr/bin/env python3
"""Exercise the Swift host and repaired Go library without configuring macOS networking."""
import argparse
import contextlib
import http.server
import json
from pathlib import Path
import secrets
import select
import shutil
import socket
import struct
import subprocess
import tempfile
import threading

from tun_frame_fixture import check_tun_frames

def read_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError("SOCKS control socket closed")
        data.extend(chunk)
    return data


def check_socks_udp(port, target, payload):
    with socket.create_connection(('127.0.0.1', port), timeout=6) as control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.bind(('127.0.0.1', 0))
        client.settimeout(6)
        control.sendall(bytes.fromhex('050100'))
        assert read_exact(control, 2) == bytes.fromhex('0500')
        control.sendall(bytes.fromhex('05030001') + socket.inet_aton('127.0.0.1') + struct.pack('!H', client.getsockname()[1]))
        header = read_exact(control, 10)
        assert header[:4] == bytes.fromhex('05000001'), header
        relay = (socket.inet_ntoa(header[4:8]), struct.unpack('!H', header[8:])[0])
        address = socket.inet_aton('127.0.0.1') + struct.pack('!H', target.getsockname()[1])
        frame = bytes.fromhex('00000001') + address + payload
        client.sendto(frame, relay)
        packet, sender = target.recvfrom(65535)
        assert packet == payload
        target.sendto(packet, sender)
        assert client.recv(65535) == frame


def run(checker, library):
    nonce = secrets.token_bytes(24)
    class Echo(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(nonce)

        def log_message(self, *args):
            pass

    with tempfile.TemporaryDirectory() as temporary, contextlib.ExitStack() as stack:
        folder = Path(temporary)
        bundle = folder / 'Fixture.app'
        frameworks = bundle / 'Contents/Frameworks'
        frameworks.mkdir(parents=True)
        shutil.copy2(library, frameworks / library.name)
        server = stack.enter_context(http.server.HTTPServer(('127.0.0.1', 0), Echo))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        stack.callback(server.shutdown)
        with socket.socket() as free:
            free.bind(('127.0.0.1', 0))
            port = free.getsockname()[1]
        udp = stack.enter_context(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
        udp.bind(('127.0.0.1', 0))
        udp.settimeout(6)
        fd, wire = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        stack.enter_context(fd)
        stack.enter_context(wire)
        wire.settimeout(6)
        results = {}
        for mode in ('proxy', 'tun'):
            config = {'log': {'loglevel': 'none'}, 'outbounds': [{'protocol': 'freedom', 'settings': {}}]}
            if mode == 'proxy':
                config['inbounds'] = [{'listen': '127.0.0.1', 'port': port, 'protocol': 'mixed', 'settings': {'udp': True}}]
            else:
                # Darwin utun frames on a socket pair. The OS interface, routes and DNS stay out of this test.
                config['inbounds'] = [{'protocol': 'tun', 'settings': {'name': 'utun9999', 'MTU': 1500}}]
                config['inbounds'][0]['tag'] = 'tun'
                config['dns'] = {'servers': ['localhost'], 'hosts': {'full:geo.invalid': '192.0.2.42'}}
                config['outbounds'] = [
                    {'protocol': 'freedom', 'tag': 'udp', 'settings': {'redirect': f'127.0.0.1:{udp.getsockname()[1]}'}},
                    {'protocol': 'freedom', 'tag': 'tcp', 'settings': {'redirect': f'127.0.0.1:{server.server_port}'}},
                    {'protocol': 'dns', 'tag': 'dns'}]
                config['routing'] = {'rules': [
                    {'inboundTag': ['tun'], 'port': '53', 'outboundTag': 'dns'},
                    {'network': 'tcp', 'outboundTag': 'tcp'}]}
            (folder / (mode + '.json')).write_text(json.dumps(config))
        process = subprocess.Popen([checker, '--serve-embedded-fixture', bundle, folder, str(fd.fileno())],
                                   pass_fds=(fd.fileno(),), stdin=subprocess.PIPE, stdout=subprocess.PIPE)

        def command(text):
            process.stdin.write((text + '\n').encode())
            process.stdin.flush()
            if not select.select([process.stdout], [], [], 12)[0]:
                raise RuntimeError(f'{text} timed out')
            reply = json.loads(process.stdout.readline())
            assert reply['action'] == text and reply['pid'] == process.pid, reply
            assert '676eaf6-v2raym-darwin-bind2' in reply['version'], reply
            return reply['version']

        try:
            for cycle in range(2):
                for mode in ('proxy', 'tun'):
                    version = command(mode)
                    children = subprocess.run(['/usr/bin/pgrep', '-P', str(process.pid)], capture_output=True)
                    assert children.returncode == 1, 'Embedded session spawned a child process'
                    if mode == 'proxy':
                        curl = ['/usr/bin/curl', '--silent', '--fail', '--max-time', '6', '--noproxy', '',
                                '--proxy']
                        url = f'http://127.0.0.1:{server.server_port}/'
                        for proxy in (f'http://127.0.0.1:{port}', f'socks5h://127.0.0.1:{port}'):
                            assert subprocess.check_output([*curl, proxy, url]) == nonce
                        assert subprocess.check_output([*curl, f'http://127.0.0.1:{port}', '--proxytunnel', url]) == nonce
                        check_socks_udp(port, udp, nonce)
                    else:
                        check_tun_frames(wire, udp, nonce, cycle)
                    command('stop')
                    if mode == 'proxy':
                        with socket.socket() as probe:
                            assert probe.connect_ex(('127.0.0.1', port)) != 0
                    results[mode] = dict(version=version, pid=process.pid, cycles=cycle + 1, forwarded=True, children=0)
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=6)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            process.stdout.close()
        assert process.returncode == 0
        results['systemTunnelCreated'] = False
        return results

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checker', type=Path)
    parser.add_argument('library', type=Path)
    args = parser.parse_args()
    print(json.dumps(run(args.checker.resolve(), args.library.resolve()), indent=2))
