"""Read-only network baseline helpers shared by the local TUN checks."""
import importlib.util
from pathlib import Path
_spec=importlib.util.spec_from_file_location('v2raym_tun_local',Path(__file__).with_name('test-macos-tun-local.py'))
_module=importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)
command=_module.command
capture_network=_module.capture_network
restoration=_module.restoration
restored=_module.restored
