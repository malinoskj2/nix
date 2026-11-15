"""Install shared guidance without replacing Muse's writable preferences."""

import json
import os
from pathlib import Path
import sys
import tempfile

START = "<!-- nix-resource-scheduler:start -->"
END = "<!-- nix-resource-scheduler:end -->"


def merge(instructions, target):
    data = json.loads(target.read_text()) if target.exists() else {}
    data.setdefault("schema_version", 1)
    run = data.setdefault("run", {})
    prompt = run.get("developer_prompt", "")
    if not isinstance(prompt, str):
        raise ValueError("Muse run.developer_prompt must be a string")
    if START in prompt:
        prefix, rest = prompt.split(START, 1)
        if END not in rest:
            raise ValueError("Incomplete managed resource guidance; refusing to overwrite")
        _, suffix = rest.split(END, 1)
        prompt = prefix + suffix
    run["developer_prompt"] = prompt.rstrip() + "\n\n" + START + "\n" + instructions.read_text() + END + "\n"
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=target.parent, prefix=".resources-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)


if __name__ == "__main__":
    merge(Path(sys.argv[1]), Path(sys.argv[2]))
