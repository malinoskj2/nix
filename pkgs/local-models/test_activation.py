"""Exercise the rendered activation without contacting a live systemd manager."""

import json
import os
from pathlib import Path
import subprocess
import tempfile


activation = Path(os.environ["ACTIVATION"]).read_text()
service = json.loads(Path(os.environ["SERVICE"]).read_text())
path = json.loads(Path(os.environ["PATH_UNIT"]).read_text())
for unit in [service, path]:
    assert not unit.get("Install", {}).get("WantedBy")
    assert unit["Unit"]["X-SwitchMethod"] == "keep-old"
assert service["Service"]["Type"] == "oneshot"
assert not service["Service"].get("RemainAfterExit", False)
assert not service["Service"].get("Restart")
assert service["Service"]["SetCredential"] == "hf-token:unconfigured"

with tempfile.TemporaryDirectory() as directory:
    home = Path(directory)
    root = home / ".local/share/models"
    log = home / "systemctl.log"
    spy = home / "systemctl"
    spy.write_text("#!" + os.environ["TEST_BASH"] + '\nprintf "%s\\n" "$*" >> "$SPY_LOG"\n')
    spy.chmod(0o755)
    store = home / "install-store"
    script = (
        activation.replace(os.environ["INSTALL_STORE"], str(store))
        .replace(os.environ["MODEL_ROOT"], str(root))
        .replace(os.environ["SYSTEMCTL"], str(spy))
    )
    script = 'set -eu\nrun() { if [ -z "${DRY_RUN_CMD:-}" ]; then "$@"; fi; }\n' + script
    environment = {**os.environ, "HOME": str(home), "SPY_LOG": str(log)}
    subprocess.run([os.environ["TEST_BASH"], "-c", script], env={**environment, "DRY_RUN_CMD": "echo"}, check=True)
    assert not root.exists() and not store.exists() and not log.exists(), "Dry run must not enqueue anything"
    for _ in range(2):
        subprocess.run([os.environ["TEST_BASH"], "-c", script], env=environment, check=True)
        assert (root / ".state/pending").is_file()
        assert store.is_dir(), "Activation must create every store"
        assert not (root / "readiness.json").exists(), "Activation must not run downloads inline"
    requests = log.read_text().splitlines()
    assert len(requests) == 4, "Unchanged switches must also enqueue a sync"
    assert all("--user start --no-block local-models-sync." in line for line in requests)
print("Rendered activation: dry run, first switch, unchanged switch and nonblocking requests passed")
