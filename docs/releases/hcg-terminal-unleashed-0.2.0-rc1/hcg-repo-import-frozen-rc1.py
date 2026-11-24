"""Import the frozen HCG Terminal Unleashed 0.2.0~rc1 .deb into HCG Repo's candidate channel.

Same checks and channel handling as `bin/hcgrepo import-request` (importer.run_request), but the bytes
come from the owner's frozen copy instead of the CI artifact, which expired on 2026-11-25.
Usage (from the HCG-repo checkout): python3 import_frozen_rc1.py <path to .deb> [--dry-run]
"""
import sys
from pathlib import Path

repo = Path.cwd()
sys.path.insert(0, str(repo / "tools"))
from hcgrepo.config import load_config  # noqa: E402
from hcgrepo.importer import import_deb, set_channel  # noqa: E402

PACKAGE, VERSION, ARCH = "com.hakmicapitalgroup.hcgterminal.unleashed", "0.2.0~rc1", "iphoneos-arm64"
SHA256 = "02626804763200f9e29d651a213bdb92330351d3052073e6a52cb86d62fc5a28"
COMMIT = "1cc76a791cf785f80f4bd742224cd681c612d806"

deb = Path(sys.argv[1]); dry = "--dry-run" in sys.argv[2:]
cfg = load_config()
prov = {"source": "local-file", "original_filename": deb.name, "repository": "F1r3srp3nt/HCG-Terminal",
        "commit": COMMIT, "request": "hcg-terminal-unleashed-0.2.0-rc1-rootless",
        "note": "Frozen 0.2.0~rc1 candidate: bytes from Apple build run #72 (run 45051075163), artifact "
                "hcg-terminal-unleashed-rootless-rc (ID 14765917921), kept by the owner after the artifact expired."}
expect = {"package": PACKAGE, "version": VERSION, "architecture": ARCH, "sha256": SHA256}
status, rep = import_deb(cfg, deb, prov, dry_run=dry, expect=expect, channel="candidate")
if status == "imported" and not dry:
    set_channel(cfg, PACKAGE, VERSION, ARCH, "candidate")
if rep.items:
    print(rep.render())
print(f"{status.upper()}: {deb.name}")
sys.exit(0 if status in ("imported", "already-present", "validated") else 1)
