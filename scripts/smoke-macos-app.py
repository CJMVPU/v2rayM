#!/usr/bin/env python3
"""Exercise the native client against loopback fixtures, without changing system proxy settings."""
import argparse
import http.server
import random
from pathlib import Path
import select
import socket
import socketserver
import subprocess
import tempfile
import threading


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


def check(app, checker):
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
        def do_GET(self):
            payload = (f'socks://127.0.0.1:{socks_server.server_address[1]}#Subscription%20fixture'.encode()
                       if self.path == '/subscription' else b'v2rayM-local-traffic-ok')
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
                api_port, proxy_port = free_port(), free_port()
                while abs(api_port - proxy_port) < 20:
                    proxy_port = free_port()
                try:
                    subprocess.run([str(checker), str(app.resolve()), str(root / 'data'), str(api_port),
                                    str(http_server.server_address[1]), str(proxy_port), str(socks_server.server_address[1])],
                                   check=True, timeout=180)
                    if len(visited_socks) < 2:
                        raise RuntimeError('Each selected node must forward traffic through the SOCKS fixture.')
                except BaseException:
                    log = root / 'data/guiLogs/native-backend.log'
                    if log.is_file():
                        # Fixture inputs contain no real subscription tokens or credentials.
                        print(log.read_text(errors='replace')[-12000:])
                    raise
        finally:
            socks_server.shutdown()
            http_server.shutdown()
    print('Native app smoke passed; no system-wide proxy settings were changed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('checker', type=Path)
    arguments = parser.parse_args()
    check(arguments.app, arguments.checker)
