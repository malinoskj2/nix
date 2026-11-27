# Crash cores on the home desktop

An unstable Curve Optimizer offset shows up as crashes that cluster on one
physical core. The kernel log names the core only for segfaults
(`likely on CPU N (core M)`), and systemd-coredump records none, so `home`
runs `crash-core.service` (`hosts/home/crash-core.nix`), which logs one journal
line for every fatal SIGSEGV, SIGABRT, SIGBUS, SIGILL and SIGFPE:

```
time=2026-11-27T17:24:12.616359+0000 signal=SIGABRT code=-6 comm=abort-self pid=809 tid=809 cpu=0 core=0 container=no cgroup=/system.slice/backdoor.service
```

List them since a time with:

```sh
journalctl -t crash-core --since '2026-11-27 12:00' -o short-iso
```

bpftrace's own startup messages share the identifier, so a parser should
take only the lines that start with `time=`:

```sh
journalctl -t crash-core --since '2026-11-27 12:00' -o cat --grep '^time=\S+ signal='
```

## Fields

- `signal`, `code`: the signal and its `si_code`. Positive codes come from the
  kernel (`1` is `SEGV_MAPERR`, `2` `SEGV_ACCERR`, `128` `SI_KERNEL`); `-6`
  (`SI_TKILL`) is a thread raising it itself, as `abort()` does.
- `comm`, `pid`, `tid`: the thread, with process and thread IDs in the host's
  PID namespace, including for containers.
- `cpu`, `core`: the logical CPU the thread was running on when the signal was
  generated, and its `topology/core_id`. SMT siblings share a core id.
- `container`: `yes` when the thread's cgroup is a Docker, Podman, containerd,
  CRI-O or `machine.slice` one; `cgroup` is the full cgroup v2 path.
- `handled_signal`, `handled_cpu`, `handled_core`, `handled_ms_ago`: present
  when the same thread earlier caught one of these signals with its own
  handler. A crash reporter catches the first fault, restores the default
  action and faults again or aborts; the handled CPU is where the original
  fault happened.

## How it decides

A bpftrace program on the `signal:signal_generate` tracepoint filters in the
kernel to those five signals and to signals the thread generates for itself:
a CPU fault (the kernel sends it to the faulting thread), or `abort()`,
`raise()` or `kill(getpid(), …)`. Signals another process sends with
`kill`, `tgkill` or `sigqueue` are skipped, whatever their `si_code`. So is a
signal one thread sends to a sibling with `pthread_kill`, unless it targets the
main thread. It reads the thread's handler for the signal at that moment: with
the default action the line is logged, since that signal kills the process; with
a handler only the CPU is remembered for a later fatal line (up to 4096
threads). Ignored signals are dropped. A Node formatter adds the core id and
container flag and writes to the journal as `crash-core`.

Nothing runs per syscall; the tracepoint fires only when a signal is generated.

## How reliable the CPU is

For a fault the tracepoint runs in the faulting thread's exception handler,
before it returns to user space, so `cpu` is the CPU that executed the faulting
instruction unless the thread was preempted and migrated inside the handler,
which is rare. For `abort()` it is the CPU that ran the `tgkill` call.

Neither is necessarily the CPU that made the mistake. A bad result can sit in a
register or in memory while the thread is migrated, and the crash happens
later, elsewhere, when something trips over it; a corrupted pointer can even
be dereferenced by another thread. So treat one line as weak evidence and look
for a core that recurs across many crashes, across unrelated programs. Pinning
a suspected workload with `taskset` or testing the core with CoreCycler
confirms it.

The service runs as root with only `CAP_BPF` and `CAP_PERFMON`, no network,
a read-only filesystem, a system call filter and no W+X memory (Node runs
`--jitless`), and restarts five seconds after any exit. While it restarts, crashes
go unrecorded. The `crash-core-vm` check boots it, aborts and segfaults test
programs and checks the lines, including the container flag, that an external
`kill -ABRT` isn't logged, and that the service restarts when bpftrace dies.
