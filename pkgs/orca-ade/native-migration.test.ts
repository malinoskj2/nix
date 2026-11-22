import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { chmodSync, copyFileSync, cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { structuredAgentCommandPlan } from '../../shared/agent-launch/startup/tui-agent-launch-command-override'
import { resolveExecutableCommand } from '../../shared/shell/command-resolution/node-cli-command-resolution'
import { localPluginPublisher, gitUrlPluginPublisher } from '../../shared/plugins/installation/plugin-publisher-derivation'
import { parsePluginAppThemeArtifact } from '../../shared/plugins/artifacts/plugin-theme-artifact'
import { isOrcadExecutableArtifact, orcadTemplateCommonFilenames } from '../../shared/remote-runtime/orcad-distribution/orcad-artifacts'
import { orcadLaunchCommand } from '../managed-server/install/orcad-remote-launch'
import { getRemoteHostPlatform } from '../ssh/remote-host/ssh-remote-platform'

import { bootstrapBundledPlugins } from '../plugins/bootstrap/plugin-bundled-bootstrap'
import { installPluginFromLocalPath, readPluginLockfile } from '../plugins/installation/plugin-install'
import { writePluginLockfile } from '../plugins/installation/plugin-install-lockfile-store'
import { writePluginInstallProvenance } from '../plugins/installation/plugin-install-provenance'

const roots: string[] = []
const temporary = () => {
  const path = mkdtempSync(join(tmpdir(), 'orca-native-migration-'))
  roots.push(path)
  return path
}
afterEach(() => roots.splice(0).forEach((path) => rmSync(path, { recursive: true, force: true })))

function executable(path: string, source: string) {
  writeFileSync(path, source)
  chmodSync(path, 0o755)
}

describe('Nix native migrations against this Orca release', () => {
  it('accepts the literal wrapper Command and resolves it against the execution host home', () => {
    const home = temporary()
    const bin = join(home, '.orca/nix/bin')
    mkdirSync(bin, { recursive: true })
    copyFileSync('nix-sandbox-launch.sh', join(bin, 'orca-sandbox-launch'))
    chmodSync(join(bin, 'orca-sandbox-launch'), 0o755)
    for (const agent of ['codex', 'claude', 'antigravity']) {
      const command = `~/.orca/nix/bin/orca-sandbox-launch orca-sandbox ${agent}`
      const plan = structuredAgentCommandPlan(command, 'linux')!
      expect(plan).toEqual({ program: '~/.orca/nix/bin/orca-sandbox-launch', prefixArgs: ['orca-sandbox', agent] })
      expect(resolveExecutableCommand(plan.program, { homePath: home, platform: 'linux', pathEnv: '/usr/bin:/bin' })).toBe(join(bin, 'orca-sandbox-launch'))
    }
  })

  it('preserves Linux/Darwin dispatch and all argv, stripping only the provenance marker', () => {
    const bin = temporary()
    const launcher = resolve('nix-sandbox-launch.sh')
    executable(join(bin, 'agent-sandbox-exec'), '#!/bin/sh\nprintf "<%s>\\n" "$@"\n')
    executable(join(bin, 'sandbox-first'), '#!/bin/sh\nprintf "<%s>\\n" "$@"\n')
    executable(join(bin, 'sandbox-second'), '#!/bin/sh\nexit 99\n')
    for (const host of ['Linux', 'Darwin']) {
      executable(join(bin, 'uname'), `#!/bin/sh\necho ${host}\n`)
      const result = execFileSync('/bin/sh', [launcher, 'orca-sandbox', 'codex', '--resume', 'a b', '--flag=$literal'], { env: { ...process.env, PATH: bin }, encoding: 'utf8' })
      expect(result).toBe('<codex>\n<--resume>\n<a b>\n<--flag=$literal>\n')
    }
  })

  it('delivers a hashed executable template resource and installs it before native lookup', () => {
    const template = readFileSync('nix-orcad-template-path', 'utf8').trim()
    const name = 'bin/orca-sandbox-launch'
    const resource = join(template, name)
    expect(orcadTemplateCommonFilenames([])).toContain(name)
    expect(isOrcadExecutableArtifact(name)).toBe(true)
    expect(statSync(resource).mode & 0o111).toBe(0o111)
    const manifest = JSON.parse(readFileSync(join(template, 'orcad-template.json'), 'utf8'))
    expect(manifest.commonSha256[name]).toBe(createHash('sha256').update(readFileSync(resource)).digest('hex'))
    const home = temporary()
    const slot = join(home, 'slot with spaces')
    mkdirSync(join(slot, 'bin'), { recursive: true })
    copyFileSync(resource, join(slot, name))
    const command = orcadLaunchCommand(getRemoteHostPlatform('darwin-arm64'), {
      remoteInstallDir: slot, nodePath: process.execPath, fullVersion: 'test',
      activationRoot: join(home, '.activation'), userDataDir: join(home, '.orca'), bindHost: '127.0.0.1', port: 7777
    })
    // Run only the real deployment fragment, without starting a daemon or contacting a host.
    const fragment = command.slice(command.indexOf('if [ -f bin/orca-sandbox-launch ]; then'), command.indexOf('fi &&') + 2)
    execFileSync('/bin/sh', ['-c', fragment], { cwd: slot, env: { ...process.env, HOME: home } })
    const installed = join(home, '.orca/nix/bin/orca-sandbox-launch')
    expect(readFileSync(installed)).toEqual(readFileSync(resource))
    expect(statSync(installed).mode & 0o777).toBe(0o755)
    expect(resolveExecutableCommand('~/.orca/nix/bin/orca-sandbox-launch', { homePath: home, platform: 'darwin', pathEnv: '/usr/bin:/bin' })).toBe(installed)
  })

  it('preserves legacy bundle data and disable callbacks until a same-identity native install', async () => {
    const home = temporary()
    const pluginsDir = join(home, 'plugins')
    const root = join(home, 'official-bundles')
    mkdirSync(root)
    writeFileSync(join(root, 'bundled-plugins.json'), JSON.stringify({ version: 1, plugins: [] }))
    for (const key of ['chron0.discord-presence', 'etherll.usage-insights']) {
      const sourcePath = resolve(`nix-plugins/${key}`)
      const input = { pluginsDir, sourcePath, hostVersion: '1.4.268' }
      const legacySource = join(home, 'legacy', key)
      cpSync(sourcePath, legacySource, { recursive: true })
      rmSync(join(legacySource, 'nix-installation.json'))
      expect((await installPluginFromLocalPath({ ...input, sourcePath: legacySource })).ok).toBe(true)
      const lock = await readPluginLockfile(pluginsDir)
      const legacy = { ...lock.plugins[key], source: { kind: 'bundled' as const, bundleId: key } }
      lock.plugins[key] = legacy
      // Model the persisted state created by the old Nix bundling patch, including recovery provenance.
      await writePluginInstallProvenance(join(pluginsDir, key), legacy)
      await writePluginLockfile(pluginsDir, lock)
      const data = join(home, 'plugins-data', key)
      mkdirSync(data, { recursive: true })
      writeFileSync(join(data, 'settings.json'), '{"keep":"my data"}')
      const retired: string[] = []
      await bootstrapBundledPlugins({ root, userDataPath: home, hostVersion: '1.4.268', beforeRetire: (pluginKey) => { retired.push(pluginKey) } })
      expect(retired).toEqual([])
      expect(readFileSync(join(data, 'settings.json'), 'utf8')).toBe('{"keep":"my data"}')
      expect((await readPluginLockfile(pluginsDir)).plugins[key].source.kind).toBe('bundled')
      expect((await installPluginFromLocalPath(input)).ok).toBe(true)
      expect((await readPluginLockfile(pluginsDir)).plugins[key].source).toEqual({ kind: 'local-path', path: sourcePath })
      // A repeat remains the same native source rather than restoring the legacy provenance.
      expect((await installPluginFromLocalPath(input)).ok).toBe(true)
      expect((await readPluginLockfile(pluginsDir)).plugins[key].source).toEqual({ kind: 'local-path', path: sourcePath })
      expect(readFileSync(join(data, 'settings.json'), 'utf8')).toBe('{"keep":"my data"}')
    }
  })

  it('uses public theme artifacts and local publishers for the existing third-party identities', () => {
    const theme = parsePluginAppThemeArtifact(readFileSync('nix-plugins/local.catppuccin-mocha/mocha.json', 'utf8'), 'strict')
    expect(theme.tokens['--background']).toBe('#1e1e2e')
    expect(theme.tokenColors?.some((rule) => JSON.stringify(rule.scope).includes('markup.heading'))).toBe(true)
    for (const key of ['chron0.discord-presence', 'etherll.usage-insights']) {
      const manifest = JSON.parse(readFileSync(`nix-plugins/${key}/orca-plugin.json`, 'utf8'))
      expect(`${localPluginPublisher(manifest.publisher)}.${manifest.id}`).toBe(key)
    }
    expect(gitUrlPluginPublisher('https://github.com/jondmarien/orca-discord-presence')).toBe('jondmarien')
  })
})
