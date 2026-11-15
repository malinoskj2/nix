"""Check the generated opt-in deployment without starting a host service."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile


policy = json.loads(Path(os.environ["POLICY"]).read_text())
compat = (Path(os.environ["COMPAT"]) / "bin/gpu-status").read_text()
assert f'{os.environ["SCHEDULER"]}/bin/resource-scheduler compat status' in compat
assert policy == {
    "socket_path": "/run/resource-scheduler/control.sock",
    "state_dir": "/var/lib/resource-scheduler",
    "allowed_uid": 1000,
    "allowed_gid": 100,
    "partition": "resource",
    "cpu_capacity": 12,
    "game_cpu_capacity": 4,
    "game_marker_path": "/run/resource-scheduler-game-active",
    "ram_headroom_mib": 4096,
    "vram_headroom_mib": 3072,
    "gpu_capacity_mib": 32768,
    "poll_seconds": 2,
    "stability_seconds": 10,
    "history_limit": 500,
    "policy_version": "1",
}

config = Path(os.environ["SLURM_CONFIG"])
slurm = (config / "slurm.conf").read_text()
for required in (
    "AllowGroups=root",
    "RootOnly=YES",
    "EnforcePartLimits=ALL",
    "MaxCPUsPerNode=12",
    "RealMemory=24576",
    "Gres=gpu:1,shard:32768",
    "ProctrackType=proctrack/cgroup",
    "SelectTypeParameters=CR_Core_Memory",
    "JobAcctGatherType=jobacct_gather/cgroup",
    "SlurmctldHost=home(127.0.0.1)",
):
    assert required in slurm, required
assert "Name=shard Count=32768 File=/dev/nvidia0" in (config / "gres.conf").read_text()
for required in (
    "CgroupPlugin=cgroup/v2",
    "EnableControllers=yes",
    "ConstrainRAMSpace=yes",
    "ConstrainDevices=yes",
    "AllowedSwapSpace=0",
):
    assert required in (config / "cgroup.conf").read_text(), required

daemon = json.loads(Path(os.environ["DAEMON"]).read_text())
assert daemon["User"] == "root"
assert daemon["StateDirectoryMode"] == "0700"
assert daemon["UMask"] == "0077"
assert "resource-scheduler daemon --config" in daemon["ExecStart"]
assert daemon["RuntimeDirectoryPreserve"] == "yes"
assert "PrivateUsers" not in daemon and "PrivateTmp" not in daemon
assert daemon["StandardOutput"] == "journal"
game_service = json.loads(Path(os.environ["GAME_SERVICE"]).read_text())
assert "touch /run/resource-scheduler-game-active" in game_service["ExecStartPost"]
assert "rm -f /run/resource-scheduler-game-active" in game_service["ExecStopPost"]
assert "agent-sandbox.slice AllowedCPUs=" in game_service["ExecStart"]

# Existing prompt/settings survive updates; repeated activation is idempotent.
spec = importlib.util.spec_from_file_location("muse_resources", os.environ["MUSE_MERGER"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as temporary:
    target = Path(temporary) / "muse/settings.json"
    target.parent.mkdir()
    target.write_text(json.dumps({"model": "existing", "run": {"developer_prompt": "Personal rules"}}))
    guidance = Path(os.environ["GUIDANCE"])
    module.merge(guidance, target)
    first = target.read_bytes()
    module.merge(guidance, target)
    assert target.read_bytes() == first
    merged = json.loads(target.read_text())
    assert merged["model"] == "existing"
    assert merged["schema_version"] == 1
    assert merged["run"]["developer_prompt"].startswith("Personal rules")
    assert merged["run"]["developer_prompt"].count(module.START) == 1
    assert "resource-run" in merged["run"]["developer_prompt"]
    target.write_text("malformed user settings")
    try:
        module.merge(guidance, target)
    except json.JSONDecodeError:
        assert target.read_text() == "malformed user settings"
    else:
        raise AssertionError("Malformed settings were overwritten")

print("Generated resource policy, Slurm/cgroup configuration and agent guidance verified")
