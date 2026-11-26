import json
import re
import sys

groups = {}
in_groups = False
for line in sys.stdin:
    if line.startswith("Lint groups loaded by this crate:"):
        in_groups = True
        continue
    match = re.match(r"^\s+clippy::(\S+)\s+(clippy::.*)$", line) if in_groups else None
    if match:
        members = [name.strip().removeprefix("clippy::").replace("-", "_") for name in match[2].split(",")]
        groups[match[1].replace("-", "_")] = sorted(clippy for clippy in members if clippy)
json.dump(groups, sys.stdout, indent=1, sort_keys=True)
