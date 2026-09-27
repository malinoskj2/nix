import { chmod, cp, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";

const { collectSeaTuiAssets } = await import(process.env.ZCODE_SEA_TUI_ASSETS);

const repositoryRoot = process.env.ZCODE_SOURCE_ROOT;
const outRoot = process.env.ZCODE_DIST_ROOT;
const target = process.env.ZCODE_TARGET;
const version = process.env.ZCODE_VERSION;
const cliDirectory = resolve(repositoryRoot, "apps/zcode-cli/packages/cli");

const packageRoot = resolve(outRoot, "zcode");
const agentRoot = resolve(packageRoot, "agent");
await rm(packageRoot, { force: true, recursive: true });
await mkdir(agentRoot, { recursive: true });

const dist = resolve(cliDirectory, "dist");
const bundle = resolve(dist, "zcode.cjs");
for (const file of [bundle, resolve(dist, "provider/zcode-builtin.json")]) {
  if (!(await stat(file).catch(() => false))) throw new Error(`Missing build output: ${file}`);
}
await cp(bundle, resolve(agentRoot, "zcode.cjs"));
await chmod(resolve(agentRoot, "zcode.cjs"), 0o755);
await cp(resolve(dist, "provider"), resolve(agentRoot, "provider"), { recursive: true });
const notices = resolve(dist, "THIRD-PARTY-NOTICES.md");
if (await stat(notices).catch(() => false)) {
  await cp(notices, resolve(agentRoot, "THIRD-PARTY-NOTICES.md"));
}

const { assets, manifest } = await collectSeaTuiAssets({
  root: resolve(repositoryRoot, "apps/zcode-cli"),
  stagingDirectory: resolve(outRoot, "tui-staging"),
  target,
});
try {
  for (const file of manifest.files) {
    const destination = resolve(agentRoot, file.path);
    await mkdir(dirname(destination), { recursive: true });
    await cp(assets[`zcode-tui-runtime/${file.path}`], destination);
    await chmod(destination, file.mode);
  }
} finally {
  await rm(resolve(outRoot, "tui-staging"), { recursive: true, force: true });
}

const requireFromCli = createRequire(resolve(cliDirectory, "package.json"));
const copyExternal = async (packageName) => {
  const packageJsonPath = requireFromCli.resolve(`${packageName}/package.json`);
  const packageDirectory = dirname(packageJsonPath);
  const destination = resolve(agentRoot, "node_modules", ...packageName.split("/"));
  await mkdir(dirname(destination), { recursive: true });
  await cp(packageDirectory, destination, {
    dereference: true,
    force: true,
    recursive: true,
    filter: (source) => {
      if (source === packageDirectory) return true;
      const rel = source.slice(packageDirectory.length + 1);
      return !rel.split("/").includes("node_modules");
    },
  });
};
await copyExternal("playwright-core");

await writeFile(
  resolve(packageRoot, "package.json"),
  `${JSON.stringify({ name: "zcode-runtime", private: true, type: "module", version }, null, 2)}\n`,
);

await mkdir(resolve(packageRoot, "bin"), { recursive: true });
const runner = resolve(packageRoot, "bin", "zcode.mjs");
await cp(resolve(repositoryRoot, "scripts/zcode-distribution/runner.mjs"), runner);
await chmod(runner, 0o755);
