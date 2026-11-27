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
  # Recovers from a SIGSEGV, prints its PID, then exits, or aborts when given an argument.
  segvRecover = pkgs.writeCBin "segv-recover" ''
    #include <setjmp.h>
    #include <signal.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    static sigjmp_buf env;
    static void handler(int sig) { siglongjmp(env, 1); }
    int main(int argc, char **argv) {
      signal(SIGSEGV, handler);
      if (!sigsetjmp(env, 1)) *(volatile int *)0 = 0;
      printf("%d\n", getpid());
      fflush(stdout);
      if (argc > 1) abort();
      return 0;
    }
  '';
  # Generates SIGABRT twice while it is blocked, so the second is already pending, and consumes it.
  abortBlocked = pkgs.writeCBin "abort-blocked" ''
    #include <signal.h>
    int main(void) {
      sigset_t set;
      int sig;
      sigemptyset(&set);
      sigaddset(&set, SIGABRT);
      sigprocmask(SIG_BLOCK, &set, 0);
      raise(SIGABRT);
      raise(SIGABRT);
      sigwait(&set, &sig);
      return 0;
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
      segvRecover
      abortBlocked
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
    machine.succeed("abort-blocked")
    machine.succeed("segv-recover recover-then-abort || true")
    # A recovered SIGSEGV must not attach to whatever process later reuses its PID.
    recovered = int(machine.succeed("segv-recover").strip())
    machine.succeed(f"echo {recovered - 1} > /proc/sys/kernel/ns_last_pid; abort-self || true")
    machine.succeed("segv-self || true")
    machine.succeed("segv-handled || true")
    machine.succeed("systemd-run --scope --unit=docker-0123456789abcdef.scope abort-self || true")
    machine.wait_until_succeeds("journalctl -b -t crash-core -o cat | grep comm=segv-handled", timeout=60)

    abort = [l for l in lines() if " comm=abort-self " in l][0]
    print(abort)
    assert re.search(r" signal=SIGABRT code=-6 ", abort), abort
    assert re.search(r" cpu=\d+ core=\d+ deliver_cpu=\d+ container=no cgroup=/system.slice/backdoor.service$", abort), abort

    assert not any("comm=abort-blocked" in l for l in lines()), "a blocked, consumed SIGABRT was logged"

    recover = line_for("segv-recover")
    assert re.search(r" signal=SIGABRT .* handled_signal=SIGSEGV handled_cpu=\d+ ", recover), recover

    reused = [l for l in lines() if " comm=abort-self " in l and f" pid={recovered} " in l]
    assert len(reused) == 1, f"PID {recovered} was not reused by abort-self: {lines()}"
    assert "handled_" not in reused[0], reused[0]

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
