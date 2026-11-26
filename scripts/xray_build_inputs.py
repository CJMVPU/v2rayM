"""Verify the ordered source patches used by the pinned macOS Xray build."""
import hashlib


def verified_patch_names(root, inputs, *, library):
    patches = dict(inputs["xray"]["patches"])
    if library:
        patches.update(inputs["xrayLibraryPatches"])
    for name, expected in patches.items():
        path = root / "patches/xray" / name
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Reviewed Xray patch checksum mismatch: {name}")
    return list(patches)
