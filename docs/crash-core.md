# Crash cores on the home desktop

An unstable Curve Optimizer offset shows up as crashes that cluster on one
physical core. The kernel log names the core only for segfaults
(`likely on CPU N (core M)`), and systemd-coredump records none, so `home`
runs `crash-core.service` (`hosts/home/crash-core.nix`), which logs one journal
line each time a thread's own SIGSEGV, SIGABRT, SIGBUS, SIGILL or SIGFPE is
delivered with its default action, which kills the process:

```
time=2026-11-27T17:24:12.616359+0000 signal=SIGABRT code=-6 comm=abort-self pid=809 tid=809 cpu=0 core=0 deliver_cpu=0 container=no cgroup=/system.slice/backdoor.service
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
- `time`, `cpu`, `core`: when the signal was generated, the logical CPU the
  thread was running on then, and its `topology/core_id`. SMT siblings share a
  core id. `deliver_cpu` is where the thread was when it took the signal; it
  differs only if the thread migrated in between.
- `container`: `yes` when the thread's cgroup is a Docker, Podman, containerd,
  CRI-O or `machine.slice` one; `cgroup` is the full cgroup v2 path.
- `handled_signal`, `handled_cpu`, `handled_core`, `handled_ms_ago`: present
  when the same thread caught one of these signals with its own handler in the
  last 10 seconds. A crash reporter catches the first fault, restores the
  default action and faults again or aborts, and then the handled CPU is where
  the original fault happened. It is only the thread's most recent caught
  signal, though: runtimes that use SIGSEGV internally (JVMs, .NET, Wasm
  engines) catch them routinely, so a handled signal before an unrelated abort
  is no evidence about that abort.

## How it decides

A bpftrace program records, on the `signal:signal_generate` tracepoint, the
time, CPU and `si_code` of each of those five signals that a thread generates
for itself: a CPU fault (the kernel sends it to the faulting thread), or
`abort()`, `raise()` or `kill(getpid(), …)`. A signal another process sends
with `kill`, `tgkill` or `sigqueue`, whatever its `si_code`, discards any such
record instead, and so does one thread's `pthread_kill` of a sibling, unless it
targets the main thread. A signal that is ignored, or already pending, records
nothing new.

A kprobe on `dequeue_signal` sees which queue, the thread's or the process's,
each signal is taken from, and takes that queue's record with it, and delivery
uses only that record. A fault, which `get_signal` takes from the thread's
queue without `dequeue_signal`, uses the thread's record. So a signal blocked and consumed with
`sigwait` or `signalfd` is never logged, and its record can't be mistaken for
a later signal from another process.

On `signal:signal_deliver`, after a debugger has had its say: if the default
action runs, the process dies (unless it is an init process, which drops it),
and the line is logged. If the thread's own handler runs, only the CPU is
remembered for the `handled_*` fields. A thread's records are dropped when it
exits (`sched:sched_process_exit`), so a reused thread ID never inherits them. A Node formatter adds the core id and container flag and
writes to the journal as `crash-core`.

Nothing runs per syscall; the probes fire only when a signal is generated,
dequeued or delivered, or a thread exits.

## How reliable the CPU is

For a fault the generation tracepoint runs in the faulting thread's exception
handler, before it returns to user space, so `cpu` is the CPU that executed the
faulting instruction unless the thread was preempted and migrated inside the
handler, which is rare. For `abort()` it is the CPU that ran the `tgkill` call.

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
programs and checks the lines, including the container flag; that an external
`kill -ABRT` and a blocked SIGABRT consumed with `sigwait` aren't logged, nor
is another process's SIGABRT that follows a consumed one; that a
recovered SIGSEGV doesn't attach to a later process with the same PID; and that
the service restarts when bpftrace dies.
