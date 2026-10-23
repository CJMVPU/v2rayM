#!/usr/bin/env python3
"""Operator-triggered TUN verification that continues without a chat connection."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request


def command(arguments, timeout=15):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    return result.returncode, result.stdout, result.stderr


def capture_network():
    route = command(['/sbin/route', '-n', 'get', '1.1.1.1'])[1]
    table = command(['/usr/sbin/netstat', '-rn', '-f', 'inet'])[1]
    gateways = []
    for line in table.splitlines():
        fields = line.split()
        if len(fields) >= 4 and ('G' in fields[2] or fields[3].startswith('utun')):
            gateways.append(fields[:4])
    dns = command(['/usr/sbin/scutil', '--dns'])[1]
    return {
        'interfaces': command(['/sbin/ifconfig', '-l'])[1].split(),
        'testRoute': [line.strip() for line in route.splitlines()
                      if line.strip().startswith(('interface:', 'gateway:'))],
        'gatewayAndTunnelRoutes': sorted(gateways),
        'dnsServers': re.findall(r'nameserver\[\d+\]\s*:\s*(\S+)', dns),
        'proxy': command(['/usr/sbin/scutil', '--proxy'])[1],
    }


def check_no_existing_proxy(network):
    if any('utun' in line for line in network['testRoute']):
        raise RuntimeError('仍有其他 TUN 接管外网路由。请先暂停 v2rayN 的 TUN。')
    if re.search(r'\b(?:HTTP|HTTPS|SOCKS|ProxyAutoConfig|ProxyAutoDiscovery)Enable\s*:\s*1\b', network['proxy']):
        raise RuntimeError('系统代理仍开启。请先在 v2rayN 中关闭系统代理。')
    processes = command(['/bin/ps', '-axo', 'comm='])[1].splitlines()
    if any('/Application Support/v2rayN/bin/' in p and
           Path(p.strip()).name in {'xray', 'sing-box', 'mihomo'} for p in processes):
        raise RuntimeError('v2rayN 内核仍在运行。请先断开连接。')


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('/Applications/v2rayM.app'))
    parser.add_argument('--source-data', type=Path,
                        default=Path.home() / 'Library/Application Support/v2rayM')
    parser.add_argument('--check-only', action='store_true', help='只检查签名、helper、后端；不启用 TUN')
    parser.add_argument('--expect-app-version', help='拒绝测试不匹配的应用版本或构建号')
    parser.add_argument('--expect-xray-marker', help='要求随包 Xray 包含指定修复标记')
    args = parser.parse_args()
    if sys.platform != 'darwin' or os.geteuid() == 0:
        parser.error('请在 Mac 上用普通用户运行，不要加 sudo。')
    if not args.check_only and not sys.stdin.isatty():
        parser.error('联网测试必须从交互终端启动，并在本机按回车确认。')

    os.umask(0o077)
    results = Path(__file__).resolve().parents[1] / 'artifacts/macos-tun-tests'
    results.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix=time.strftime('%Y%m%d-%H%M%S-'), dir=results))
    data = root / 'temporary-data'
    report = {'mode': 'check-only' if args.check_only else 'tun-test', 'stage': 'preparing',
              'app': str(args.app), 'tunAttempted': False}
    report_path = root / 'result.json'
    (results / ('latest-check-only.txt' if args.check_only else 'latest.txt')).write_text(str(report_path) + '\n')

    def save():
        temporary = root / 'result.pending.json'
        temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        temporary.replace(report_path)

    def say(message):
        print(message, flush=True)

    backend = None
    token = None
    before = None
    watchdog = None
    expired = threading.Event()
    failure = None
    log = None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    base = None

    def api(path, method='GET', body=None, authenticated=True, timeout=35):
        headers = {'Content-Type': 'application/json'}
        if authenticated:
            headers['Authorization'] = 'Bearer ' + token
        request = urllib.request.Request(base + path, headers=headers, method=method,
                                         data=None if body is None else json.dumps(body).encode())
        try:
            with opener.open(request, timeout=timeout) as response:
                value = json.load(response)
        except urllib.error.HTTPError as error:
            value = json.load(error)
        if not value.get('success'):
            raise RuntimeError(path + ': ' + str(value.get('code') or value.get('messageKey')))
        return value.get('data')

    def stop_owned_backend():
        if backend is not None and backend.poll() is None:
            backend.terminate()
            try:
                backend.wait(timeout=10)
            except subprocess.TimeoutExpired:
                backend.kill()
                backend.wait(timeout=5)

    def timeout_stop():
        expired.set()
        say('达到两分钟测试时限，正在终止本次后端；helper 会在连接关闭后清理自己的内核。')
        stop_owned_backend()

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    say('本机测试入口已启动，断开聊天不会中止此程序。')
    say('结果将保存在：' + str(report_path))
    save()
    try:
        if command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(args.app)])[0] != 0:
            raise RuntimeError('应用签名校验失败。')
        app_info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
        report['appVersion'] = app_info.get('CFBundleShortVersionString')
        report['appBuild'] = app_info.get('CFBundleVersion')
        if args.expect_app_version and (report['appVersion'] != args.expect_app_version
                                       or report['appBuild'] != args.expect_app_version):
            raise RuntimeError('应用版本不匹配，请先安装指定测试版本。')
        core = args.app / 'Contents/Resources/Backend/bin/xray/xray'
        code, version, _ = command([str(core), 'version'])
        if code != 0 or (args.expect_xray_marker and args.expect_xray_marker not in version):
            raise RuntimeError('随包 Xray 不是本次要求的修复版。')
        report['bundledXrayVersion'] = version.splitlines()[0]
        report['bundledXraySHA256'] = hashlib.sha256(core.read_bytes()).hexdigest()
        report['sourceData'] = str(args.source_data)
        say('测试应用版本：' + str(report['appVersion']) + '（' + str(report['appBuild']) + '）')
        config_path = args.source_data / 'guiConfigs/guiNConfig.json'
        config = json.loads(config_path.read_text())
        if not config.get('IndexId'):
            raise RuntimeError('源应用尚未选中节点。请先选择一个可用节点。')
        config['TunModeItem']['EnableTun'] = False
        config['Inbound'][0].update(LocalPort=17891, SecondLocalPortEnabled=False, AllowLANConn=False)
        config['GuiItem']['AutoUpdateInterval'] = 0
        config['CoreBasicItem'].update(LogEnabled=True, Loglevel='warning')
        (data / 'guiConfigs').mkdir(parents=True)
        (data / 'guiConfigs/guiNConfig.json').write_text(json.dumps(config, ensure_ascii=False))
        with sqlite3.connect('file:' + str(args.source_data / 'guiConfigs/guiNDB.db') + '?mode=ro', uri=True) as source:
            with sqlite3.connect(data / 'guiConfigs/guiNDB.db') as target:
                source.backup(target)
        shutil.copytree(args.app / 'Contents/Resources/Backend/bin', data / 'bin')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        base = 'http://127.0.0.1:' + str(port)
        key = secrets.token_urlsafe(32)
        environment = {k: v for k, v in os.environ.items()
                       if not k.startswith(('V2RAYN_', 'V2RAYM_', 'ASPNETCORE_', 'DYLD_'))
                       and not k.lower().startswith('kestrel')
                       and k not in {'URLS', 'HTTP_PORTS', 'HTTPS_PORTS', 'INVOCATION_ID', 'JOURNAL_STREAM', 'NOTIFY_SOCKET'}}
        environment.update(V2RAYM_DATA_HOME=str(data), V2RAYN_WEB_API_KEY=key,
                           V2RAYN_WEB_AUTOSTART='false', V2RAYN_WEB_PROXY_LISTEN_ALL='false',
                           DOTNET_HOSTBUILDER__RELOADCONFIGONCHANGE='false', DOTNET_USE_POLLING_FILE_WATCHER='1',
                           DOTNET_BUNDLE_EXTRACT_BASE_DIR=str(data / 'guiTemps/dotnet'))
        log = (root / 'backend.log').open('wb')
        backend = subprocess.Popen([str(args.app / 'Contents/Resources/Backend/v2rayN.WebAPI'),
                                    '--foreground', '--no-open', '--urls', base],
                                   cwd=args.app / 'Contents/Resources/Backend', env=environment,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        for _ in range(150):
            if backend.poll() is not None:
                raise RuntimeError('测试后端退出，详情已留在本机日志。')
            try:
                with opener.open(base + '/api/health', timeout=1) as response:
                    if response.headers.get('X-v2rayn-WebAPI-instance-pid') != str(backend.pid):
                        raise RuntimeError('后端身份不匹配。')
                    if json.load(response).get('status') == 'ok':
                        break
            except (OSError, urllib.error.URLError):
                time.sleep(.2)
        else:
            raise RuntimeError('测试后端启动超时。')
        token = api('/api/auth/login', 'POST', {'key': key}, authenticated=False)['token']
        tun = api('/api/macos/tun')
        status = api('/api/status')
        report['preflight'] = {'helperAvailable': tun['helperAvailable'], 'helperCode': tun['helperCode'],
                               'coreSource': tun['coreSource'], 'profileCount': status['profileCount']}
        if not tun['helperAvailable'] or status['coreRunning']:
            raise RuntimeError('helper 未就绪或测试内核意外自启。')
        report['preflight']['installedXrayVersion'] = status.get('installedXrayVersion')
        say('准备检查通过：签名、helper、后端和节点副本均可用，尚未开启 TUN。')
        if args.check_only:
            report['stage'] = 'preflight-passed'
        else:
            report['stage'] = 'waiting-for-operator'
            save()
            say('现在手动暂停 v2rayN：关闭 TUN、断开内核、关闭系统代理。')
            say('保持本终端打开。测试完成后，请手动恢复 v2rayN，再回到聊天。')
            input('准备好后在本终端按回车开始；按 Ctrl+C 取消：')
            before = capture_network()
            check_no_existing_proxy(before)
            helper_client = args.app / 'Contents/MacOS/V2rayMHelperClient'
            helper_code, helper_output, _ = command([str(helper_client), 'status'])
            if helper_code != 0 or json.loads(helper_output).get('state') != 'idle':
                raise RuntimeError('v2rayM 后台服务不是空闲状态，请先关闭 v2rayM 的代理。')
            report['before'] = before
            report['stage'] = 'testing'
            report['tunAttempted'] = True
            save()
            watchdog = threading.Timer(120, timeout_stop)
            watchdog.daemon = True
            watchdog.start()
            api('/api/macos/tun', 'PUT', {'enabled': True})
            say('正在启动 TUN 并检查真实流量……')
            api('/api/core/start', 'POST')
            time.sleep(2)
            tun = api('/api/macos/tun')
            status = api('/api/status')
            report['running'] = {'coreRunning': status['coreRunning'], 'coreType': status['coreType'],
                                 'runtimeState': tun['runtimeState'], 'privilegedPids': tun['privilegedCoreProcessIds'],
                                 'supportedCores': tun['supportedCores'], 'coreSource': tun['coreSource']}
            if tun['supportedCores'] != ['xray'] or len(tun['privilegedCoreProcessIds']) != 1:
                raise RuntimeError('本次要求仅有一个 Xray 原生 TUN 内核，未接受旧的前置入口。')
            if not status['coreRunning'] or not tun['privilegedCoreProcessIds']:
                raise RuntimeError('未检测到正常运行的特权内核。')
            report['during'] = capture_network()
            temporary_dns = (config['TunModeItem'].get('IPv4Address') or '172.18.0.1/30').split('/')[0]
            report['nativeDnsResolverObserved'] = temporary_dns in report['during']['dnsServers']
            if not report['nativeDnsResolverObserved']:
                raise RuntimeError('系统解析器未发现本次原生 TUN 的临时 DNS。')
            if not any('utun' in line for line in report['during']['testRoute']):
                raise RuntimeError('测试目标路由未进入 TUN。')
            for pid in tun['privilegedCoreProcessIds']:
                if Path(command(['/bin/ps', '-p', str(pid), '-o', 'comm='])[1].strip()).name != 'xray':
                    raise RuntimeError('特权内核不是 Xray。')
                if command(['/bin/ps', '-p', str(pid), '-o', 'uid='])[1].strip() != '0':
                    raise RuntimeError('特权内核的进程身份不是 root。')

            def request_site(url):
                code, output, _ = command(['/usr/bin/curl', '--silent', '--show-error', '--noproxy', '*',
                                           '--connect-timeout', '5', '--max-time', '12', '--output', '/dev/null',
                                           '--write-out', '%{http_code}', url])
                return {'url': url, 'exitCode': code, 'httpStatus': output.strip()}

            report['traffic'] = [request_site('https://www.google.com/generate_204'),
                                 request_site('https://www.cloudflare.com/cdn-cgi/trace')]
            save()
            if not all(item['exitCode'] == 0 and item['httpStatus'] in {'200', '204'} for item in report['traffic']):
                raise RuntimeError('TUN 下的 HTTPS 请求未全部通过。')
            say('无显式代理的 HTTPS 请求通过，正在检查 TUN 重启。')
            api('/api/core/restart', 'POST')
            time.sleep(2)
            report['restartTraffic'] = request_site('https://www.google.com/generate_204')
            if report['restartTraffic']['exitCode'] != 0 or report['restartTraffic']['httpStatus'] != '204':
                raise RuntimeError('重启 TUN 后请求失败。')
    except KeyboardInterrupt:
        failure = '用户取消测试。'
    except Exception as error:
        failure = str(error)
    finally:
        if report['tunAttempted'] and token:
            try:
                entries = api('/api/logs?limit=10000', timeout=5)
                (root / 'core-logs.json').write_text(json.dumps(entries, ensure_ascii=False, indent=2))
                report['coreLogs'] = 'core-logs.json'
            except Exception as error:
                report['logCaptureError'] = str(error)
            say('正在停止本次测试内核并检查网络恢复……')
            try:
                api('/api/core/stop', 'POST', timeout=25)
                api('/api/macos/tun', 'PUT', {'enabled': False}, timeout=10)
                tun = api('/api/macos/tun', timeout=10)
                report['stopped'] = {'runtimeState': tun['runtimeState'], 'privilegedPids': tun['privilegedCoreProcessIds']}
                if tun['privilegedCoreProcessIds'] or tun['runtimeState'] != 'stopped':
                    raise RuntimeError('后端未确认内核完全停止。')
            except Exception as error:
                report['cleanupError'] = str(error)
                failure = failure or '停止状态未确认，请查看结果文件。'
        stop_owned_backend()
        if watchdog:
            watchdog.cancel()
        if log:
            log.close()
        if report['tunAttempted'] and before is not None:
            for _ in range(12):
                report['after'] = capture_network()
                report['restoration'] = restoration(before, report['after'])
                if restored(report['restoration']):
                    break
                time.sleep(1)
            if not restored(report['restoration']):
                failure = failure or '网络状态与测试前基线不一致。'
        if expired.is_set():
            failure = failure or '测试超过两分钟时限。'
        if data.exists():
            shutil.rmtree(data)
        report['passed'] = failure is None
        report['failure'] = failure
        if report['tunAttempted']:
            report['stage'] = 'finished'
        save()
        if failure:
            say('测试未全部通过：' + failure)
        elif args.check_only:
            say('准备检查通过；没有开启 TUN，没有修改系统网络。')
        else:
            say('测试通过：TUN 请求、重启及网络恢复检查均通过。')
        say('结果已保存：' + str(report_path))
        if not args.check_only:
            say('现在请手动恢复 v2rayN；恢复联网后告诉我“读取本机 TUN 测试结果”。')
    return 0 if failure is None else 1


if __name__ == '__main__':
    sys.exit(main())
