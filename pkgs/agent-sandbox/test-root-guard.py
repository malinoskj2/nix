#!/usr/bin/env python3
"""Every container given the host nix-daemon socket runs as the launching user, never root.

nix-daemon trusts root, and Docker runs container root as host root, so a root process holding the
socket would be a trusted client. Each source that mounts the socket must pass --user and refuse to
run as root itself, and the image's entrypoint refuses to start as root with the socket present.
"""

import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
failures = []
mounting = []
for path in sorted(root.rglob("*")):
    if not path.is_file() or path.suffix not in (".sh", ".py") or path.name.startswith("test-"):
        continue
    text = path.read_text()
    if "/nix/var/nix/daemon-socket:" not in text:
        continue
    mounting.append(path.name)
    if not re.search(r'"--user",?\s*\n?\s*f"\{(os\.getuid\(\)|uid)\}:|--user "\$uid:\$gid"', text):
        failures.append(f"{path.name}: mounts the nix-daemon socket without --user set to the caller's uid")
    if not re.search(r"refusing to run as root", text):
        failures.append(f"{path.name}: mounts the nix-daemon socket without refusing to run as root")
    if re.search(r'--user[ "=,\n]+(0|root)\b', text):
        failures.append(f"{path.name}: passes --user root")

entrypoint = (root / "entrypoint.sh").read_text()
if "refusing to start as root with the nix-daemon socket" not in entrypoint:
    failures.append("entrypoint.sh: doesn't refuse to start as root with the nix-daemon socket")
for name in ("agent-sandbox.sh", "runner.py"):
    if name not in mounting:
        failures.append(f"{name}: no longer found mounting the socket; update this check")

for failure in failures:
    print(failure, file=sys.stderr)
sys.exit(1 if failures else 0)
