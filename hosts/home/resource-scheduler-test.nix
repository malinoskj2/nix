{ pkgs, ... }:
let
  probe = pkgs.writeText "resource-scheduler-probe.py" ''
    import json, os, pathlib, socket
    cgroup = pathlib.Path("/proc/self/cgroup").read_text()
    affinity = os.sched_getaffinity(0)
    outside = set(range(os.cpu_count())) - affinity
    affinity_error = None
    if outside:
      try:
        os.sched_setaffinity(0, outside)
      except OSError as error:
        affinity_error = error.errno
      assert os.sched_getaffinity(0) == affinity
    relative = cgroup.strip().split(":")[-1].lstrip("/")
    limits = []
    if ".." not in pathlib.Path(relative).parts:
      current = pathlib.Path("/sys/fs/cgroup") / relative
      while current != pathlib.Path("/sys/fs"):
        limit = current / "memory.max"
        if limit.exists():
          limits.append(limit.read_text().strip())
        current = current.parent
    pathlib.Path("/tmp/resource-result.json").write_text(json.dumps({
      "uid": os.getuid(), "gid": os.getgid(), "groups": os.getgroups(),
      "hostname": socket.gethostname(), "cwd": os.getcwd(),
      "marker": os.environ.get("RESOURCE_TEST_MARKER"),
      "cgroup": cgroup, "memory_limits": limits,
      "affinity": sorted(os.sched_getaffinity(0)),
      "empty_affinity_error": affinity_error,
      "job": os.environ.get("RESOURCE_JOB_ID"),
    }))
    raise SystemExit(7)
  '';
  descendants = pkgs.writeText "resource-scheduler-descendants.py" ''
    import json, pathlib, subprocess, sys, time
    # Two busy build workers make quota throttling observable; detached sessions
    # also exercise cleanup beyond a simple foreground process group.
    children = [subprocess.Popen([sys.executable, "-c", "while True: pass"], start_new_session=True)
                for _ in range(2)]
    pathlib.Path("/tmp/resource-child.json").write_text(json.dumps({"pids": [child.pid for child in children]}))
    time.sleep(600)
  '';
  game = pkgs.writeText "resource-scheduler-game.py" ''
    import time
    time.sleep(600)
  '';
  nvidiaFixture = pkgs.writeShellScriptBin "nvidia-smi" ''
    case "$*" in
      *--query-gpu=*) echo 'GPU-fixture, 32768, 0, 0' ;;
      *--query-compute-apps=*) exit 0 ;;
      *) exit 2 ;;
    esac
  '';
  image = pkgs.dockerTools.buildLayeredImage {
    name = "resource-scheduler-test";
    tag = "latest";
    contents = [ pkgs.busybox ];
    extraCommands = ''
      mkdir -p tmp
      chmod 1777 tmp
    '';
    config.Cmd = [
      "${pkgs.busybox}/bin/sleep"
      "infinity"
    ];
  };
in
{
  name = "resource-scheduler-slurm";
  globalTimeout = 600;
  # TCG also permits this isolated CPU-only test on builders without /dev/kvm.
  requiredFeatures.kvm = false;
  node.pkgsReadOnly = false;
  nodes.machine = { lib, ... }: {
    imports = [ ../common/optional/resource-scheduler.nix ];
    networking.hostName = "home";
    virtualisation = {
      cores = 4;
      memorySize = 2048;
      diskSize = 4096;
      docker.enable = true;
    };
    users.users.agent = {
      isNormalUser = true;
      uid = 1000;
      group = "users";
    };
    users.users.foreign = {
      isNormalUser = true;
      uid = 1001;
      group = "users";
    };
    services.resourceScheduler = {
      enable = true;
      queue.enable = true;
      package = pkgs.resource-scheduler;
      cpuCapacity = 4;
      gameCpuCapacity = 1;
      memoryMiB = 1024;
      ramHeadroomMiB = 128;
      stabilitySeconds = 1;
    };
    services.slurm = {
      nodeName = lib.mkForce [
        "home NodeAddr=127.0.0.1 NodeHostName=home CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=1024 Gres=gpu:1,shard:32768 State=UNKNOWN"
      ];
      # No physical GPU or inference: fake character-device GRES exercise the
      # ordinary CPU submission path without creating a production ledger.
      extraConfigPaths = lib.mkForce [
        (pkgs.writeTextDir "gres.conf" ''
          Name=gpu File=/dev/resource-gpu
          Name=shard Count=32768 File=/dev/resource-gpu
        '')
      ];
      extraConfig = lib.mkAfter "SlurmdParameters=config_overrides\n";
    };
    # Never alias /dev/null: ConstrainDevices correctly withholds unallocated
    # GPU devices, which would also make ordinary job stdin inaccessible.
    systemd.tmpfiles.rules = [
      "c /dev/resource-gpu 0600 root root - 240:0"
      "L+ /run/opengl-driver/bin/nvidia-smi - - - - ${nvidiaFixture}/bin/nvidia-smi"
    ];
    systemd.services.resource-test-game-mode.serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/touch /run/resource-scheduler-game-active";
      ExecStop = "${pkgs.coreutils}/bin/rm -f /run/resource-scheduler-game-active";
    };
    environment.etc = {
      "resource-test-probe".source = probe;
      "resource-test-descendants".source = descendants;
      "resource-test-game".source = game;
      # The shared host store hides the store embedded in the image. Retain
      # BusyBox in the VM closure so its absolute entrypoint is also mounted.
      "resource-test-busybox".source = "${pkgs.busybox}/bin/busybox";
    };
    environment.systemPackages = [
      pkgs.python3
      pkgs.jq
    ];
  };
  testScript = ''
    import json
    def explain_failure(code):
        if code != 7:
            print(machine.succeed("journalctl --no-pager -n 100 -u resource-scheduler -u slurmd -u slurmctld"))
            print(machine.succeed("su - agent -c 'resource-status --json'"))
            print(machine.succeed("scontrol show job --json | jq '.jobs[] | {job_id,exit_code,job_state}'"))
    def status():
        return json.loads(machine.succeed("su - agent -c 'resource-status --json'"))
    def terminate(job):
        fresh = next(item for item in status()["jobs"] if item["id"] == job["id"])
        machine.succeed(f"su - agent -c 'resource-control terminate {fresh['id']} --revision {fresh['revision']} --confirm'")
    def cgroup_for(job):
        group = machine.succeed(f"find /sys/fs/cgroup/system.slice -maxdepth 2 -type d -name job_{job['slurm_job_id']}").strip()
        assert group, job
        return group
    start_all()
    machine.wait_for_unit("resource-scheduler.service")
    machine.wait_until_succeeds("su - agent -c 'resource-status --json'")
    machine.wait_until_succeeds("sinfo -h -o %T | grep -E '^idle$'")
    assert machine.succeed("stat -c '%U:%G:%a' /var/lib/munge/munge.key").strip() == "munge:munge:400"
    assert machine.succeed("stat -c '%u:%g:%a' /run/resource-scheduler/control.sock").strip() == "1000:100:600"
    machine.succeed("su - agent -c 'test ! -r /var/lib/munge/munge.key'")
    machine.fail("su - agent -c 'sbatch --partition=resource --wrap=true'")
    machine.fail("su - foreign -c 'resource-status --json'")

    with subtest("Host command retains Slurm cgroup after privilege drop"):
        code, output = machine.execute("su - agent -c 'cd /tmp && RESOURCE_TEST_MARKER=host resource-run --cpu 1 --ram 64MiB --name host-probe -- ${pkgs.python3}/bin/python3 ${probe}'", timeout=120)
        explain_failure(code)
        assert code == 7, (code, output)
        result = json.loads(machine.succeed("cat /tmp/resource-result.json"))
        print("Host allocation evidence:", result)
        assert result["uid"] == 1000 and result["gid"] == 100 and 0 not in result["groups"], result
        assert result["cwd"] == "/tmp" and result["marker"] == "host", result
        assert result["hostname"] == "home" and result["job"], result
        assert "slurm" in result["cgroup"], result
        assert str(64 * 1024 * 1024) in result["memory_limits"], result
        assert len(result["affinity"]) == 1, result
        assert result["empty_affinity_error"] == 22, result

    with subtest("Docker namespace entry retains Slurm cgroup ownership"):
        machine.succeed("docker load -i ${image}")
        machine.succeed("docker run -d --init --cap-drop ALL --security-opt no-new-privileges --name agent-sandbox-integration --hostname resource-container --user 1000:100 --workdir /tmp --volume /nix/store:/nix/store:ro --volume /run/resource-scheduler:/run/resource-scheduler:ro resource-scheduler-test:latest")
        code, output = machine.execute("docker exec --env AGENT_SANDBOX_INSTANCE=agent-sandbox-integration --env RESOURCE_TEST_MARKER=container agent-sandbox-integration ${pkgs.resource-scheduler}/bin/resource-run --cpu 1 --ram 64MiB --name container-probe -- ${pkgs.python3}/bin/python3 ${probe}", timeout=120)
        explain_failure(code)
        assert code == 7, (code, output)
        result = json.loads(machine.succeed("docker exec agent-sandbox-integration cat /tmp/resource-result.json"))
        assert result["uid"] == 1000 and result["gid"] == 100 and 0 not in result["groups"], result
        assert result["hostname"] == "resource-container", result
        assert result["cwd"] == "/tmp" and result["marker"] == "container", result
        assert "slurm" in result["cgroup"] and result["job"], result
        queue = status()
        assert any(job["id"] == result["job"] and job["origin"] == "agent-sandbox-integration" for job in queue["history"]), queue
        machine.succeed("docker stop agent-sandbox-integration")

    with subtest("Restart reconciles running allocation and cancellation kills detached descendants"):
        machine.succeed("systemd-run --unit resource-test-client --uid agent --working-directory=/tmp ${pkgs.resource-scheduler}/bin/resource-run --cpu 2 --ram 64MiB --category build --name cancellation-probe -- ${pkgs.python3}/bin/python3 ${descendants}")
        machine.wait_until_succeeds("test -f /tmp/resource-child.json")
        machine.wait_until_succeeds("su - agent -c 'resource-status --json' | jq -e '.jobs[] | select(.label == \"cancellation-probe\" and .state == \"running\")'")
        children = json.loads(machine.succeed("cat /tmp/resource-child.json"))["pids"]
        before = json.loads(machine.succeed("su - agent -c 'resource-status --json'"))
        job = next(job for job in before["jobs"] if job["label"] == "cancellation-probe")
        group = cgroup_for(job)
        machine.succeed(f"grep -q '^max ' {group}/cpu.max")
        machine.succeed("systemctl start resource-test-game-mode")
        machine.wait_until_succeeds(f"test $(cut -d' ' -f1 {group}/cpu.max) = 100000")
        machine.wait_until_succeeds(f"grep -Eq '^nr_throttled [1-9]' {group}/cpu.stat")
        assert machine.succeed(f"cat {group}/cpu.weight").strip() == "25"
        machine.succeed("systemctl restart resource-scheduler.service")
        machine.wait_until_succeeds("su - agent -c 'resource-status --json'")
        for child in children:
            machine.succeed(f"kill -0 {child}")
        after = json.loads(machine.succeed("su - agent -c 'resource-status --json'"))
        recovered = next(item for item in after["jobs"] if item["id"] == job["id"])
        assert recovered["slurm_job_id"] == job["slurm_job_id"], recovered
        machine.wait_until_succeeds(f"test $(cut -d' ' -f1 {group}/cpu.max) = 100000")
        machine.succeed("systemctl stop resource-test-game-mode")
        machine.wait_until_succeeds(f"grep -q '^max ' {group}/cpu.max")
        assert machine.succeed(f"cat {group}/cpu.weight").strip() == "100"

        machine.succeed("systemd-run --unit resource-test-game --uid agent --working-directory=/tmp ${pkgs.resource-scheduler}/bin/resource-run --cpu 1 --ram 64MiB --exclusive --priority game --category game --name game-probe -- ${pkgs.python3}/bin/python3 ${game}")
        machine.wait_until_succeeds("su - agent -c 'resource-status --json' | jq -e '.jobs[] | select(.label == \"game-probe\" and .state == \"running\")'")
        managed_game = next(item for item in status()["jobs"] if item["label"] == "game-probe")
        game_group = cgroup_for(managed_game)
        machine.succeed(f"grep -q '^max ' {game_group}/cpu.max")
        machine.wait_until_succeeds(f"test $(cut -d' ' -f1 {group}/cpu.max) = 100000")
        terminate(managed_game)
        machine.wait_until_succeeds("su - agent -c 'resource-status --json' | jq -e '.history[] | select(.label == \"game-probe\" and .state == \"cancelled\")'")
        machine.wait_until_succeeds(f"grep -q '^max ' {group}/cpu.max")
        assert machine.succeed(f"cat {group}/cpu.weight").strip() == "100"
        machine.fail(f"su - agent -c 'resource-control terminate {job['id']} --revision 0 --confirm'")
        terminate(job)
        for child in children:
            machine.wait_until_fails(f"kill -0 {child}")
        machine.wait_until_succeeds("su - agent -c 'resource-status --json' | jq -e '.history[] | select(.label == \"cancellation-probe\" and .state == \"cancelled\")'")

    with subtest("Real Slurm shards overlap and whole-device allocation waits for both"):
        for label in ("shard-one", "shard-two"):
            machine.succeed(f"systemd-run --unit resource-test-{label} --uid agent --working-directory=/tmp ${pkgs.resource-scheduler}/bin/resource-run --cpu 1 --ram 64MiB --vram 1MiB --name {label} -- ${pkgs.python3}/bin/python3 ${game}")
        machine.wait_until_succeeds("su - agent -c 'resource-status --json' | jq -e '[.jobs[] | select((.label == \"shard-one\" or .label == \"shard-two\") and .state == \"running\")] | length == 2'")
        shared = [job for job in status()["jobs"] if job["label"] in ("shard-one", "shard-two")]
        for job in shared:
            assert "shard:1" in machine.succeed(f"scontrol show job -o {job['slurm_job_id']}")
        machine.succeed("systemd-run --unit resource-test-exclusive --uid agent --working-directory=/tmp ${pkgs.resource-scheduler}/bin/resource-run --cpu 1 --ram 64MiB --exclusive --vram 2MiB --name exclusive-probe -- ${pkgs.python3}/bin/python3 ${game}")
        machine.wait_until_succeeds("su - agent -c 'resource-status --json' | jq -e '.jobs[] | select(.label == \"exclusive-probe\" and .state == \"queued\")'")
        exclusive = next(job for job in status()["jobs"] if job["label"] == "exclusive-probe")
        assert "PENDING" in machine.succeed(f"squeue -h -j {exclusive['slurm_job_id']} -o %T")
        terminate(shared[0])
        machine.wait_until_succeeds(f"su - agent -c 'resource-status --json' | jq -e '.history[] | select(.id == \"{shared[0]['id']}\")'")
        assert next(job for job in status()["jobs"] if job["id"] == exclusive["id"])["state"] == "queued"
        assert next(job for job in status()["jobs"] if job["id"] == shared[1]["id"])["state"] == "running"
        terminate(shared[1])
        machine.wait_until_succeeds("su - agent -c 'resource-status --json' | jq -e '.jobs[] | select(.label == \"exclusive-probe\" and .state == \"running\")'")
        assert "gpu:1" in machine.succeed(f"scontrol show job -o {exclusive['slurm_job_id']}")
        terminate(exclusive)
        machine.wait_until_succeeds("su - agent -c 'resource-status --json' | jq -e '.history[] | select(.label == \"exclusive-probe\" and .state == \"cancelled\")'")
  '';
}
