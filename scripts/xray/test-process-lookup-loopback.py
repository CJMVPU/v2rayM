#!/usr/bin/env python3
"""Exercise process routing with UDP sockets that close before routing.
Only loopback addresses; no TUN, routes, system DNS, app settings or helper.
"""
import argparse
import hashlib
import json
from pathlib import Path
import signal
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.bind(('127.0.0.1', 0))
    receiver.settimeout(5)
    reservation = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    reservation.bind(('127.0.0.1', 0))
    inbound_port = reservation.getsockname()[1]
    reservation.close()
    config = {
        'log': {'loglevel': 'debug', 'access': str(args.output/'access.log'), 'error': str(args.output/'error.log')},
        'inbounds': [{'listen': '127.0.0.1', 'port': inbound_port, 'protocol': 'dokodemo-door', 'tag':'test',
                      'settings': {'address':'127.0.0.1', 'port':receiver.getsockname()[1], 'network':'udp'}}],
        'outbounds': [{'tag':'direct','protocol':'freedom'}, {'tag':'self-block','protocol':'blackhole'}],
        'routing': {'rules':[{'type':'field','process':['xray/','self/'], 'outboundTag':'self-block'},
                             {'type':'field','network':'udp','outboundTag':'direct'}]}
    }
    config_path = args.output/'config.json'
    config_path.write_text(json.dumps(config, indent=2))
    result = {'version': subprocess.check_output([str(args.core),'version'],text=True).splitlines()[0],
              'sha256': hashlib.sha256(args.core.read_bytes()).hexdigest(), 'loopback_only':True,
              'tun_started':False, 'network_configuration_writes':0}
    with (args.output/'console.log').open('w') as log:
        proc = subprocess.Popen([str(args.core),'run','-c',str(config_path)], stdout=log, stderr=subprocess.STDOUT)
        try:
            # Readiness packet also verifies a live foreign-process socket.
            live = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            live.settimeout(.2)
            for _ in range(50):
                if proc.poll() is not None: raise RuntimeError('core exited before readiness')
                live.sendto(b'live', ('127.0.0.1', inbound_port))
                receiver.settimeout(.1)
                try:
                    data, source = receiver.recvfrom(1024)
                    if data == b'live':
                        receiver.sendto(b'echo',source)
                        assert live.recvfrom(1024)[0] == b'echo'
                        break
                except socket.timeout: pass
            else: raise RuntimeError('live UDP forwarding not ready')
            live.close()
            result['live_udp_echo'] = True
            # Pause ONLY this child, enqueue local packets, close their senders,
            # then resume. This deterministically reproduces the owner lifetime race.
            proc.send_signal(signal.SIGSTOP)
            expected = {('closed-%02d'%i).encode() for i in range(20)}
            for payload in sorted(expected):
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
                    sender.sendto(payload, ('127.0.0.1',inbound_port))
            proc.send_signal(signal.SIGCONT)
            got = set()
            receiver.settimeout(5)
            while got != expected:
                payload, _ = receiver.recvfrom(1024)
                if payload in expected: got.add(payload)
            result['closed_socket_packets_received'] = len(got)
        finally:
            if proc.poll() is None:
                proc.send_signal(signal.SIGCONT)
                proc.terminate()
                try: proc.wait(timeout=5)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait()
            receiver.close()
            result['child_exited'] = proc.poll() is not None
    lines=(args.output/'error.log').read_text().splitlines()
    result['errors']=[line for line in lines if '[Error]' in line]
    result['warnings']=[line for line in lines if '[Warning]' in line]
    result['owner_unavailable_debug_count']=sum('[Debug]' in line and 'Process owner unavailable' in line for line in lines)
    (args.output/'result.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))

if __name__=='__main__': main()
