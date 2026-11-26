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
from xray_build_inputs import verified_patch_names

INPUTS = json.loads((Path(__file__).resolve().parents[1] / "contracts/macos-build-inputs.json").read_text())
REVISION = INPUTS["xray"]["revision"]
SOURCE_SHA256 = INPUTS["xray"]["sourceSHA256"]
MARKER = INPUTS["xray"]["buildMarker"]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", default="go")
    parser.add_argument("--source-archive", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--library", action="store_true", help="Build the in-process library from the same reviewed and tested tree")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output must not exist")
    go = shutil.which(args.go)
    if not go or ("go" + INPUTS["goVersion"] + " darwin/") not in subprocess.check_output([go, "version"], text=True):
        parser.error("use the verified Go " + INPUTS["goVersion"] + " Darwin toolchain")
    repo = Path(__file__).resolve().parent.parent
    marker = MARKER
    patches = verified_patch_names(repo, INPUTS, library=args.library)
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
        env.update(GOTOOLCHAIN="local", CGO_ENABLED="1" if args.library else "0")
        def run(command):
            subprocess.run(command, cwd=tree, env=env, check=True)
        for filename in patches:
            with (repo / "patches/xray" / filename).open("rb") as patch:
                subprocess.run(["patch", "-p1", "--batch"], stdin=patch, cwd=tree, check=True)
        shutil.copyfile(repo / "scripts/xray/process_darwin_test.go", tree / "common/net/v2raym_process_darwin_test.go")
        shutil.copyfile(repo / "scripts/xray/process_router_test.go", tree / "app/router/v2raym_process_test.go")
        run([go, "test", "./common/net", "./app/router", "-run", "^(TestV2rayM|TestFindProcessDarwin|TestDarwinSocketInfo)", "-count=1", "-v"])
        run([go, "test", "./proxy/tun", "-run", "^TestDarwin(OutboundSocket|WildcardUDP)Binding$", "-count=1", "-v"])
        flags = ["-trimpath", "-buildvcs=false", "-ldflags", "-s -w -X github.com/xtls/xray-core/core.build=" + marker]
        if args.library:
            for package, fixture in [("app/dns", "doh_recovery_test.go"), ("transport/internet/splithttp", "xhttp_recovery_test.go")]:
                shutil.copyfile(repo / "scripts/xray" / fixture, tree / package / "v2raym_recovery_test.go")
            run([go, "test", "./app/dns", "./transport/internet/splithttp", "-run", "^TestV2rayM", "-count=1", "-timeout=60s", "-v"])
            bridge = tree / "v2raymlib"
            bridge.mkdir()
            bridge_sources = {}
            for source in sorted((repo / "scripts/xray/library").glob("*.go")):
                shutil.copy2(source, bridge / source.name)
                bridge_sources[source.name] = hashlib.sha256(source.read_bytes()).hexdigest()
            binary = root / "libV2rayMXray.dylib"
            run([go, "build", *flags, "-buildmode=c-shared", "-o", str(binary), "./v2raymlib"])
            run(["install_name_tool", "-id", "@rpath/" + binary.name, str(binary)])
            run(["codesign", "--force", "--sign", "-", str(binary)])
        else:
            binary = root / "xray"
            run([go, "build", *flags, "-o", str(binary), "./main"])
        args.output.mkdir(parents=True)
        shutil.copy2(binary, args.output / binary.name)
        if args.library:
            receipt = {"inputs": INPUTS["xray"], "libraryPatches": INPUTS["xrayLibraryPatches"], "goVersion": INPUTS["goVersion"],
                       "bridgeSources": bridge_sources,
                       "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest()}
            (args.output / "library-build.json").write_text(json.dumps(receipt, indent=2) + "\n")
            shutil.copy2(binary.with_suffix(".h"), args.output / binary.with_suffix(".h").name)
        shutil.copy2(tree / "LICENSE", args.output / "LICENSE")
        (args.output / "SOURCE.txt").write_text(f"Xray source: {REVISION}\nArchive SHA256: {SOURCE_SHA256}\nPatches: {', '.join(patches)}\nBuild: {marker}\n")
        if args.library:
            print("Built pinned Xray library:", args.output / binary.name)
        else:
            print(subprocess.check_output([str(args.output / "xray"), "version"], text=True))

if __name__ == "__main__":
    main()
