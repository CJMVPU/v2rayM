#!/usr/bin/env python3
"""Run two legacy Xray configurations in one Go image, using loopback and temporary files."""
import argparse
import contextlib
import ctypes
import http.client
import http.server
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import uuid


class IPv6Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


class EchoAddress(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(self.server.server_address[0].encode())

    def log_message(self, *args):
        pass


def check_fast_probe(image, call, assets):
    class Fast(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def do_GET(self):
            self.server.hits.append(self.path)
            data = {'/ping': b'', '/ip': b'{"ip":"127.0.0.1"}', '/download': b'x' * 16384}[self.path]
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    begin, measure, close = image.V2rayMCoreOpenProbe, image.V2rayMCoreMeasureProbe, image.V2rayMCoreCloseProbe
    for func, argc in [(begin, 3), (measure, 2), (close, 1)]:
        func.argtypes, func.restype = [ctypes.c_char_p] * argc, ctypes.c_void_p
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fast) as server:
        server.hits = []
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = f'http://127.0.0.1:{server.server_port}'
            request = json.dumps(dict(action='realping', url=url + '/ping', ipURL=url + '/ip',
                                      downloadURL=url + '/download', timeout=1)).encode()
            for _ in range(4):
                key = str(uuid.uuid4())
                config = json.dumps({'outbounds': [{'tag': key + '/proxy', 'protocol': 'freedom'}]}).encode()
                assert call(begin, key.encode(), config, str(assets).encode()) is None
                try:
                    server.hits.clear()
                    answer = json.loads(call(measure, key.encode(), request))
                    assert answer['delay'] >= 1 and answer['ipInfo']['ip'] == '127.0.0.1' and answer['speed'] > 0, answer
                    assert '/ip' in server.hits and '/download' in server.hits, server.hits
                finally:
                    assert call(close, key.encode()) is None
        finally:
            server.shutdown()
    print('PASS: fast loopback realping records positive delay and completes exit IP and download probes')


def http_via_proxy(port, target):
    with socket.create_connection(('127.0.0.1', port), timeout=4) as conn:
        conn.settimeout(4)
        conn.sendall(f'GET http://scope.invalid:{target}/ HTTP/1.0\r\nHost: scope.invalid:{target}\r\nConnection: close\r\n\r\n'.encode())
        with conn.makefile('rb') as response:
            header, body = response.read().split(b'\r\n\r\n', 1)
        assert b' 200 ' in header, header
        return body.decode()


def run(library):
    image = ctypes.CDLL(str(library.resolve()))
    start, stop, free = image.V2rayMCoreStartPair, image.V2rayMCoreStop, image.V2rayMCoreFree
    start.argtypes = [ctypes.c_char_p] * 3
    start_logged = image.V2rayMCoreStartLogged
    start_logged.argtypes = [ctypes.c_char_p] * 3 + [ctypes.c_int] * 2
    start_logged.restype = ctypes.c_void_p
    drain = image.V2rayMCoreDrainLogs
    drain.argtypes, drain.restype = [], ctypes.c_void_p
    stop.argtypes = []
    start.restype = stop.restype = ctypes.c_void_p
    free.argtypes, free.restype = [ctypes.c_void_p], None

    traffic = image.V2rayMCoreTraffic
    traffic.argtypes, traffic.restype = [ctypes.POINTER(ctypes.c_longlong), ctypes.c_int], ctypes.c_int
    counts = (ctypes.c_longlong * 4)(-1, -1, -1, -1)
    assert traffic(counts, 4) == 0 and list(counts) == [-1] * 4

    def call(function, *args):
        address = function(*args)
        if address:
            try:
                return ctypes.string_at(address).decode()
            finally:
                free(address)

    with tempfile.TemporaryDirectory() as temp, contextlib.ExitStack() as stack:
        root = Path(temp)
        check_fast_probe(image, call, root)
        v4 = stack.enter_context(http.server.ThreadingHTTPServer(('127.0.0.1', 0), EchoAddress))
        target = v4.server_address[1]
        v6 = stack.enter_context(IPv6Server(('::1', target), EchoAddress))
        for server in (v4, v6):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            stack.callback(server.shutdown)
        with socket.socket() as a, socket.socket() as b:
            a.bind(('127.0.0.1', 0))
            b.bind(('127.0.0.1', 0))
            ports = [s.getsockname()[1] for s in (a, b)]
        logs = [root / 'frontend.log', root / 'custom.log']

        def document(index):
            ip = ['127.0.0.1', '::1'][index]
            return dict(env={'V2RAYM_FIXTURE_PORT': str(ports[index]), 'xray.cone.disabled': ['false', 'true'][index]},
                        log=dict(access=str(logs[index]), error=str(root / f'{index}-errors.log'), loglevel='debug'),
                        dns=dict(hosts={'scope.invalid': ip}, servers=['localhost']),
                        inbounds=[dict(tag='entry', protocol='http', listen='127.0.0.1', port='env:V2RAYM_FIXTURE_PORT')],
                        outbounds=[dict(tag='first', protocol='blackhole'),
                                   dict(tag='proxy', protocol='freedom', settings=dict(domainStrategy=['ForceIPv4', 'ForceIPv6'][index]))],
                        routing=dict(domainStrategy=['AsIs', 'IPIfNonMatch'][index],
                                     rules=[dict(type='field', inboundTag=['entry'], outboundTag='proxy')]))

        def begin(front, custom):
            return call(start, json.dumps(front).encode(), json.dumps(custom).encode(), temp.encode())

        front, custom = document(0), document(1)
        # A DNS initialization error can occur before the router has installed
        # its rules. Closing that partial graph must leave the host usable.
        bad_dns = dict(custom, dns=dict(servers=["127.0.0.1:5300"]))
        assert begin(front, bad_dns), 'expected invalid raw Xray DNS server to be rejected'
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1', ports[0]))
            occupied.listen()
            assert begin(front, custom), 'expected frontend bind failure'
            with socket.socket() as reusable:
                reusable.bind(('127.0.0.1', ports[1]))

        assert begin(front, dict(custom, env={'xray.buf.readv': 'peer-only'})), 'incompatible process-wide flags crossed the graph boundary'
        assert begin(front, dict(custom, env={'xray.tun.fd': '9999'})), 'custom configuration replaced host environment'
        with socket.socket() as spare:
            spare.bind(('127.0.0.1', 0))
            metrics_port = spare.getsockname()[1]
        front['metrics'] = dict(listen=f'127.0.0.1:{metrics_port}')
        for graph in (front, custom):
            graph['stats'] = {}
            graph['policy'] = dict(system=dict(statsOutboundUplink=True, statsOutboundDownlink=True))
        for tag in ('proxy-test', 'source-proxy-Fixture', 'direct'):
            front['outbounds'][1]['tag'] = tag
            front['routing']['rules'][0]['outboundTag'] = tag
            failure = begin(front, custom)
            assert failure is None, failure
            try:
                for index, expected in enumerate(['127.0.0.1', '::1']):
                    assert http_via_proxy(ports[index], target) == expected
                    until = time.monotonic() + 2
                    while time.monotonic() < until and not (logs[index].exists() and 'scope.invalid' in logs[index].read_text()):
                        time.sleep(.02)
                    assert 'scope.invalid' in logs[index].read_text()
                    entries = json.loads(call(drain) or '[]')
                    assert any('accepted' in line and 'scope.invalid' in line for line in entries), 'file log missing from native console'

                    if index == 0 and not logs[1].exists():
                        continue
                    if index == 0:
                        assert 'scope.invalid' not in logs[1].read_text(), 'frontend traffic was logged by custom graph'
                # The custom graph has its own traffic and counters. Only the
                # frontend should match its explicit metrics endpoint, byte for byte.
                conn = http.client.HTTPConnection('127.0.0.1', metrics_port, timeout=4)
                try:
                    conn.request('GET', '/debug/vars')
                    values = json.load(conn.getresponse())['stats']['outbound'][tag]
                finally:
                    conn.close()
                tally = [values['uplink'], values['downlink']]
                assert all(n > 0 for n in tally), tally
                expected = [0, 0] + tally if tag == 'direct' else tally + [0, 0]
                assert traffic(counts, 4) == 1 and list(counts) == expected, (list(counts), expected)
                assert traffic(counts, 3) == 0 and list(counts) == expected
            finally:
                failure = call(stop)
                assert failure is None, failure
            assert traffic(counts, 4) == 0
            for log in logs:
                log.unlink()
        print('PASS: in-process byte counters equal explicit HTTP metrics for proxy and direct and exclude the custom graph')
        front = document(0)
        # The old generated pre-SOCKS frontend always displayed logs. A hidden
        # custom profile suppresses only its own UI feed and still writes its file.
        quiet_front = dict(front, log=dict(front['log'], loglevel='error'))
        quiet_custom = dict(custom, log=dict(custom['log'], loglevel='error'))
        call(drain)
        failure = call(start_logged, json.dumps(quiet_front).encode(), json.dumps(quiet_custom).encode(), temp.encode(), -1, 0)
        assert failure is None, failure
        try:
            assert http_via_proxy(ports[1], target) == '::1'
            assert not any('accepted' in line for line in json.loads(call(drain) or '[]'))
            for _ in range(540):
                assert http_via_proxy(ports[0], target) == '127.0.0.1'
            messages = json.loads(call(drain) or '[]')
            assert sum('accepted' in line and 'scope.invalid' in line for line in messages) == 540
        finally:
            assert call(stop) is None
        print('PASS: file and UI logging coexist; hidden custom logs stay private and all 540 frontend access records arrive')
        # Exercise connection pools through the real patched transports. Every peer
        # lives in the second graph, forwards to our HTTP fixture, and closes on stop.
        identity = 'f468d922-92a2-46fd-971b-054fe27024cf'
        for network in ('grpc', 'xhttp'):
            stream = dict(network=network)
            if network == 'grpc':
                stream['grpcSettings'] = dict(serviceName='loopback')
            else:
                stream['xhttpSettings'] = dict(path='/loopback', mode='packet-up')
            primary = document(0)
            primary['outbounds'] = [dict(tag='proxy', protocol='vless', streamSettings=stream,
                                         settings=dict(vnext=[dict(address='127.0.0.1', port=ports[1],
                                                                  users=[dict(id=identity, encryption='none')])]))]
            secondary = document(1)
            secondary['outbounds'][1]['settings']['finalRules'] = [
                dict(action='allow', network='tcp', ip=['::1/128'], port=str(target))]
            secondary['inbounds'] = [dict(tag='entry', protocol='vless', listen='127.0.0.1',
                                          port=ports[1], streamSettings=stream,
                                          settings=dict(clients=[dict(id=identity)], decryption='none'))]
            for _ in range(2):
                failure = begin(primary, secondary)
                assert failure is None, failure
                try:
                    assert http_via_proxy(ports[0], target) == '::1', network
                except Exception:
                    for index in (0, 1):
                        print(network, (root / f'{index}-errors.log').read_text()[-2400:], flush=True)
                    raise
                finally:
                    failure = call(stop)
                    assert failure is None, failure
            print(f'PASS: {network} forwarded over loopback after replacing its session')
    print('PASS: same-name tags, IPv4/IPv6 DNS isolation, independent log sinks, bind failure cleanup and restart')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', type=Path)
    run(parser.parse_args().library)
