import sys
from collections.abc import MutableMapping
from pathlib import Path

import tomlkit


def merge(dst, src):
    for key, value in src.items():
        old = dst.get(key)
        if isinstance(old, MutableMapping) and isinstance(value, MutableMapping):
            merge(old, value)
        else:
            dst[key] = value


settings = tomlkit.parse(Path(sys.argv[1]).read_text())
target = Path(sys.argv[2])
if target.exists():
    config = tomlkit.parse(target.read_text())
else:
    config = tomlkit.document()
merge(config, settings)
target.unlink(missing_ok=True)
target.write_text(tomlkit.dumps(config))
