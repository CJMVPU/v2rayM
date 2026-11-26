"""Three loopback listeners. Each CONNECT peer permits only the next fixture listener."""
import json
import select
import socket
import subprocess
import sys
import threading
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    seen = []
    payload = b"custom-chain-target-ok"

    class Peer(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_CONNECT(self):
            address = self.server.destination
            if self.path != f"127.0.0.1:{address}":
                self.send_error(403)
                return
            with socket.create_connection(("127.0.0.1", address), timeout=4) as upstream:
                seen.append([self.server.label, self.path])
                self.send_response_only(200)
                self.end_headers()
                streams = [self.connection, upstream]
                while True:
                    readable, _, _ = select.select(streams, [], [], 8)
                    if not readable:
                        return
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        (upstream if source is self.connection else self.connection).sendall(data)

        def do_GET(self):
            if self.server.label != "target" or self.path != "/chain":
                self.send_error(404)
                return
            seen.append(["target", self.path])
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    with ExitStack() as resources:
        def server(label, destination=None):
            listener = resources.enter_context(ThreadingHTTPServer(("127.0.0.1", 0), Peer))
            listener.label = label
            listener.destination = destination
            threading.Thread(target=listener.serve_forever, daemon=True).start()
            resources.callback(listener.shutdown)
            return listener.server_port

        target = server("target")
        exit_peer = server("exit", target)
        entry = server("entry", exit_peer)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            inbound = reserve.getsockname()[1]
        print(json.dumps({"entry": entry, "exit": exit_peer, "target": target, "inbound": inbound}), flush=True)
        if sys.stdin.readline().strip() != "run":
            return
        result = subprocess.run(["/usr/bin/curl", "-q", "--silent", "--show-error", "--fail", "--max-time", "8",
                                 "--noproxy", "", "--proxy", f"http://127.0.0.1:{inbound}",
                                 f"http://127.0.0.1:{target}/chain"], capture_output=True, timeout=12)
        expected = [["entry", f"127.0.0.1:{exit_peer}"], ["exit", f"127.0.0.1:{target}"], ["target", "/chain"]]
        print(json.dumps({"visits": seen, "body": result.stdout.decode(), "error": result.stderr.decode()}), flush=True)
        if result.returncode or result.stdout != payload or seen != expected:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
