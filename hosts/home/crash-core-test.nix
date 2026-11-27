{ pkgs }:
let
  abortSelf = pkgs.writeCBin "abort-self" ''
    #include <stdlib.h>
    int main(void) { abort(); }
  '';
  segvSelf = pkgs.writeCBin "segv-self" ''
    int main(void) { return *(volatile int *)0; }
  '';
  # A crash reporter's pattern: catch the fault, restore the default action, return and fault again.
  segvHandled = pkgs.writeCBin "segv-handled" ''
    #include <signal.h>
    static void handler(int sig) { signal(sig, SIG_DFL); }
    int main(void) {
      signal(SIGSEGV, handler);
      return *(volatile int *)0;
    }
  '';
  victim = pkgs.writeCBin "kill-victim" ''
    #include <unistd.h>
    int main(void) { for (;;) pause(); }
  '';
in
{
  name = "crash-core";

  nodes.machine = {
    imports = [ ./crash-core.nix ];
    boot.kernelPackages = pkgs.linuxPackages_6_18;
    virtualisation.cores = 2;
    environment.systemPackages = [
      abortSelf
      segvSelf
      segvHandled
      victim
    ];
  };

  testScript = ''
    import re

    def lines():
        return machine.succeed("journalctl -b -t crash-core -o cat").splitlines()

    def line_for(comm):
        found = [l for l in lines() if f" comm={comm} " in l]
        assert len(found) == 1, f"expected one {comm} line, got {found}"
        return found[0]

    machine.wait_for_unit("crash-core.service")
    # bpftrace prints nothing once attached, so abort until the first line shows up.
    machine.wait_until_succeeds("abort-self || true; journalctl -b -t crash-core -o cat | grep comm=abort-self", timeout=120)

    machine.succeed("kill-victim >/dev/null 2>&1 & pid=$!; sleep 1; kill -ABRT $pid; wait $pid || true")
    machine.succeed("segv-self || true")
    machine.succeed("segv-handled || true")
    machine.succeed("systemd-run --scope --unit=docker-0123456789abcdef.scope abort-self || true")
    machine.wait_until_succeeds("journalctl -b -t crash-core -o cat | grep comm=segv-handled", timeout=60)

    abort = [l for l in lines() if " comm=abort-self " in l][0]
    print(abort)
    assert re.search(r" signal=SIGABRT code=-6 ", abort), abort
    assert re.search(r" cpu=\d+ core=\d+ container=no cgroup=/system.slice/backdoor.service$", abort), abort

    segv = line_for("segv-self")
    assert re.search(r" signal=SIGSEGV code=1 .* cpu=\d+ core=\d+ ", segv), segv
    assert "handled_cpu" not in segv, segv

    handled = line_for("segv-handled")
    assert re.search(r" handled_signal=SIGSEGV handled_cpu=\d+ handled_core=\d+ ", handled), handled

    container = [l for l in lines() if "docker-0123456789abcdef.scope" in l]
    assert len(container) == 1 and " container=yes " in container[0], container

    assert not any("comm=kill-victim" in l for l in lines()), "another process's kill() was logged"

    machine.succeed("test \"$(systemctl show -P NRestarts crash-core.service)\" = 0")
    machine.succeed("pkill -x bpftrace")
    machine.wait_until_succeeds("test \"$(systemctl show -P NRestarts crash-core.service)\" = 1")
    machine.wait_for_unit("crash-core.service")
    print(machine.succeed("systemd-analyze security crash-core.service | tail -n 1"))
  '';
}
