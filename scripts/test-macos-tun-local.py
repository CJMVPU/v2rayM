#!/usr/bin/env python3
"""Operator-triggered TUN verification that continues without a chat connection."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import queue
import re
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time


def command(arguments, timeout=15):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    return result.returncode, result.stdout, result.stderr


def read_command(args):
    code, output, _ = command(args)
    if code:
        raise RuntimeError('无法核对当前系统状态：' + args[0])
    return output


def capture_network():
    route = read_command(['/sbin/route', '-n', 'get', '1.1.1.1'])
    table = '\n'.join(read_command(['/usr/sbin/netstat', '-rn', '-f', family]) for family in ('inet', 'inet6'))
    gateways = []
    for line in table.splitlines():
        fields = line.split()
        if len(fields) >= 4 and ('G' in fields[2] or fields[3].startswith('utun')) and 'W' not in fields[2]:
            gateways.append(fields[:4])
    dns = read_command(['/usr/sbin/scutil', '--dns'])
    return {
        'interfaces': read_command(['/sbin/ifconfig', '-l']).split(),
        'testRoute': [line.strip() for line in route.splitlines()
                      if line.strip().startswith(('interface:', 'gateway:'))],
        'gatewayAndTunnelRoutes': sorted(gateways),
        'dnsServers': re.findall(r'nameserver\[\d+\]\s*:\s*(\S+)', dns),
        'proxy': read_command(['/usr/sbin/scutil', '--proxy']),
    }


def check_no_existing_proxy(network):
    if any('utun' in line for line in network['testRoute']):
        raise RuntimeError('仍有其他 TUN 接管外网路由。请先暂停 v2rayN 的 TUN。')
    # macOS also creates link-local utuns for OS services. A routed unicast subnet
    # on one of those interfaces can indicate a split VPN even with a physical default route.
    for destination, _, _, interface in network['gatewayAndTunnelRoutes']:
        if interface.startswith('utun') and (destination == 'default' or
                ('/' in destination and not destination.lower().startswith(('fe80', 'ff', '169.254', '224.')))):
            raise RuntimeError('仍有其他 utun 管理网络路由，请先断开。')
    if '(Connected)' in read_command(['/usr/sbin/scutil', '--nc', 'list']):
        raise RuntimeError('系统报告另一个 VPN 已连接，请先断开。')
    if re.search(r'\b(?:HTTP|HTTPS|SOCKS|ProxyAutoConfig|ProxyAutoDiscovery)Enable\s*:\s*1\b', network['proxy']):
        raise RuntimeError('系统代理仍开启。请先在 v2rayN 中关闭系统代理。')
    processes = read_command(['/bin/ps', '-axo', 'comm=']).splitlines()
    if any(Path(p.strip()).name.lower() in {'xray', 'sing-box', 'mihomo'} for p in processes):
        raise RuntimeError('仍有代理内核在运行。请先断开其他代理和 v2rayM 的连接。')


def restoration(before, after):
    return {
        'testRouteRestored': before['testRoute'] == after['testRoute'],
        'gatewayAndTunnelRoutesRestored': before['gatewayAndTunnelRoutes'] == after['gatewayAndTunnelRoutes'],
        'dnsServersRestored': before['dnsServers'] == after['dnsServers'],
        'systemProxyUnchanged': before['proxy'] == after['proxy'],
        'newInterfacesRemaining': sorted(set(after['interfaces']) - set(before['interfaces'])),
    }


def restored(result):
    return all(value for key, value in result.items() if key != 'newInterfacesRemaining') and not result['newInterfacesRemaining']


def preflight(app, version, marker):
    if command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])[0]:
        raise RuntimeError('应用签名校验失败。')
    contents = app / 'Contents'
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'io.github.CJMVPU.v2rayM' or info.get('V2rayMTunAcceptanceProtocol') != 1:
        raise RuntimeError('此应用不支持原生 TUN 验收。')
    actual = info['CFBundleShortVersionString']
    if actual != info['CFBundleVersion'] or (version and actual != version):
        raise RuntimeError('应用版本或构建号不匹配。')
    for relative in ['MacOS/V2rayM', 'MacOS/V2rayMHelper', 'Frameworks/libV2rayMXray.dylib',
                     'Library/LaunchDaemons/io.github.CJMVPU.v2rayM.tun-helper.plist']:
        if not (contents / relative).is_file():
            raise RuntimeError('缺少组件 ' + relative)
    inputs = json.loads((contents / 'Resources/Xray/library-build.json').read_bytes())['inputs']
    if marker and inputs['buildMarker'] != marker:
        raise RuntimeError('Xray 修复标记不匹配。')
    return {'appVersion': actual, 'xrayVersion': inputs['version'], 'buildMarker': inputs['buildMarker']}


class Host:
    def __init__(self, app, network):
        self.answers = queue.Queue()
        self.data = None
        environment = {k: v for k, v in os.environ.items() if not k.startswith(('V2RAY', 'DYLD_', 'XRAY_'))}
        args = [str(app / 'Contents/MacOS/V2rayM'), '--tun-acceptance']
        if network:
            args.append('--allow-tun')
        self.process = subprocess.Popen(args, env=environment, text=True, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=sys.stderr)

        def read():
            try:
                for line in self.process.stdout:
                    if line.startswith('V2M-CHECK '):
                        self.answers.put(json.loads(line[len('V2M-CHECK '):]))
            finally:
                self.answers.put(None)
        threading.Thread(target=read, daemon=True).start()

    def handshake(self, interactive):
        path = Path(self.receive(timeout=None if interactive else 40)['directory']).resolve(strict=True)
        if (path.parent != Path(tempfile.gettempdir()).resolve() or not path.name.startswith('v2raym-acceptance-')
                or path.stat().st_uid != os.getuid() or (path.stat().st_mode & 0o777) != 0o700):
            raise RuntimeError('无法确认验收临时目录归属。')
        self.data = path

    def receive(self, timeout=40):
        try:
            value = self.answers.get(timeout=timeout)
        except queue.Empty:
            # A late response could otherwise be mistaken for the next command's acknowledgement.
            self.process.terminate()
            raise RuntimeError('验收宿主响应超时。') from None
        if value is None or (isinstance(value, dict) and 'error' in value):
            raise RuntimeError(value['error'] if value else '验收宿主已退出。')
        return value

    def request(self, name):
        self.process.stdin.write(name + '\n')
        self.process.stdin.flush()
        return self.receive()

    def close(self):
        try:
            self.process.stdin.close()  # EOF asks the host to stop the runtime and release its XPC session.
            return self.process.wait(timeout=25)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise RuntimeError('宿主退出超时。') from None
        finally:
            self.process.stdout.close()
            if self.data and self.data.exists() and self.process.poll() is not None:
                shutil.rmtree(self.data)


def copy_config(source, data):
    directory = source / 'guiConfigs'
    destination = data / 'guiConfigs'
    destination.mkdir()
    config = json.loads((directory / 'guiNConfig.json').read_bytes())
    if not config.get('IndexId'):
        raise RuntimeError('源应用尚未选中节点。')
    config['TunModeItem']['EnableTun'] = False
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        config['Inbound'][0].update(LocalPort=sock.getsockname()[1], SecondLocalPortEnabled=False, AllowLANConn=False)
    (destination / 'guiNConfig.json').write_text(json.dumps(config, ensure_ascii=False))
    uri = (directory / 'guiNDB.db').resolve().as_uri() + '?mode=ro'
    with sqlite3.connect(uri, uri=True) as original, sqlite3.connect(destination / 'guiNDB.db') as copied:
        original.backup(copied)
        # Local file-backed nodes can refer to nested files or absolute paths.
        # Rebase every reference inside the test copy, including missing/unportable files.
        nodes = list(copied.execute('SELECT DISTINCT Address FROM ProfileItem WHERE ConfigType IN (2,13)'))
        for (address,) in nodes:
            if not address:
                continue
            local_name = 'profile-' + hashlib.sha256(address.encode()).hexdigest() + '.json'
            path = (directory / address).resolve()
            if directory.resolve() in path.parents and path.is_file():
                shutil.copyfile(path, destination / local_name)
            copied.execute('UPDATE ProfileItem SET Address=? WHERE ConfigType IN (2,13) AND Address=?',
                           (local_name, address))
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('/Applications/v2rayM.app'))
    parser.add_argument('--source-data', type=Path, default=Path.home() / 'Library/Application Support/v2rayM')
    parser.add_argument('--check-only', '--preflight-only', action='store_true',
                        help='离线校验签名和宿主，使用空白临时数据库')
    parser.add_argument('--result-dir', type=Path, help='验收报告的父目录')
    parser.add_argument('--expect-app-version')
    parser.add_argument('--expect-xray-marker')
    args = parser.parse_args()
    if sys.platform != 'darwin' or os.geteuid() == 0:
        parser.error('请用普通 macOS 用户运行。')
    if not args.check_only and not sys.stdin.isatty():
        parser.error('真实 TUN 验收需要本地交互终端。')
    os.umask(0o077)
    results = args.result_dir or Path(__file__).resolve().parents[1] / 'artifacts/macos-tun-tests'
    results.mkdir(parents=True, exist_ok=True)
    report_path = Path(tempfile.mkdtemp(prefix=time.strftime('%Y%m%d-%H%M%S-'), dir=results)) / 'result.json'
    (results / ('latest-check-only.txt' if args.check_only else 'latest.txt')).write_text(str(report_path) + '\n')
    report = {'app': str(args.app), 'mode': 'check-only' if args.check_only else 'real-tun', 'tunAttempted': False}
    host = before = watchdog = None
    def save():
        pending = report_path.with_suffix('.pending')
        pending.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        pending.replace(report_path)

    def interrupt(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt)
    print('验收结果将写入 ' + str(report_path), flush=True)
    try:
        report.update(preflight(args.app, args.expect_app_version, args.expect_xray_marker))
        if not args.check_only:
            print('请先关闭其他 VPN、系统代理和 TUN。验收会临时修改路由和 DNS，再恢复基线。')
            print('确认当前网络空闲后，v2rayM 将在本机弹窗请求开始验收。')
            before = capture_network()
            check_no_existing_proxy(before)
        host = Host(args.app, not args.check_only)
        host.handshake(interactive=not args.check_only)
        if not args.check_only:
            config = copy_config(args.source_data, host.data)
        opened = host.request('open')
        current = host.request('status')
        if opened['pid'] != host.process.pid or current['coreRunning'] or not current['xrayAvailable']:
            raise RuntimeError('原生宿主身份或初始状态不符。')
        report['hostPID'] = opened['pid']
        if args.check_only:
            host.request('logs')
            isolated = host.request('helper')
            if isolated['helperCode'] != 'helper_isolated':
                raise RuntimeError('离线预检未隔离助手。')
        else:
            helper = host.request('helper')
            if not helper['helperAvailable'] or helper['coreSource'] != 'embedded-xray':
                raise RuntimeError('签名助手未就绪：' + helper['helperCode'])
            report['before'] = before
            report['tunAttempted'] = True
            save()
            watchdog = threading.Timer(120, host.process.terminate)
            watchdog.daemon = True
            watchdog.start()
            for cycle in ('start', 'restart'):
                check_no_existing_proxy(capture_network())
                host.request('start-tun')
                state, tun = host.request('status'), host.request('helper')
                if not (state['coreRunning'] and state['coreProcessIds'] == [host.process.pid]
                        and tun['tunnelForwardingPID'] == host.process.pid and tun['privilegedCoreProcessIds'] == []
                        and tun['supportedCores'] == ['xray'] and tun['runtimeState'] == 'running'):
                    raise RuntimeError('未确认由本次 v2rayM 进程执行 TUN 转发。')
                network = capture_network()
                server = (config['TunModeItem'].get('IPv4Address') or '172.18.0.1/30').split('/')[0]
                if server not in network['dnsServers'] or not any('utun' in item for item in network['testRoute']):
                    raise RuntimeError('路由或临时 DNS 未进入 TUN。')
                report[cycle] = {'corePID': host.process.pid, 'network': network, 'requests': []}
                for url in ['https://www.google.com/generate_204', 'https://www.cloudflare.com/cdn-cgi/trace']:
                    code, status, _ = command(['/usr/bin/curl', '-sS', '--noproxy', '*', '--max-time', '10',
                                               '-o', '/dev/null', '-w', '%{http_code}', url])
                    report[cycle]['requests'].append({'url': url, 'code': code, 'http': status})
                    if code or status not in ('200', '204'):
                        raise RuntimeError('TUN 下的 HTTPS 验证失败。')
                (report_path.parent / 'core-logs.json').write_text(json.dumps(host.request('logs'), ensure_ascii=False))
                host.request('stop')
                if host.request('status')['coreRunning']:
                    raise RuntimeError('内核停止未确认。')
                save()
    except (Exception, KeyboardInterrupt) as error:
        report['failure'] = str(error) or '已取消验收。'
    finally:
        if watchdog:
            watchdog.cancel()
        if host:
            try:
                if host.close():
                    raise RuntimeError('验收宿主异常退出。')
            except Exception as error:
                report['cleanupError'] = str(error)
        if report['tunAttempted']:
            try:
                for _ in range(12):
                    report['restoration'] = restoration(before, capture_network())
                    if restored(report['restoration']):
                        break
                    time.sleep(1)
                if not restored(report['restoration']):
                    report['recoveryError'] = '系统网络尚未恢复到测试前基线。'
            except Exception as error:
                report['recoveryError'] = str(error)
        report['passed'] = not any(key in report for key in ('failure', 'cleanupError', 'recoveryError'))
        save()
    print(json.dumps({k: report[k] for k in ('passed', 'failure', 'cleanupError', 'recoveryError') if k in report},
                     ensure_ascii=False))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
