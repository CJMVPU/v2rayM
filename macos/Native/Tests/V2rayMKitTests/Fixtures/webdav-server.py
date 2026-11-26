import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread


root = Path(sys.argv[1])


class WebDAV(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    @property
    def resource(self):
        return root / self.path.strip("/")

    def reply(self, status, data=b""):
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_MKCOL(self):
        if self.path.rstrip("/") == "/shared/team":
            return self.reply(403)
        if self.resource.is_dir():
            return self.reply(405)
        if not self.resource.parent.is_dir():
            return self.reply(409)
        self.resource.mkdir()
        self.reply(201)

    def do_PUT(self):
        self.resource.write_bytes(self.rfile.read(int(self.headers["Content-Length"])))
        self.reply(201)

    def do_GET(self):
        if self.path.startswith("/denied/"):
            return self.reply(403)
        data = self.resource.read_bytes()
        self.reply(200, data + b"x" if self.path.startswith("/corrupt/") else data)

    def do_DELETE(self):
        self.resource.unlink()
        self.reply(204)


server = ThreadingHTTPServer(("127.0.0.1", 0), WebDAV)
Thread(target=server.serve_forever, daemon=True).start()
print(server.server_port, flush=True)
sys.stdin.read()
