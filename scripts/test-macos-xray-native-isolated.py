#!/usr/bin/env python3
"""Exercise a signed native Xray TUN on one TEST-NET host; preserve the default route and system DNS."""
import argparse, base64, http.server, json, queue, select, socket, socketserver, struct, subprocess, threading, time
from pathlib import Path
from test_macos_tun_support import capture_network, command, restoration, restored

TARGET = '203.0.113.231'
GATEWAY = '169.254.129.1'
PAYLOAD = b'v2rayM-native-xray-tun-ok'

def receive(sock, count):
    result = b''
    while len(result) < count:
        data = sock.recv(count - len(result))
        if not data: raise ConnectionError('fixture EOF')
        result += data
    return result

class TCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

class Socks(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        try:
            version, count = receive(self.request, 2); receive(self.request, count)
            if version != 5: return
            self.request.sendall(b'\x05\x00')
            version, kind, _, addrtype = receive(self.request, 4)
            if addrtype != 1: return
            host = socket.inet_ntoa(receive(self.request, 4)); port = int.from_bytes(receive(self.request, 2), 'big')
            if kind != 1 or host != TARGET or port != 80: return
            self.server.requests_seen += 1
            with socket.create_connection(('127.0.0.1', self.server.http_port), timeout=10) as remote:
                self.request.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01' + self.server.http_port.to_bytes(2, 'big'))
                while True:
                    readable, _, _ = select.select([self.request, remote], [], [], 10)
                    if not readable: return
                    for stream in readable:
                        data = stream.recv(65536)
                        if not data: return
                        (remote if stream is self.request else self.request).sendall(data)
        except (OSError, ConnectionError): pass

class HTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Length', str(len(PAYLOAD))); self.end_headers(); self.wfile.write(PAYLOAD)
    def log_message(self, *_): pass

class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        data, stream = self.request
        if len(data) < 12: return
        offset = 12
        while offset < len(data) and data[offset]: offset += data[offset] + 1
        end = offset + 5
        question = data[12:end]
        if end > len(data): return
        kind = int.from_bytes(data[offset+1:offset+3], 'big')
        count = 1 if kind == 1 else 0
        answer = b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04' + socket.inet_aton(TARGET) if count else b''
        stream.sendto(data[:2] + struct.pack('!HHHHH', 0x8180, 1, count, 0, 0) + question + answer, self.client_address)


def run(app, report_path):
    baseline = capture_network()
    assert TARGET not in command(['/usr/sbin/netstat', '-rn', '-f', 'inet'])[1], 'Test address already has an explicit route'
    report = {'mode': 'isolated-native-tun', 'target': TARGET, 'systemDNSChangedByTest': False, 'defaultRouteChangedByTest': False, 'runs': []}
    report_path.parent.mkdir(parents=True, exist_ok=True)
    def save(): report_path.write_text(json.dumps(report, indent=2))
    save()
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), HTTP) as httpd, TCPServer(('127.0.0.1', 0), Socks) as socks, socketserver.ThreadingUDPServer(('127.0.0.1', 0), DNS) as dns:
        socks.http_port = httpd.server_address[1]; socks.requests_seen = 0
        for server in [httpd, socks, dns]: threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            for mode in ['graceful-stop', 'bridge-interruption']:
                interfaces = set(command(['/sbin/ifconfig', '-l'])[1].split())
                interface = next('utun'+str(i) for i in range(900, 1024) if 'utun'+str(i) not in interfaces)
                config = {'log': {'loglevel': 'info'}, 'inbounds': [{'tag': 'tun', 'protocol': 'tun', 'settings': {'name': interface, 'mtu': 1500, 'gateway': [GATEWAY+'/30'], 'autoSystemRoutingTable': [TARGET+'/32'], 'autoOutboundsInterface': 'lo0'}}],
                          'outbounds': [{'tag': 'proxy', 'protocol': 'socks', 'settings': {'servers': [{'address':'127.0.0.1','port':socks.server_address[1]}]}}, {'tag':'dns-out','protocol':'dns'}],
                          'dns': {'servers': [{'address':'127.0.0.1','port':dns.server_address[1]}], 'queryStrategy':'UseIPv4'},
                          'routing': {'domainStrategy':'AsIs','rules':[{'type':'field','inboundTag':['tun'],'port':'53','outboundTag':'dns-out'},{'type':'field','inboundTag':['tun'],'outboundTag':'proxy'}]}}
                request = {'action':'start','core':'xray','config':base64.b64encode(json.dumps(config).encode()).decode(),'configureSystemDNS':False}
                bridge = subprocess.Popen([str(app/'Contents/MacOS/V2rayMHelperClient'),'run'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
                messages = queue.Queue()
                def read_output(proc=bridge, dest=messages):
                    for line in proc.stdout:
                        try: dest.put(json.loads(line))
                        except json.JSONDecodeError: pass
                threading.Thread(target=read_output, daemon=True).start()
                result = {'termination':mode,'interface':interface}; report['runs'].append(result); save()
                try:
                    bridge.stdin.write(json.dumps(request)+'\n'); bridge.stdin.flush()
                    response = messages.get(timeout=25)
                    assert response.get('success') and response.get('state') == 'running', response
                    pid = response['pid']; result['pid'] = pid
                    result['coreExecutable'] = Path(response['executablePath']).name
                    result['uid'] = command(['/bin/ps','-p',str(pid),'-o','uid='])[1].strip()
                    assert result['coreExecutable'] == 'xray' and result['uid'] == '0'
                    for attempt in range(30):
                        route = command(['/sbin/route','-n','get',TARGET])[1]
                        if 'interface: '+interface in route: break
                        time.sleep(.1)
                    assert 'interface: '+interface in route, route
                    current = capture_network()
                    assert current['testRoute'] == baseline['testRoute'], 'Default route changed'
                    assert current['dnsServers'] == baseline['dnsServers'], 'System DNS changed'
                    assert current['proxy'] == baseline['proxy'], 'System proxy changed'
                    code, output, err = command(['/usr/bin/curl','--silent','--show-error','--noproxy','*','--connect-timeout','3','--max-time','8','http://'+TARGET+'/native-tun'],timeout=12)
                    assert code == 0 and output.encode() == PAYLOAD, (code, output, err)
                    result['httpTrafficPassed'] = True
                    question = b''.join(bytes([len(part)])+part.encode() for part in 'v2raym-native-test.invalid'.split('.'))+b'\0\0\x01\0\x01'
                    query = b'\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00'+question
                    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as udp:
                        udp.settimeout(8); udp.sendto(query,(GATEWAY,53)); answer=udp.recv(4096)
                    assert answer[:2] == b'\x12\x34' and socket.inet_aton(TARGET) in answer, answer.hex()
                    result['dnsThroughTunPassed'] = True
                finally:
                    if bridge.poll() is None:
                        if mode == 'bridge-interruption': bridge.kill()
                        else: bridge.stdin.write('{}\n'); bridge.stdin.flush()
                        try: bridge.wait(timeout=15)
                        except subprocess.TimeoutExpired: bridge.kill(); bridge.wait(timeout=3)
                    for attempt in range(30):
                        cleanup = restoration(baseline,capture_network())
                        if restored(cleanup): break
                        time.sleep(.2)
                    result['restoration'] = cleanup; save()
                    assert restored(cleanup), cleanup
            assert socks.requests_seen >= 2
            report['passed'] = True; save(); print('Native Xray TUN isolated HTTP, DNS, restart and disconnect cleanup passed.')
        finally:
            for server in [httpd,socks,dns]: server.shutdown()

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('--app',type=Path,default=Path('/Applications/v2rayM.app')); p.add_argument('--report',type=Path,required=True); args=p.parse_args()
    run(args.app,args.report)
