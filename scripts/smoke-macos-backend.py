#!/usr/bin/env python3
"""Check a published macOS backend using disposable data and no proxy Core."""

import argparse
import io
import sqlite3
import zipfile
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


def check(publish_directory, app_bundle=None, check_backup=False, check_restore=False):
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

        def request(path, method="GET", body=None, token=None, expected=200, binary=False):
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
                return (response.read() if binary else json.load(response)), response.headers

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

                if check_backup or check_restore:
                    # Only disposable configuration is mutated; no remote WebDAV connection is made.
                    fixture_password = secrets.token_urlsafe(24)
                    tokens.append(fixture_password)
                    settings = {"url": " https://example.invalid/ ", "userName": " fixture ",
                                "password": fixture_password, "dirName": " backups "}
                    saved, _ = request("/api/settings/webdav", "PUT", settings, token=token)
                    if not saved.get("success"):
                        raise RuntimeError("WebDAV settings save failed.")
                    settings.pop("password")
                    saved, _ = request("/api/settings/webdav", "PUT", settings, token=token)
                    view, _ = request("/api/settings/webdav", token=token)
                    if not saved.get("success") or view["data"] != {
                            "url": "https://example.invalid/", "userName": "fixture",
                            "dirName": "backups", "hasPassword": True}:
                        raise RuntimeError("WebDAV normalization or omitted-password preservation failed.")
                    archive, _ = request("/api/backup/download", token=token, binary=True)
                    with zipfile.ZipFile(io.BytesIO(archive)) as backup:
                        names = backup.namelist()
                        if any("webapi-auth.json" in name.lower() for name in names):
                            raise RuntimeError("Authentication material entered the backup.")
                        if any(name.endswith(("guiNDB.db-wal", "guiNDB.db-shm", "guiNDB.db-journal")) for name in names):
                            raise RuntimeError("Live SQLite sidecars entered the backup.")
                        config_name = next(name for name in names if name.endswith("guiConfigs/guiNConfig.json"))
                        config = json.loads(backup.read(config_name))
                        if config["WebDavItem"]["Password"] != fixture_password:
                            raise RuntimeError("Backup did not preserve the saved WebDAV credential.")
                        database_name = next(name for name in names if name.endswith("guiConfigs/guiNDB.db"))
                        database_copy = root / "backup-probe.db"
                        database_copy.write_bytes(backup.read(database_name))
                    with sqlite3.connect(database_copy) as database:
                        if database.execute("PRAGMA integrity_check").fetchone() != ("ok",):
                            raise RuntimeError("Downloaded backup database is inconsistent.")
                    after, _ = request("/api/status", token=token)
                    if after["data"].get("coreProcessIds"):
                        raise RuntimeError("Backup/settings probe unexpectedly launched a Core.")
                    print("Backup API passed: settings transaction, omitted credential, authenticated download, SQLite integrity and auth exclusion.")

                if check_restore:
                    # Restore only the archive generated above from this disposable host.
                    settings["userName"] = "changed-after-backup"
                    request("/api/settings/webdav", "PUT", settings, token=token)
                    auth_file = root / "data/guiConfigs/WebAPI-auth.json"
                    auth_before = auth_file.read_bytes() if auth_file.exists() else None
                    boundary = "restore-probe-" + secrets.token_hex(12)
                    payload = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"backup.zip\"\r\n"
                               "Content-Type: application/zip\r\n\r\n").encode() + archive + f"\r\n--{boundary}--\r\n".encode()
                    upload = urllib.request.Request(base_url + "/api/backup/restore", payload, {
                        "Authorization": f"Bearer {token}", "Content-Type": f"multipart/form-data; boundary={boundary}"}, method="POST")
                    with opener.open(upload, timeout=30) as response:
                        restored = json.load(response)
                        if response.status != 202 or not restored.get("success") or not restored["data"].get("restartRequired"):
                            raise RuntimeError("Disposable restore did not hand off restart.")
                    process.wait(timeout=45)
                    if process.returncode != 0:
                        raise RuntimeError("Restore host did not exit cleanly.")
                    if auth_before is not None and auth_file.read_bytes() != auth_before:
                        raise RuntimeError("Restore replaced local authentication material.")
                    safety = root / "data/guiBackups" / restored["data"]["safetyBackup"]
                    if not safety.is_file():
                        raise RuntimeError("Restore safety backup was not retained.")
                    # macOS's native controller owns relaunch; this isolated probe
                    # performs that relaunch explicitly after the old host exits.
                    process = subprocess.Popen(
                        [str(app / "v2rayN.WebAPI"), "--foreground", "--no-open", "--urls", base_url],
                        cwd=app, env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                    deadline = time.monotonic() + 40
                    while True:
                        if process.poll() is not None:
                            raise RuntimeError("Restored host exited during startup.")
                        try:
                            _, headers = request("/api/health")
                            if headers.get("X-v2rayn-WebAPI-instance-pid") == str(process.pid):
                                break
                        except (urllib.error.URLError, TimeoutError):
                            pass
                        if time.monotonic() >= deadline:
                            raise RuntimeError("Restored host health timeout.")
                        time.sleep(0.2)
                    login, _ = request("/api/auth/login", "POST", {"key": management_key})
                    token = login["data"]["token"]
                    tokens.append(token)
                    restored_settings, _ = request("/api/settings/webdav", token=token)
                    restored_status, _ = request("/api/status", token=token)
                    if restored_settings["data"]["userName"] != "fixture" or not restored_settings["data"]["hasPassword"]:
                        raise RuntimeError("Restored configuration did not survive host restart.")
                    if restored_status["data"].get("coreProcessIds") or restored_status["data"].get("runtimeState") != "stopped":
                        raise RuntimeError("Restore did not preserve stopped runtime intent.")
                    print("Restore API passed: upload, safety backup, clean shutdown, explicit relaunch, configuration and stopped runtime recovery.")

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
                if check_backup or check_restore:
                    # The first scheduled release check may now be awaiting the
                    # network. A detached check must not block exclusive writes.
                    settings["userName"] = "after-scheduled-check"
                    saved, _ = request("/api/settings/webdav", "PUT", settings, token=token)
                    view, _ = request("/api/settings/webdav", token=token)
                    if not saved.get("success") or view["data"]["userName"] != settings["userName"]:
                        raise RuntimeError("Settings save after the scheduled check failed.")
                    print("Post-heartbeat settings save passed within the API timeout.")
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
    parser.add_argument("--check-backup", action="store_true", help="Exercise settings and backup download using disposable data only.")
    parser.add_argument("--check-restore", action="store_true", help="Restore a generated backup and relaunch the disposable host.")
    arguments = parser.parse_args()
    if arguments.publish_directory is None and arguments.app_bundle is None:
        parser.error("Specify a publish directory or --app-bundle.")
    check(arguments.publish_directory, arguments.app_bundle, arguments.check_backup, arguments.check_restore)
