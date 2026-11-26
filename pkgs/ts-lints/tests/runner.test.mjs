import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const runner = path.join(here, "..", "bin", "ts-lints.mjs");
const created = [];

after(() => {
  for (const directory of created) {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

function fixture(name, { installed }) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), `ts-lints-${name}-`));
  created.push(directory);
  fs.cpSync(path.join(here, "fixtures", name), directory, { recursive: true });
  if (installed) {
    fs.mkdirSync(path.join(directory, "node_modules"));
  }
  return directory;
}

function run(directory) {
  const result = spawnSync(process.execPath, [runner, "--json", directory], { cwd: os.tmpdir(), encoding: "utf8" });
  return { status: result.status, report: JSON.parse(result.stdout) };
}

function rules(report) {
  return new Set(report.findings.map((finding) => finding.rule));
}

test("lints a TypeScript project from another directory with types and the strict type check", () => {
  const directory = fixture("ts-app", { installed: true });
  const { status, report } = run(directory);
  assert.equal(status, 1);
  assert.deepEqual(report.files, { typed: 1, untyped: 0 });
  for (const rule of [
    "jesse/no-catch-all-module",
    "jesse/no-boolean-literal-argument",
    "@typescript-eslint/no-floating-promises",
    "TS1294",
  ]) {
    assert.ok(rules(report).has(rule), `missing ${rule} in ${[...rules(report)].join(" ")}`);
  }
  assert.deepEqual(fs.readdirSync(path.join(directory, "node_modules")), []);
});

test("lints a Vue project without installed dependencies untyped and says so", () => {
  const directory = fixture("vue-app", { installed: false });
  const { status, report } = run(directory);
  assert.equal(status, 1);
  assert.equal(report.vue, true);
  assert.deepEqual(report.files, { typed: 0, untyped: 2 });
  assert.deepEqual(report.tsconfigs, []);
  for (const rule of ["jesse/vue-no-index-key", "jesse/vue-lazy-route-component"]) {
    assert.ok(rules(report).has(rule), `missing ${rule} in ${[...rules(report)].join(" ")}`);
  }
  assert.ok(report.notices.some((notice) => notice.includes("no node_modules")));
});

test("keeps a project's explicit compiler option and reports it", () => {
  const directory = fixture("ts-app", { installed: true });
  const tsconfig = path.join(directory, "tsconfig.json");
  const config = JSON.parse(fs.readFileSync(tsconfig, "utf8"));
  config.compilerOptions.erasableSyntaxOnly = false;
  fs.writeFileSync(tsconfig, JSON.stringify(config));
  const { report } = run(directory);
  assert.ok(!rules(report).has("TS1294"));
  assert.deepEqual(report.project_overrides, [
    { option: "erasableSyntaxOnly", ours: true, project: false, tsconfig: "tsconfig.json" },
  ]);
});

test("reports a broken tsconfig and keeps TS2353 outside Vue templates", () => {
  const directory = fixture("ts-app", { installed: true });
  fs.writeFileSync(
    path.join(directory, "src", "options.ts"),
    "export const options: { valid: number } = { valid: 1, 'data-secret': 1 };\n",
  );
  const { report } = run(directory);
  assert.ok(rules(report).has("TS2353"));

  fs.writeFileSync(path.join(directory, "tsconfig.json"), "{broken");
  const broken = run(directory);
  assert.equal(broken.status, 1);
  assert.ok(broken.report.findings.some((finding) => finding.file === "tsconfig.json" && finding.tool === "tsc"));
});

test("reads vueCompilerOptions through extends", () => {
  const directory = fixture("ts-app", { installed: true });
  const tsconfig = path.join(directory, "tsconfig.json");
  const config = JSON.parse(fs.readFileSync(tsconfig, "utf8"));
  fs.writeFileSync(path.join(directory, "base.json"), JSON.stringify({ vueCompilerOptions: { strictTemplates: false } }));
  fs.writeFileSync(tsconfig, JSON.stringify({ ...config, extends: "./base.json" }));
  const { report } = run(directory);
  assert.ok(
    report.project_overrides.some(
      (override) => override.option === "vueCompilerOptions.strictTemplates" && override.project === false,
    ),
  );
});

test("fails with status 2 on a missing directory", () => {
  const result = spawnSync(process.execPath, [runner, "--json", path.join(os.tmpdir(), "ts-lints-missing")], {
    encoding: "utf8",
  });
  assert.equal(result.status, 2);
  assert.equal(JSON.parse(result.stdout).status, "failed");
});
