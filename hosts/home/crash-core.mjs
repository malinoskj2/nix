import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { createInterface } from "node:readline";

const [bpftrace, script] = process.argv.slice(2);

const signals = { 4: "SIGILL", 6: "SIGABRT", 7: "SIGBUS", 8: "SIGFPE", 11: "SIGSEGV" };
const containerCgroup = /\/(docker|libpod|cri-containerd|crio)-[0-9a-f]{12,}\.scope(\/|$)|\/docker\/[0-9a-f]{12,}(\/|$)|^\/machine\.slice\//;

function coreId(cpu) {
  try {
    return readFileSync(`/sys/devices/system/cpu/cpu${cpu}/topology/core_id`, "utf8").trim();
  } catch {
    return "?";
  }
}

function field(value) {
  return /^[\x21-\x7e]+$/.test(value) && !value.includes('"') ? value : JSON.stringify(value);
}

function format(line) {
  const parts = line.split("\t");
  if (parts.length < 11) return null;
  const [time, sig, code, pid, tid, cpu, priorAgeNs, priorCpu, priorSig, cgroupPaths] = parts;
  const cgroup = cgroupPaths.replace(/^unified:/, "");
  const comm = parts.slice(10).join("\t");
  const out = [
    `time=${time}`,
    `signal=${signals[sig] ?? `SIG${sig}`}`,
    `code=${code}`,
    `comm=${field(comm)}`,
    `pid=${pid}`,
    `tid=${tid}`,
    `cpu=${cpu}`,
    `core=${coreId(cpu)}`,
    `container=${containerCgroup.test(cgroup) ? "yes" : "no"}`,
    `cgroup=${field(cgroup)}`,
  ];
  if (Number(priorCpu) >= 0) {
    out.push(
      `handled_signal=${signals[priorSig] ?? `SIG${priorSig}`}`,
      `handled_cpu=${priorCpu}`,
      `handled_core=${coreId(priorCpu)}`,
      `handled_ms_ago=${(Number(priorAgeNs) / 1e6).toFixed(3)}`,
    );
  }
  return out.join(" ");
}

const child = spawn(bpftrace, ["-q", "-B", "line", script], { stdio: ["ignore", "pipe", "inherit"] });
let stopping = false;
for (const name of ["SIGTERM", "SIGINT"]) {
  process.on(name, () => {
    stopping = true;
    child.kill(name);
  });
}

createInterface({ input: child.stdout }).on("line", (line) => {
  const formatted = format(line);
  process.stdout.write(`${formatted ?? line}\n`);
});

child.on("exit", (code) => {
  process.exitCode = stopping ? 0 : code || 1;
});
