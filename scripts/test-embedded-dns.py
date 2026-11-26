#!/usr/bin/env python3
"""Exercise the generated resolver policy with the packaged core, local DNS peers and synthetic utun frames."""
import argparse
import contextlib
import ipaddress
import json
import secrets
import select
import socket
import socketserver
import sqlite3
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from tun_frame_fixture import TunnelFlow


def exact(sock, length):
    data = bytearray()
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise EOFError
        data.extend(chunk)
    return bytes(data)


def read_message(sock):
    return exact(sock, struct.unpack("!H", exact(sock, 2))[0])


def frame(message):
    return struct.pack("!H", len(message)) + message


def question(packet):
    pos = 12
    labels = []
    while packet[pos]:
        size = packet[pos]
        labels.append(packet[pos + 1:pos + 1 + size].decode("ascii"))
        pos += 1 + size
    return ".".join(labels), struct.unpack_from("!H", packet, pos + 1)[0], pos + 5


def query(domain, kind):
    labels = b"".join(bytes([len(label)]) + label.encode("ascii") for label in domain.split("."))
    return secrets.token_bytes(2) + bytes.fromhex("01000001000000000000") + labels + b"\0" + struct.pack("!HH", kind, 1)


class Resolver(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            packet = read_message(self.request)
            name, kind, end = question(packet)
            self.server.events.append((name, self.server.role, time.monotonic()))
            case = name.split(".")[0]
            if self.server.role == "direct" and case == "timeout":
                # No DNS response: the actual Xray client must reach its deadline.
                self.server.closed.wait(8)
                return
            if self.server.role == "direct" and case == "hit":
                time.sleep(0.12)  # Let remote win the wire race when parallel queries are enabled.
            if kind == 28:
                address = "2001:db8::11" if self.server.role == "direct" else "2001:db8::22"
            elif self.server.role == "remote":
                address = "203.0.113.22"
            else:
                address = "198.51.100.11" if case == "mismatch" else "192.0.2.11"
            raw = ipaddress.ip_address(address).packed
            answer = packet[:2] + bytes.fromhex("81800001000100000000") + packet[12:end]
            answer += bytes.fromhex("c00c") + struct.pack("!HHIH", kind, 1, 1, len(raw)) + raw
            self.request.sendall(frame(answer))
        except (EOFError, OSError):
            pass  # A speculative query can be cancelled after a higher-priority reply.


class Socks(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            version, methods = exact(self.request, 2)
            assert version == 5
            exact(self.request, methods)
            self.request.sendall(b"\x05\0")
            assert exact(self.request, 4) == b"\x05\x01\0\x01"
            host = socket.inet_ntoa(exact(self.request, 4))
            port = struct.unpack("!H", exact(self.request, 2))[0]
            assert host == "127.0.0.1" and port in self.server.allowed_ports
            with socket.create_connection((host, port), timeout=8) as peer:
                self.request.sendall(bytes.fromhex("050000017f0000010000"))
                packet = read_message(self.request)
                self.server.events.append((question(packet)[0], "socks", time.monotonic()))
                peer.sendall(frame(packet))
                self.request.sendall(frame(read_message(peer)))
        except (EOFError, OSError):
            pass


def start_server(stack, handler):
    server = stack.enter_context(socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler))
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    stack.callback(server.shutdown)
    return server


def geo_assets(directory):
    # One GeoSite and one GeoIP entry; each length fits a one-byte protobuf varint.
    def field(tag, data):
        assert len(data) < 128
        return bytes([tag, len(data)]) + data
    region = field(10, b"LAB")
    domain = b"\x08\x02" + field(18, b"regional.invalid")  # RootDomain
    cidr = field(10, socket.inet_aton("192.0.2.0")) + b"\x10\x18"
    (directory / "geosite.dat").write_bytes(field(10, region + field(18, domain)))
    (directory / "geoip.dat").write_bytes(field(10, region + field(18, cidr)))


def prepare_store(directory, peer_port):
    config = directory / "guiConfigs"
    config.mkdir()
    with sqlite3.connect(config / "guiNDB.db") as db:
        db.executescript("""
            CREATE TABLE ProfileItem (IndexId TEXT PRIMARY KEY, ConfigType INT, Remarks TEXT, Address TEXT, Port INT);
            CREATE TABLE RoutingItem (Id TEXT, Remarks TEXT, RuleSet TEXT, IsActive INT);
            CREATE TABLE DNSItem (CoreType INT);
            CREATE TABLE FullConfigTemplateItem (CoreType INT);
            CREATE TABLE SubItem (Id TEXT, PrevProfile TEXT, NextProfile TEXT);
        """)
        db.execute("INSERT INTO ProfileItem VALUES ('node',4,'Local SOCKS','127.0.0.1',?)", [peer_port])
        rules = [dict(domain=["domain:proxy.invalid"], outboundTag="proxy"),
                 dict(domain=["geosite:lab"], outboundTag="direct"),
                 dict(ip=["::/0"], outboundTag="direct")]
        db.execute("INSERT INTO RoutingItem VALUES ('fixture','Fixture',?,1)", [json.dumps(rules)])
    return config


def configured_servers(app, checker, directory, settings, parallel, dns_port):
    settings["SimpleDNSItem"]["ParallelQuery"] = parallel
    (directory / "guiConfigs/guiNConfig.json").write_text(json.dumps(settings))
    configs = {}
    for mode, flag in [("proxy", "--generate-client"), ("tun", "--generate-tun-client")]:
        config = json.loads(subprocess.check_output([checker, flag, directory, "node"], timeout=10))
        if mode == "proxy":
            # The ordinary client has no DNS listener. Expose its actual built-in resolver
            # on loopback without replacing any generated upstreams or outbound routing.
            config["inbounds"].append(dict(tag="fixture-dns", listen="127.0.0.1", port=dns_port,
                                           protocol="dokodemo-door", settings=dict(address="127.0.0.1", port=53, network="udp")))
            config["outbounds"].append(dict(tag="fixture-dns-out", protocol="dns"))
            config["routing"]["rules"].insert(0, dict(inboundTag=["fixture-dns"], outboundTag="fixture-dns-out"))
        else:
            # A socketpair has no kernel interface, gateway or routes. Keep Xray's actual
            # TUN packet handler and DNS capture rules; omit host network provisioning.
            tunnel = next(item for item in config["inbounds"] if item["protocol"] == "tun")
            for key in ("autoOutboundsInterface", "autoSystemRoutingTable", "gateway", "dns"):
                tunnel["settings"].pop(key, None)
        configs[mode] = config
        (directory / (mode + ".json")).write_text(json.dumps(config))
    assert configs["proxy"]["dns"] == configs["tun"]["dns"], "resolver configuration diverged between modes"


def run(app, checker):
    with tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack:
        directory = Path(tmp)
        events = []
        closed = threading.Event()
        peers = {}
        for role in ("direct", "remote"):
            resolver = start_server(stack, Resolver)
            resolver.role, resolver.events, resolver.closed = role, events, closed
            peers[role] = resolver.server_address[1]
        socks = start_server(stack, Socks)
        socks.events, socks.allowed_ports = events, set(peers.values())
        stack.callback(closed.set)
        prepare_store(directory, socks.server_address[1])
        geo_assets(directory)
        defaults = app / "Contents/Resources/V2rayMNative_V2rayMKit.bundle/Contents/Resources/RuntimeDefaults/settings.json"
        settings = json.loads(defaults.read_text())
        # The generated mixed port and the test DNS inlet must both be local and unused.
        with socket.socket() as mixed, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as dns:
            mixed.bind(("127.0.0.1", 0))
            dns.bind(("127.0.0.1", 0))
            dns_port = dns.getsockname()[1]
            settings["Inbound"][0].update(LocalPort=mixed.getsockname()[1], AllowLANConn=False)
        settings["SimpleDNSItem"].update(DirectDNS=f"tcp://127.0.0.1:{peers['direct']}",
                                         RemoteDNS=f"tcp://127.0.0.1:{peers['remote']}", DirectExpectedIPs="geoip:lab",
                                         BootstrapDNS="127.0.0.1", AddCommonHosts=False, UseSystemHosts=False)
        fd, wire = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        stack.enter_context(fd)
        stack.enter_context(wire)
        core = subprocess.Popen([checker, "--serve-embedded-fixture", app, directory, str(fd.fileno())], pass_fds=[fd.fileno()],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        def command(action):
            core.stdin.write((action + "\n").encode())
            core.stdin.flush()
            if not select.select([core.stdout], [], [], 12)[0]:
                raise TimeoutError(f"embedded core did not acknowledge {action}")
            reply = core.stdout.readline()
            assert reply and json.loads(reply)["action"] == action, f"embedded core failed at {action}"
        try:
            for parallel in (False, True):
                configured_servers(app, checker, directory, settings, parallel, dns_port)
                for mode in ("proxy", "tun"):
                    command(mode)
                    for index, (case, zone, kind, expected) in enumerate([
                        ("hit", "regional", 1, "192.0.2.11"),
                        ("mismatch", "regional", 1, "203.0.113.22"),
                        ("timeout", "regional", 1, "203.0.113.22"),
                        ("only", "proxy", 1, "203.0.113.22"),
                        ("default", "unmatched", 28, "2001:db8::11"),
                    ]):
                        name = f"{case}.{mode}{int(parallel)}.{zone}.invalid"
                        packet = query(name, kind)
                        if mode == "tun":
                            flow = TunnelFlow(wire, socket.AF_INET, socket.IPPROTO_UDP, 26300 + index, 53)
                            flow.send(packet)
                            answer = flow.receive()[8:]
                        else:
                            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                                client.settimeout(7)
                                client.connect(("127.0.0.1", dns_port))
                                client.send(packet)
                                answer = client.recv(65535)
                        received = [(role, stamp) for domain, role, stamp in events if domain == name]
                        seen = [role for role, _ in received]
                        assert answer[:2] == packet[:2] and struct.unpack_from("!H", answer, 6)[0] == 1, (name, seen, answer.hex())
                        assert answer.endswith(ipaddress.ip_address(expected).packed), (name, expected, seen, answer.hex())
                        remote = case in ("mismatch", "timeout", "only") or (case == "hit" and parallel)
                        expected_roles = ({"direct"} if case != "only" else set()) | ({"remote", "socks"} if remote else set())
                        assert set(seen) == expected_roles, (name, seen, expected_roles)
                        if remote and case != "only" and not parallel:
                            assert seen[0] == "direct", (name, seen)
                        if case == "timeout" and not parallel:
                            # The direct peer never writes a byte. Serial fallback must
                            # wait for Xray's four-second resolver timeout before dialing.
                            stamps = dict(received)
                            assert stamps["socks"] - received[0][1] >= 3, (name, received)
                        print(f"PASS {name} {expected} via {','.join(seen)}", flush=True)
                    command("stop")
        finally:
            core.stdin.close()
            try:
                core.wait(timeout=8)
            except subprocess.TimeoutExpired:
                core.kill()
                core.wait()
            core.stdout.close()
        assert core.returncode == 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--checker", type=Path, required=True)
    args = parser.parse_args()
    run(args.app.resolve(), args.checker.resolve())
