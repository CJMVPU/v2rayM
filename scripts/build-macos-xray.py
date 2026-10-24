#!/usr/bin/env python3
"""Build the pinned Xray Darwin binding fix. Never installs or changes networking."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

INPUTS = json.loads((Path(__file__).resolve().parents[1] / "contracts/macos-build-inputs.json").read_text())
REVISION = INPUTS["xray"]["revision"]
SOURCE_SHA256 = INPUTS["xray"]["sourceSHA256"]
MARKER = INPUTS["xray"]["buildMarker"]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", default="go")
    parser.add_argument("--source-archive", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--process-lookup-fix", action="store_true", default=True, help="Include process lookup fix (M2, enabled by default)")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output must not exist")
    go = shutil.which(args.go)
    if not go or ("go" + INPUTS["goVersion"] + " darwin/") not in subprocess.check_output([go, "version"], text=True):
        parser.error("use the verified Go " + INPUTS["goVersion"] + " Darwin toolchain")
    repo = Path(__file__).resolve().parent.parent
    marker = MARKER
    patches = ["darwin-bound-interface.patch"]
    if args.process_lookup_fix:
        patches.append("darwin-process-lookup.patch")
    for filename in patches:
        if hashlib.sha256((repo / "patches/xray" / filename).read_bytes()).hexdigest() != INPUTS["xray"]["patches"][filename]:
            raise RuntimeError("Reviewed Darwin patch checksum mismatch: " + filename)
    with tempfile.TemporaryDirectory(prefix="v2raym-xray-build-") as work:
        root = Path(work)
        archive = args.source_archive or root / "source.tar.gz"
        if args.source_archive is None:
            urllib.request.urlretrieve("https://api.github.com/repos/XTLS/Xray-core/tarball/" + REVISION, archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != SOURCE_SHA256:
            raise RuntimeError("Pinned source archive checksum mismatch")
        with tarfile.open(archive) as source:
            for item in source.getmembers():
                path = Path(item.name)
                if path.is_absolute() or ".." in path.parts or not (item.isfile() or item.isdir()):
                    raise RuntimeError("Unsafe source archive")
            source.extractall(root)
        tree = next(root.glob("XTLS-Xray-core-*"))
        shutil.copyfile(repo / "scripts/xray/bind_darwin_test.go", tree / "proxy/tun/v2raym_bind_darwin_test.go")
        env = os.environ.copy()
        env.update(GOTOOLCHAIN="local", CGO_ENABLED="0")
        def run(command):
            subprocess.run(command, cwd=tree, env=env, check=True)
        for filename in patches:
            with (repo / "patches/xray" / filename).open("rb") as patch:
                subprocess.run(["patch", "-p1", "--batch"], stdin=patch, cwd=tree, check=True)
        if args.process_lookup_fix:
            shutil.copyfile(repo / "scripts/xray/process_darwin_test.go", tree / "common/net/v2raym_process_darwin_test.go")
            shutil.copyfile(repo / "scripts/xray/process_router_test.go", tree / "app/router/v2raym_process_test.go")
            run([go, "test", "./common/net", "./app/router", "-run", "^(TestV2rayM|TestFindProcessDarwin|TestDarwinSocketInfo)", "-count=1", "-v"])
        run([go, "test", "./proxy/tun", "-run", "^TestDarwin(OutboundSocket|WildcardUDP)Binding$", "-count=1", "-v"])
        binary = root / "xray"
        run([go, "build", "-trimpath", "-buildvcs=false", "-ldflags", "-s -w -X github.com/xtls/xray-core/core.build=" + marker,
             "-o", str(binary), "./main"])
        args.output.mkdir(parents=True)
        shutil.copy2(binary, args.output / "xray")
        shutil.copy2(tree / "LICENSE", args.output / "LICENSE")
        (args.output / "SOURCE.txt").write_text(f"Xray source: {REVISION}\nArchive SHA256: {SOURCE_SHA256}\nPatches: {', '.join(patches)}\nBuild: {marker}\n")
        print(subprocess.check_output([str(args.output / "xray"), "version"], text=True))

if __name__ == "__main__":
    main()
