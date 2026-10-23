#!/usr/bin/env python3
"""Operator-run native TUN -> freedom/direct -> public UDP DNS round-trip check."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import queue
import re
import secrets
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from test_macos_tun_support import _module as support

TARGETS = ['223.5.5.5', '119.29.29.29']
MARKER = 'v2raym-darwin-bind2'


def query_dns(target, port=53):
    transaction = secrets.token_bytes(2)
    question = b'\x07example\x03com\x00\x00\x01\x00\x01'
    packet = transaction + struct.pack('!HHHHH', 0x0100, 1, 0, 0, 0) + question
    start = time.monotonic()
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.settimeout(4)
            udp.connect((target, port))
            udp.send(packet)
            response = udp.recv(4096)
        if len(response) < 12:
            raise ValueError('truncated DNS response')
        flags, questions, answers, _, _ = struct.unpack('!HHHHH', response[2:12])
        if (response[:2] != transaction or not flags & 0x8000 or flags & 0x0200
                or flags & 15 or questions != 1 or answers < 1
                or response[12:12 + len(question)] != question):
            raise ValueError('DNS response identity/status mismatch')
        return dict(target=target, port=port, passed=True, answers=answers,
                    receivedBytes=len(response), elapsedMs=round((time.monotonic()-start)*1000))
    except (OSError, ValueError) as error:
        return dict(target=target, port=port, passed=False, error=str(error))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('/Applications/v2rayM.app'))
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'darwin' or os.geteuid() == 0:
        parser.error('请在 Mac 上以普通用户运行，不要加 sudo。')
    if not args.check_only and not sys.stdin.isatty():
        parser.error('实际测试必须从交互终端确认后运行。')
    os.umask(0o077)
    results = Path(__file__).resolve().parents[1] / 'artifacts/macos-direct-udp-tests'
    results.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix=time.strftime('%Y%m%d-%H%M%S-'), dir=results))
    report_path = root / 'result.json'
    (results / ('latest-check-only.txt' if args.check_only else 'latest.txt')).write_text(str(report_path)+'\n')
    report = dict(mode='check-only' if args.check_only else 'direct-udp', tunAttempted=False,
                  targets=TARGETS, udpPort=53, usesDnsOutbound=False, runs=[])
    def save():
        pending = root / 'result.pending.json'
        pending.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
        pending.replace(report_path)
    bridge = None
    before = None
    watchdog = None
    expired = threading.Event()
    messages = []
    reader = None
    error_log = None
    failure = None
    command = support.command
    def interrupt(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupt)
    print('直连 UDP 专项测试：聊天断线不会中止本机程序。\n结果：'+str(report_path), flush=True)
    try:
        info = plistlib.loads((args.app/'Contents/Info.plist').read_bytes())
        report['appVersion'] = info['CFBundleShortVersionString']
        if report['appVersion'] not in {'0.2.0', '0.2.1'}:
            raise RuntimeError('此入口仅验证 0.2.0 / 0.2.1 修复版。')
        if command(['codesign', '--verify', '--deep', '--strict', str(args.app)])[0]:
            raise RuntimeError('应用签名验证失败。')
        executable = args.app/'Contents/Resources/Backend/bin/xray/xray'
        version = command([str(executable), 'version'])[1]
        if MARKER not in version:
            raise RuntimeError('随包内核缺少 M1 修复标记。')
        report['xrayVersion'] = version.splitlines()[0]
        report['bundledSHA256'] = hashlib.sha256(executable.read_bytes()).hexdigest()
        client = args.app/'Contents/MacOS/V2rayMHelperClient'
        code, output, _ = command([str(client), 'status'])
        helper = json.loads(output)
        if code or not helper.get('success'):
            raise RuntimeError('后台服务不可用。')
        report['helperState'] = helper['state']
        if args.check_only:
            report['stage'] = 'preflight-passed'
        else:
            print('请关闭并退出 v2rayM；关闭 v2rayN 的 TUN、内核和系统代理。', flush=True)
            input('保持终端打开，准备好后按回车；Ctrl+C 取消：')
            before = support.capture_network()
            support.check_no_existing_proxy(before)
            code, output, _ = command([str(client), 'status'])
            if code or json.loads(output).get('state') != 'idle':
                raise RuntimeError('v2rayM helper 仍在运行代理，请先关闭。')
            route = command(['/sbin/route', '-n', 'get', '1.1.1.1'])[1]
            match = re.search(r'interface:\s*(\S+)', route)
            if not match or match[1].startswith('utun'):
                raise RuntimeError('没有可用的物理出口网卡。')
            outbound = match[1]
            report['before'] = before
            report['outboundInterface'] = outbound
            report['baselineUDP'] = [query_dns(target) for target in TARGETS]
            targets = [item['target'] for item in report['baselineUDP'] if item['passed']]
            if not targets:
                raise RuntimeError('原始网络两个 UDP 测试端点均无有效回包，不能据此判断内核修复。')
            interfaces = command(['/sbin/ifconfig', '-l'])[1].split()
            interface = next('utun'+str(i) for i in range(900, 1024) if 'utun'+str(i) not in interfaces)
            config = {'log': {'loglevel': 'info'}, 'inbounds': [
                {'tag': 'tun', 'protocol': 'tun', 'settings': {'name': interface, 'mtu': 1500,
                 'gateway': ['172.29.255.1/30'], 'autoSystemRoutingTable': [t+'/32' for t in targets],
                 'autoOutboundsInterface': outbound}}],
                'outbounds': [{'tag': 'direct', 'protocol': 'freedom', 'settings': {}}],
                'routing': {'rules': [{'type': 'field', 'inboundTag': ['tun'], 'network': 'udp',
                                      'port': '53', 'outboundTag': 'direct'}]}}
            (root/'test-config.json').write_text(json.dumps(config, indent=2))
            request = dict(action='start', core='xray', configureSystemDNS=False,
                           config=base64.b64encode(json.dumps(config).encode()).decode())
            first = queue.Queue()
            error_log = (root/'bridge-stderr.log').open('w')
            bridge = subprocess.Popen([str(client), 'run'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=error_log, text=True, bufsize=1)
            def receive():
                for line in bridge.stdout:
                    try: value = json.loads(line)
                    except json.JSONDecodeError: continue
                    messages.append(value)
                    first.put(value)
            reader = threading.Thread(target=receive, daemon=True)
            reader.start()
            def timeout():
                expired.set()
                if bridge.poll() is None: bridge.terminate()
            watchdog = threading.Timer(90, timeout)
            watchdog.daemon = True
            watchdog.start()
            report['tunAttempted'] = True
            save()
            bridge.stdin.write(json.dumps(request)+'\n'); bridge.stdin.flush()
            started = first.get(timeout=25)
            if not started.get('success') or started.get('state') != 'running':
                raise RuntimeError('TUN 启动失败：'+str(started.get('code')))
            report['pid'] = started['pid']
            report['executablePath'] = started.get('executablePath')
            if Path(started.get('executablePath', '')).name != 'xray':
                raise RuntimeError('特权进程不是 Xray。')
            if command(['/bin/ps','-p',str(started['pid']),'-o','uid='])[1].strip() != '0':
                raise RuntimeError('未确认特权进程身份。')
            for target in targets:
                for _ in range(30):
                    route = command(['/sbin/route','-n','get',target])[1]
                    if 'interface: '+interface in route: break
                    time.sleep(.1)
                else: raise RuntimeError('UDP 测试目标未进入指定 TUN。')
            report['during'] = support.capture_network()
            for key in ['testRoute','dnsServers','proxy']:
                if before[key] != report['during'][key]: raise RuntimeError('测试意外改变默认网络：'+key)
            print('已进入原生 TUN → freedom/direct，检查 UDP 回包……', flush=True)
            for _ in range(3):
                for target in targets:
                    report['runs'].append(query_dns(target)); save()
            time.sleep(.6)
            logs = '\n'.join(str(line) for item in messages for line in item.get('logs', []))
            report['runtimeRepairMarkerObserved'] = MARKER in logs
            report['directUDPLogObserved'] = bool(re.search(r'accepted udp:.*\[tun (?:->|>>) direct\]', logs))
            report['bindingErrors'] = [line for line in logs.splitlines()
                                       if re.search(r'invalid argument|setsockopt|failed to bind', line, re.I)]
            if not all(item['passed'] for item in report['runs']): raise RuntimeError('部分直连 UDP 请求无有效回包。')
            if not report['runtimeRepairMarkerObserved'] or not report['directUDPLogObserved']:
                raise RuntimeError('缺少实际运行的修复标记或 UDP direct 日志证据。')
            if report['bindingErrors']: raise RuntimeError('仍发现出口绑定相关错误。')
    except KeyboardInterrupt:
        failure = '用户取消。'
    except Exception as error:
        failure = str(error)
    finally:
        if bridge is not None:
            if bridge.poll() is None:
                try: bridge.stdin.write('{}\n'); bridge.stdin.flush()
                except (OSError, BrokenPipeError): pass
                try: bridge.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    bridge.kill(); bridge.wait(timeout=5)
            if reader: reader.join(timeout=2)
            report['bridgeExitCode'] = bridge.returncode
            (root/'helper-responses.json').write_text(json.dumps(messages,ensure_ascii=False,indent=2))
            if bridge.returncode: failure = failure or '后台桥接未正常退出，请检查清理结果。'
        if watchdog: watchdog.cancel()
        if error_log: error_log.close()
        if report['tunAttempted'] and before is not None:
            for _ in range(20):
                report['restoration'] = support.restoration(before, support.capture_network())
                if support.restored(report['restoration']): break
                time.sleep(.5)
            if not support.restored(report['restoration']): failure = failure or '网络恢复与基线不一致。'
        if expired.is_set(): failure = failure or '测试达到 90 秒时限。'
        report.update(passed=failure is None, failure=failure)
        save()
        print(('准备检查通过，未创建 TUN。' if args.check_only else '直连 UDP 测试通过，已恢复测试路由。')
              if failure is None else '未全部通过：'+failure, flush=True)
        print('结果已保存：'+str(report_path), flush=True)
        if not args.check_only: print('确认清理完成后，请手动恢复 v2rayN，再回到聊天。', flush=True)
    return 0 if failure is None else 1


if __name__ == '__main__':
    sys.exit(main())
