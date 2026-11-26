"""Loopback peer for GeoDownloadTests. EOF on stdin stops the server."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys
from threading import Thread
import time


class Peer(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        scenario, name = self.path.strip('/').split('/')
        if scenario == 'redirect':
            self.send_response(302)
            self.send_header('Location', '/success/' + name)
            self.end_headers()
            return
        self.send_response(503 if scenario == 'failure' else 200)
        self.send_header('Content-Type', 'application/octet-stream')
        size = {'success': 1024 * 1024, 'oversized': 33554433}.get(scenario, 100)
        if scenario != 'unbounded':
            self.send_header('Content-Length', str(size))
        self.end_headers()
        try:
            if scenario == 'success':
                self.wfile.write(b'v' * size)
            elif scenario == 'unbounded':
                block = b'x' * (128 * 1024)
                for _ in range(257):
                    self.wfile.write(block)
            elif scenario != 'idle':
                for _ in range(100):
                    self.wfile.write(b'x')
                    self.wfile.flush()
                    time.sleep(0.15)
            else:
                time.sleep(8)
        except OSError:
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Peer)
Thread(target=server.serve_forever, daemon=True).start()
print(server.server_port, flush=True)
sys.stdin.read()
