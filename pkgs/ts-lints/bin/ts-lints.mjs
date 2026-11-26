#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { ESLint } from "eslint";
import ts from "typescript";
import { createConfig } from "../config.mjs";

const DATA_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(import.meta.url);
const STRICT = JSON.parse(fs.readFileSync(path.join(DATA_DIR, "tsconfig.strict.json"), "utf8"));
const SOURCE_EXTENSIONS = new Set([".ts", ".tsx", ".mts", ".cts", ".vue"]);
const SKIPPED_DIRS = new Set([
  "node_modules",
  ".git",
  "dist",
  "build",
  "coverage",
  ".tmp",
  ".nuxt",
  ".output",
  ".vite",
  "target",
]);
const VUE_EXTENSION = [{ extension: ".vue", isMixedContent: true, scriptKind: ts.ScriptKind.Deferred }];
const EXIT_CLEAN = 0;
const EXIT_FINDINGS = 1;
const EXIT_FAILURE = 2;
const USAGE = `usage: ts-lints [options] [directory]

Lint a TypeScript or Vue project with the shared rules, regardless of its own ESLint config.

  --json       print a machine-readable report
  --no-types   skip type-aware lint rules
  --no-tsc     skip the strict type-check pass
  --paths      print the files that define the rules and exit
  -h, --help   show this help

Exit status: 0 clean, 1 findings, 2 a tool failure.`;

class RunError extends Error {}

function walk(root) {
  const sources = [];
  const tsconfigs = [];
  const packageFiles = [];
  const pending = [root];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        if (!SKIPPED_DIRS.has(entry.name)) {
          pending.push(full);
        }
      } else if (entry.name === "tsconfig.json") {
        tsconfigs.push(full);
      } else if (entry.name === "package.json") {
        packageFiles.push(full);
      } else if (SOURCE_EXTENSIONS.has(path.extname(entry.name)) && !entry.name.endsWith(".d.ts")) {
        sources.push(full);
      }
    }
  }
  return { sources: sources.sort(), tsconfigs, packageFiles };
}

function dependsOn(manifests, name) {
  return manifests.some((manifest) =>
    ["dependencies", "devDependencies", "peerDependencies"].some((field) => manifest[field]?.[name] !== undefined),
  );
}

function readManifests(packageFiles, notices) {
  return packageFiles.flatMap((file) => {
    try {
      return [JSON.parse(fs.readFileSync(file, "utf8"))];
    } catch (error) {
      notices.push(`${file}: ${error.message}`);
      return [];
    }
  });
}

function parseTsconfig(file, notices) {
  const read = ts.readConfigFile(file, ts.sys.readFile);
  if (read.error) {
    notices.push(`${file}: ${ts.flattenDiagnosticMessageText(read.error.messageText, "\n")}`);
    return null;
  }
  return ts.parseJsonConfigFileContent(read.config, ts.sys, path.dirname(file), undefined, file, undefined, VUE_EXTENSION);
}

function projectClosure(file, cache, notices, seen = new Set()) {
  if (seen.has(file)) {
    return [];
  }
  seen.add(file);
  if (!cache.has(file)) {
    cache.set(file, parseTsconfig(file, notices));
  }
  const parsed = cache.get(file);
  if (!parsed) {
    return [];
  }
  const projects = [{ file, parsed, files: new Set(parsed.fileNames) }];
  for (const reference of parsed.projectReferences ?? []) {
    const target = ts.resolveProjectReferencePath(reference);
    if (fs.existsSync(target)) {
      projects.push(...projectClosure(target, cache, notices, seen));
    } else {
      notices.push(`${file}: referenced project ${target} does not exist`);
    }
  }
  return projects;
}

function nearestTsconfig(file, root, roots) {
  for (let current = path.dirname(file); ; current = path.dirname(current)) {
    const candidate = path.join(current, "tsconfig.json");
    if (roots.has(candidate)) {
      return candidate;
    }
    if (current === root || current === path.dirname(current)) {
      return null;
    }
  }
}

function planProjects(root, sources, tsconfigs, notices) {
  const cache = new Map();
  const closures = new Map(tsconfigs.map((file) => [file, projectClosure(file, cache, notices)]));
  const leaves = new Map();
  for (const projects of closures.values()) {
    for (const project of projects) {
      if (project.parsed.fileNames.length > 0) {
        leaves.set(project.file, project);
      }
    }
  }
  const installed = new Map();
  const typed = [];
  const untyped = [];
  const roots = new Set(tsconfigs);
  for (const file of sources) {
    const tsconfig = nearestTsconfig(file, root, roots);
    const included = tsconfig && closures.get(tsconfig).some((project) => project.files.has(file));
    if (!included) {
      untyped.push(file);
      continue;
    }
    if (!installed.has(tsconfig)) {
      installed.set(tsconfig, dependencyDir(path.dirname(tsconfig), root) !== null);
      if (!installed.get(tsconfig)) {
        notices.push(`${path.relative(root, tsconfig)}: no node_modules installed, so its files are linted without types and not type-checked`);
      }
    }
    (installed.get(tsconfig) ? typed : untyped).push(file);
  }
  const checked = [...leaves.values()].filter((project) => dependencyDir(path.dirname(project.file), root) !== null);
  return { typed, untyped, leaves: checked };
}

async function lint(root, files, options) {
  if (files.length === 0) {
    return [];
  }
  const eslint = new ESLint({
    cwd: root,
    overrideConfigFile: true,
    overrideConfig: createConfig({ root, ...options }),
    warnIgnored: false,
    errorOnUnmatchedPattern: false,
  });
  const results = await eslint.lintFiles(files);
  return results.flatMap((result) =>
    result.messages.map((message) => ({
      tool: "eslint",
      rule: message.ruleId ?? "fatal",
      severity: message.severity === 2 || message.fatal ? "error" : "warning",
      message: message.message,
      file: path.relative(root, result.filePath),
      line: message.line ?? null,
      column: message.column ?? null,
    })),
  );
}

const DEPRECATED = [
  ["baseUrl", (value) => value !== undefined],
  ["moduleResolution", (value) => value === ts.ModuleResolutionKind.Classic || value === ts.ModuleResolutionKind.Node10],
  ["target", (value) => value === ts.ScriptTarget.ES3 || value === ts.ScriptTarget.ES5],
  ["module", (value) => [ts.ModuleKind.None, ts.ModuleKind.AMD, ts.ModuleKind.UMD, ts.ModuleKind.System].includes(value)],
  ["outFile", (value) => value !== undefined],
  ["downlevelIteration", (value) => value !== undefined],
  ["esModuleInterop", (value) => value === false],
  ["allowSyntheticDefaultImports", (value) => value === false],
  ["alwaysStrict", (value) => value === false],
];

function deprecatedOptions(project, tsconfig) {
  if (project.parsed.options.ignoreDeprecations !== undefined) {
    return [];
  }
  return DEPRECATED.filter(([option, deprecated]) => deprecated(project.parsed.options[option])).map(([option]) => ({
    tool: "tsc",
    rule: "TS5101",
    severity: "error",
    message: `Option '${option}' is deprecated in TypeScript 6 and stops working in TypeScript 7.`,
    file: tsconfig,
    line: null,
    column: null,
  }));
}

function strictOptions(project) {
  const ours = {};
  const overrides = [];
  for (const [option, value] of Object.entries(STRICT.compilerOptions)) {
    const current = project.parsed.options[option];
    if (current === undefined) {
      ours[option] = value;
    } else if (current !== value) {
      overrides.push({ option, ours: value, project: current });
    }
  }
  const vue = {};
  const projectVue = project.parsed.raw?.vueCompilerOptions ?? {};
  for (const [option, value] of Object.entries(STRICT.vueCompilerOptions)) {
    if (projectVue[option] === undefined) {
      vue[option] = value;
    } else if (projectVue[option] !== value) {
      overrides.push({ option: `vueCompilerOptions.${option}`, ours: value, project: projectVue[option] });
    }
  }
  return { ours, vue, overrides };
}

const DATA_ATTRIBUTE_UNKNOWN = /^Object literal may only specify known properties, and ''data-/;
const DIAGNOSTIC = /^(.+?)\((\d+),(\d+)\): (error|warning) (TS\d+): (.*)$/;
const GLOBAL_DIAGNOSTIC = /^(error|warning) (TS\d+): (.*)$/;

function parseDiagnostic(line, root, tsconfig, wrapper) {
  const located = DIAGNOSTIC.exec(line);
  if (located) {
    const [, file, row, column, severity, rule, message] = located;
    const absolute = path.resolve(root, file);
    if (absolute === wrapper) {
      return { tool: "tsc", rule, severity, message, file: tsconfig, line: null, column: null };
    }
    return {
      tool: "tsc",
      rule,
      severity,
      message,
      file: path.relative(root, absolute),
      line: Number(row),
      column: Number(column),
    };
  }
  const global = GLOBAL_DIAGNOSTIC.exec(line);
  if (global) {
    const [, severity, rule, message] = global;
    return { tool: "tsc", rule, severity, message, file: tsconfig, line: null, column: null };
  }
  return null;
}

function parseDiagnostics(output, root, tsconfig, wrapper) {
  const findings = [];
  let current = null;
  for (const line of output.split("\n")) {
    const diagnostic = parseDiagnostic(line, root, tsconfig, wrapper);
    if (diagnostic) {
      const ignored = diagnostic.rule === "TS2353" && DATA_ATTRIBUTE_UNKNOWN.test(diagnostic.message);
      current = ignored ? null : diagnostic;
      if (current) {
        findings.push(current);
      }
    } else if (line.startsWith("  ") && current) {
      current.message += `\n${line.trimEnd()}`;
    }
  }
  return findings;
}

function dependencyDir(directory, root) {
  for (let current = directory; ; current = path.dirname(current)) {
    if (fs.existsSync(path.join(current, "node_modules"))) {
      return path.join(current, "node_modules");
    }
    if (current === root || current === path.dirname(current)) {
      return null;
    }
  }
}

function removeEmptyDirs(directory, topmost) {
  if (!topmost) {
    return;
  }
  for (let current = directory; current.startsWith(topmost); current = path.dirname(current)) {
    try {
      fs.rmdirSync(current);
    } catch {
      return;
    }
  }
}

function typeCheck(root, leaves, vue, notices) {
  const findings = [];
  const overrides = [];
  const checker = require.resolve(vue ? "vue-tsc/bin/vue-tsc.js" : "typescript/bin/tsc");
  const checkerName = vue ? "vue-tsc" : "tsc";
  for (const [index, project] of leaves.entries()) {
    const tsconfig = path.relative(root, project.file);
    const strict = strictOptions(project);
    overrides.push(...strict.overrides.map((override) => ({ ...override, tsconfig })));
    const scratch = path.join(dependencyDir(path.dirname(project.file), root), ".cache", "ts-lints");
    const created = fs.mkdirSync(scratch, { recursive: true });
    const wrapper = path.join(scratch, `tsconfig.${process.pid}.${index}.json`);
    const config = {
      extends: project.file,
      compilerOptions: {
        ...strict.ours,
        composite: false,
        declaration: false,
        declarationMap: false,
        emitDeclarationOnly: false,
        incremental: false,
        ignoreDeprecations: "6.0",
        noEmit: true,
      },
      vueCompilerOptions: strict.vue,
    };
    fs.writeFileSync(wrapper, JSON.stringify(config));
    let result;
    try {
      result = spawnSync(process.execPath, [checker, "-p", wrapper, "--pretty", "false"], {
        cwd: root,
        encoding: "utf8",
        maxBuffer: 256 * 1024 * 1024,
      });
    } finally {
      fs.rmSync(wrapper, { force: true });
      removeEmptyDirs(scratch, created);
    }
    if (result.error) {
      throw new RunError(`${checkerName} failed to start: ${result.error.message}`);
    }
    const diagnostics = parseDiagnostics(result.stdout, root, tsconfig, wrapper);
    if (result.status !== 0 && diagnostics.length === 0) {
      throw new RunError(`${checkerName} -p ${tsconfig} exited ${result.status}: ${result.stderr.trim()}`);
    }
    if (diagnostics.length > 0 && diagnostics.every((finding) => finding.line === null)) {
      notices.push(`${tsconfig}: configuration errors stopped the type check before it reached the source files`);
    }
    findings.push(...deprecatedOptions(project, tsconfig), ...diagnostics);
  }
  const unique = new Map(findings.map((finding) => [`${finding.file}:${finding.line}:${finding.column}:${finding.rule}`, finding]));
  return { findings: [...unique.values()], overrides };
}

function compareFindings(a, b) {
  return a.file.localeCompare(b.file) || (a.line ?? 0) - (b.line ?? 0) || (a.column ?? 0) - (b.column ?? 0);
}

async function run(args) {
  const root = path.resolve(args.positionals[0] ?? ".");
  if (!fs.statSync(root, { throwIfNoEntry: false })?.isDirectory()) {
    throw new RunError(`${root} is not a directory`);
  }
  const notices = [];
  const { sources, tsconfigs, packageFiles } = walk(root);
  const manifests = readManifests(packageFiles, notices);
  const vue = sources.some((file) => file.endsWith(".vue")) || dependsOn(manifests, "vue");
  const vitest = dependsOn(manifests, "vitest");
  const plan = planProjects(root, sources, tsconfigs, notices);
  if (args.values["no-types"]) {
    plan.untyped.push(...plan.typed.splice(0));
  }
  const findings = [
    ...(await lint(root, plan.typed, { vue, vitest, typed: true })),
    ...(await lint(root, plan.untyped, { vue, vitest, typed: false })),
  ];
  let overrides = [];
  if (!args.values["no-tsc"] && plan.leaves.length > 0) {
    const checked = typeCheck(root, plan.leaves, vue, notices);
    findings.push(...checked.findings);
    overrides = checked.overrides;
  }
  findings.sort(compareFindings);
  return {
    status: findings.length > 0 ? "findings" : "clean",
    root,
    vue,
    files: { typed: plan.typed.length, untyped: plan.untyped.length },
    tsconfigs: plan.leaves.map((project) => path.relative(root, project.file)),
    findings,
    project_overrides: overrides,
    notices,
    errors: [],
  };
}

function countBy(findings) {
  const counts = new Map();
  for (const finding of findings) {
    counts.set(finding.rule, (counts.get(finding.rule) ?? 0) + 1);
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
}

function printHuman(report) {
  for (const finding of report.findings) {
    const location = finding.line === null ? finding.file : `${finding.file}:${finding.line}:${finding.column}`;
    console.log(`${location}  ${finding.severity}  ${finding.rule}  ${finding.message}`);
  }
  if (report.findings.length > 0) {
    console.log("\nFindings by rule:");
    for (const [rule, count] of countBy(report.findings)) {
      console.log(`  ${String(count).padStart(5)}  ${rule}`);
    }
  }
  for (const override of report.project_overrides) {
    console.log(`project override: ${override.tsconfig} sets ${override.option} = ${JSON.stringify(override.project)} (ours: ${JSON.stringify(override.ours)})`);
  }
  for (const notice of report.notices) {
    console.log(`notice: ${notice}`);
  }
  for (const error of report.errors) {
    console.log(`error: ${error}`);
  }
  const files = report.files ? `${report.files.typed} typed and ${report.files.untyped} untyped files` : "no files";
  console.log(`\n${report.findings.length} findings in ${files}; type-checked ${report.tsconfigs.length} tsconfigs${report.vue ? " with vue-tsc" : ""}.`);
}

function printPaths() {
  console.log(`lint levels:      ${path.join(DATA_DIR, "config.mjs")}`);
  console.log(`custom rules:     ${path.join(DATA_DIR, "plugin", "rules")}`);
  console.log(`compiler flags:   ${path.join(DATA_DIR, "tsconfig.strict.json")}`);
}

function exitStatus(report) {
  if (report.errors.length > 0) {
    return EXIT_FAILURE;
  }
  return report.findings.length > 0 ? EXIT_FINDINGS : EXIT_CLEAN;
}

async function main(argv) {
  let args;
  try {
    args = parseArgs({
      args: argv,
      allowPositionals: true,
      options: {
        json: { type: "boolean" },
        "no-types": { type: "boolean" },
        "no-tsc": { type: "boolean" },
        paths: { type: "boolean" },
        help: { type: "boolean", short: "h" },
      },
    });
  } catch (error) {
    console.error(`${error.message}\n\n${USAGE}`);
    return EXIT_FAILURE;
  }
  if (args.values.help) {
    console.log(USAGE);
    return EXIT_CLEAN;
  }
  if (args.values.paths) {
    printPaths();
    return EXIT_CLEAN;
  }
  let report;
  try {
    report = await run(args);
  } catch (error) {
    const message = error instanceof RunError ? error.message : String(error?.stack ?? error);
    report = { status: "failed", findings: [], project_overrides: [], notices: [], errors: [message], tsconfigs: [] };
  }
  if (args.values.json) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    printHuman(report);
  }
  return exitStatus(report);
}

process.exitCode = await main(process.argv.slice(2));
