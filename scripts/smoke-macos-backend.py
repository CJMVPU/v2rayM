#!/usr/bin/env python3
"""Check a published macOS backend using disposable data and no proxy Core."""

import argparse
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def check(publish_directory, app_bundle=None):
    if platform.system() != "Darwin":
        raise RuntimeError("Run this check on macOS with a matching backend architecture.")
    source = (app_bundle / "Contents/Resources/Backend" if app_bundle else publish_directory).resolve()
    if not (source / "v2rayN.WebAPI").is_file():
        raise RuntimeError("The publish directory must contain v2rayN.WebAPI.")

    with tempfile.TemporaryDirectory(prefix="v2raym-backend-smoke-") as temporary:
        root = Path(temporary)
        app = root / "app"
        # Copy only publish files. Do not import .env or real application data.
        excluded = shutil.ignore_patterns(
            ".env", "guiConfigs", "guiBackups", "guiTemps", "guiLogs",
            "binConfigs", "WebAPIData", "*.instance.lock")
        if app_bundle:
            bundle_copy = root / "Probe.app"
            shutil.copytree(app_bundle, bundle_copy, ignore=excluded)
            app = bundle_copy / "Contents/Resources/Backend"
        else:
            shutil.copytree(source, app, ignore=excluded)
        environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("V2RAYN_", "V2RAYM_", "ASPNETCORE_", "Kestrel__", "KESTREL__"))
            and key not in {"INVOCATION_ID", "JOURNAL_STREAM", "NOTIFY_SOCKET",
                            "DOTNET_RUNNING_IN_CONTAINER", "container", "URLS",
                            "HTTP_PORTS", "HTTPS_PORTS"}
        }
        management_key = secrets.token_urlsafe(32)
        tokens = [management_key]
        api_port = free_port()
        proxy_port = free_port()
        while abs(api_port - proxy_port) < 20:
            proxy_port = free_port()
        environment.update({
            "V2RAYM_DATA_HOME": str(root / "data"),
            "V2RAYN_WEB_API_KEY": management_key,
            "V2RAYN_WEB_AUTOSTART": "false",
            "V2RAYN_WEB_PROXY_PORT": str(proxy_port),
            "DOTNET_BUNDLE_EXTRACT_BASE_DIR": str(root / "extract"),
        })
        base_url = f"http://127.0.0.1:{api_port}"
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def request(path, method="GET", body=None, token=None, expected=200):
            headers = {}
            payload = None
            if body is not None:
                payload = json.dumps(body).encode()
                headers["Content-Type"] = "application/json"
            if token:
                headers["Authorization"] = f"Bearer {token}"
            req = urllib.request.Request(base_url + path, payload, headers, method=method)
            try:
                response = opener.open(req, timeout=3)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                if response.status != expected:
                    raise RuntimeError(f"{method} {path.split('?')[0]} returned {response.status}, expected {expected}.")
                return json.load(response), response.headers

        log_path = root / "backend.log"
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(app / "v2rayN.WebAPI"), "--foreground", "--no-open", "--urls", base_url],
                cwd=app, env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 40
                while True:
                    if process.poll() is not None:
                        raise RuntimeError(f"Backend exited during startup with code {process.returncode}.")
                    try:
                        health, headers = request("/api/health")
                        if health != {"status": "ok"}:
                            raise RuntimeError("Unexpected health response.")
                        if headers.get("X-v2rayn-WebAPI-instance-pid") != str(process.pid):
                            raise RuntimeError("Health response belongs to a different process.")
                        break
                    except (urllib.error.URLError, TimeoutError):
                        if time.monotonic() >= deadline:
                            raise RuntimeError("Backend did not become healthy within 40 seconds.")
                        time.sleep(0.2)

                request("/api/status", expected=401)
                login, _ = request("/api/auth/login", "POST", {"key": management_key})
                token = login["data"]["token"]
                tokens.append(token)
                status, _ = request("/api/status", token=token)
                state = status["data"]
                if state.get("runtimeState") != "stopped" or state.get("coreProcessIds"):
                    raise RuntimeError("The smoke test must not run a proxy Core.")
                if not {"profiles", "subscriptions", "events.sse"}.issubset(state.get("capabilities", [])):
                    raise RuntimeError("Required backend capabilities are missing.")
                for path in ("/api/profiles", "/api/subscriptions", "/api/editor-options", "/api/operations"):
                    result, _ = request(path, token=token)
                    if result.get("success") is not True:
                        raise RuntimeError(f"Read-only API failed: {path}")

                tun, _ = request("/api/macos/tun", token=token)
                if app_bundle and tun["data"]["helperCode"] == "signed_app_bundle_required":
                    raise RuntimeError("The backend did not discover the native client in its bundle.")
                if tun["data"]["enabled"]:
                    raise RuntimeError("Fresh isolated data must not enable TUN.")
                if not tun["data"]["helperAvailable"]:
                    rejected, _ = request("/api/macos/tun", "PUT", {"enabled": True}, token=token, expected=400)
                    if rejected.get("code") != "mac_tun_helper_unavailable":
                        raise RuntimeError("TUN must fail closed without an authorized helper.")
                tun, _ = request("/api/macos/tun", token=token)
                if tun["data"]["enabled"] or not (root / "data" / "guiConfigs").is_dir():
                    raise RuntimeError("TUN state or dedicated macOS data scope is incorrect.")

                ticket_result, _ = request("/api/auth/sse-ticket", "POST", token=token)
                ticket = ticket_result["data"]["ticket"]
                tokens.append(ticket)
                # The upstream stream first flushes on an event or its 60-second heartbeat.
                # Waiting for that heartbeat keeps this probe free of business mutations.
                with opener.open(base_url + "/api/events?sse_ticket=" + ticket, timeout=70) as stream:
                    if not stream.headers.get("Content-Type", "").startswith("text/event-stream"):
                        raise RuntimeError("Expected an SSE event stream.")
                    if not stream.readline().startswith(b":"):
                        raise RuntimeError("Expected an SSE heartbeat comment.")
                request("/api/events?sse_ticket=" + ticket, expected=401)
                request("/api/auth/logout", "POST", token=token)
                request("/api/status", token=token, expected=401)
                process.terminate()
                process.wait(timeout=45)
                if process.returncode != 0:
                    raise RuntimeError(f"Backend shutdown returned {process.returncode}.")
            except BaseException:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=45)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                detail = log_path.read_text(errors="replace")[-10000:]
                for secret in tokens:
                    detail = detail.replace(secret, "<redacted>")
                if detail:
                    print(detail)
                raise
        print("macOS backend smoke passed: owned process, authentication, read-only APIs, SSE and graceful exit.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("publish_directory", type=Path, nargs="?")
    parser.add_argument("--app-bundle", type=Path, help="Check an integration bundle using an isolated copy.")
    arguments = parser.parse_args()
    if arguments.publish_directory is None and arguments.app_bundle is None:
        parser.error("Specify a publish directory or --app-bundle.")
    check(arguments.publish_directory, arguments.app_bundle)
