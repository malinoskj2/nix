#!/usr/bin/env python3
"""Exercise the real widget and provider argv with offline fake CLIs."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = Path(os.environ.get('PLUGIN_TEMPLATE', ROOT / 'zsh-claude-command.plugin.zsh'))
FAKE = '''#!/usr/bin/env python3
import json, os, pathlib, signal, sys, time
provider = pathlib.Path(sys.argv[0]).name
scenario = json.loads(os.environ['SCENARIO'])[provider]
root = pathlib.Path(os.environ['TEST_ROOT'])
(root / (provider + '.args')).write_text(json.dumps(sys.argv[1:]))
if scenario.get('wait'):
    (root / 'ready').touch()
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    while True:
        time.sleep(.02)
if provider == 'codex' and 'output' in scenario:
    path = sys.argv[sys.argv.index('--output-last-message') + 1]
    pathlib.Path(path).write_text(scenario['output'])
    key = next(a for a in sys.argv if a.startswith('model_instructions_file='))
    # Parse exactly as TOML, including a TMPDIR containing quotes/backslashes.
    import tomllib
    prompt = pathlib.Path(tomllib.loads(key)['model_instructions_file'])
    (root / 'codex.prompt').write_text(prompt.read_text())
print(scenario.get('stdout', ''), end='')
print(scenario.get('stderr', ''), end='', file=sys.stderr)
sys.exit(scenario.get('status', 0))
'''
HARNESS = '''
function zle() {
  case "$1" in
    .accept-line) (( accepted += 1 ));;
    -M) message="$2"; messages+=("$2");;
  esac
  return 0
}
typeset -i accepted=0
typeset -a messages=()
source "$TEST_ROOT/plugin.zsh"
BUFFER="$TEST_BUFFER"
CURSOR=3
_zsh_claude_command_accept_line
print -rn -- "$BUFFER" > "$TEST_ROOT/buffer"
print -rn -- "$CURSOR" > "$TEST_ROOT/cursor"
print -rn -- "$message" > "$TEST_ROOT/message"
print -rn -- "$accepted" > "$TEST_ROOT/accepted"
print -rl -- "${messages[@]}" > "$TEST_ROOT/messages"
'''


def success(command):
    return {'stdout': json.dumps({'type': 'result', 'subtype': 'success',
                                 'is_error': False, 'result': command})}


class PluginTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zsh-ai-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Exercise path handling with spaces, double quotes, and literal backslashes.
        self.tmp = self.root / 'temp "quoted" \\ directory'
        self.tmp.mkdir()
        replacements = {'jq': shutil.which('jq'), 'mktemp': shutil.which('mktemp'),
                        'rm': shutil.which('rm')}
        for name in ('claude', 'codex'):
            script = self.root / name
            script.write_text(FAKE.replace('#!/usr/bin/env python3', '#!' + sys.executable))
            script.chmod(0o755)
            replacements[name] = str(script)
        plugin = TEMPLATE.read_text()
        for key, value in replacements.items():
            plugin = plugin.replace('@' + key + '@', value)
        (self.root / 'plugin.zsh').write_text(plugin)

    def run_widget(self, claude=None, codex=None, buffer='# list files', interrupt=None,
                   **extra_env):
        env = os.environ | {'TEST_ROOT': str(self.root), 'TMPDIR': str(self.tmp),
                            'TEST_BUFFER': buffer,
                            'SCENARIO': json.dumps({'claude': claude or success('eza -l'),
                                                    'codex': codex or {'output': 'pwd'}})}
        env.update(extra_env)
        process = subprocess.Popen(['zsh', '-f'], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=env, start_new_session=True)
        def stop_process():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
        self.addCleanup(stop_process)
        if interrupt:
            process.stdin.write(HARNESS)
            process.stdin.close()
            process.stdin = None
            deadline = time.monotonic() + 5
            while not (self.root / 'ready').exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue((self.root / 'ready').exists(), 'fake CLI did not start')
            os.killpg(process.pid, signal.SIGINT)
        stdout, stderr = process.communicate(None if interrupt else HARNESS, timeout=10)
        self.assertEqual(process.returncode, 0, (stdout, stderr))
        self.assertEqual(stdout, '', 'provider output leaked to terminal')
        self.assertEqual(stderr, '', 'provider errors leaked to terminal')
        self.assertEqual(list(self.tmp.iterdir()), [], 'request temp files leaked')
        return (self.root / 'buffer').read_text(), (self.root / 'message').read_text()

    def args(self, provider):
        return json.loads((self.root / (provider + '.args')).read_text())

    def assert_unchanged(self, message_part, **kwargs):
        buffer, message = self.run_widget(**kwargs)
        self.assertEqual(buffer, '# list files')
        self.assertIn(message_part, message)
        self.assertEqual((self.root / 'cursor').read_text(), '3')

    def test_claude_success_only_fills_buffer(self):
        self.assertEqual(self.run_widget(), ('eza -l', ''))
        self.assertFalse((self.root / 'codex.args').exists())
        self.assertEqual((self.root / 'accepted').read_text(), '0')
        self.assertEqual((self.root / 'cursor').read_text(), '6')
        args = self.args('claude')
        self.assertEqual(args[args.index('--tools') + 1], '')
        self.assertEqual(args[args.index('--output-format') + 1], 'json')
        self.assertIn('--safe-mode', args)

    def test_claude_failures_try_codex(self):
        cases = [
            {'status': 1, 'stderr': 'network unavailable'},
            {'status': 127, 'stderr': 'not found'},
            {'status': 139, 'stderr': 'segmentation fault'},
            {'status': 1, 'stdout': "You've hit your limit"},
            {'status': 1, 'stderr': 'not authenticated'},
            {'stdout': json.dumps({'type': 'result', 'subtype': 'success',
                                   'is_error': True, 'result': 'usage limit reached'})},
            {'stdout': json.dumps({'type': 'result', 'subtype': 'error_during_execution',
                                   'is_error': True, 'errors': ['service failed']})},
            {'stdout': 'not valid JSON'},
        ]
        for claude in cases:
            with self.subTest(claude=claude):
                self.assertEqual(self.run_widget(claude=claude), ('pwd', ''))
                self.assertIn('trying Codex', (self.root / 'messages').read_text())
                self.assertEqual((self.root / 'accepted').read_text(), '0')

    def test_success_is_not_classified_by_command_text(self):
        command = "printf '%s\\n' 'quota 429 authentication'"
        self.assertEqual(self.run_widget(claude=success(command)), (command, ''))
        self.assertFalse((self.root / 'codex.args').exists())

    def test_codex_failure_discards_even_a_written_response(self):
        self.assert_unchanged('Codex failed (exit 7)', claude={'status': 1},
                              codex={'status': 7, 'output': 'touch should-not-run'})

    def test_codex_missing_response(self):
        self.assert_unchanged('Codex failed', claude={'status': 1}, codex={'stdout': 'logs'})

    def test_both_usage_limits(self):
        self.assert_unchanged('Claude usage limit; Codex usage limit',
                              claude={'status': 1, 'stdout': "You've hit your limit"},
                              codex={'status': 1, 'stderr': 'quota exceeded'})

    def test_cancelled_claude_never_tries_codex(self):
        for status in (129, 130, 143):
            with self.subTest(status=status):
                self.assert_unchanged('cancelled', claude={'status': status,
                                                         'stderr': 'usage limit'})
                self.assertFalse((self.root / 'codex.args').exists())

    def test_cancelled_codex_discards_response(self):
        self.assert_unchanged('cancelled', claude={'status': 1},
                              codex={'status': 130, 'output': 'pwd'})

    def test_real_sigint_during_claude(self):
        self.assert_unchanged('cancelled', claude={'wait': True}, interrupt=True)
        self.assertFalse((self.root / 'codex.args').exists())

    def test_real_sigint_during_codex(self):
        self.assert_unchanged('cancelled', claude={'status': 1},
                              codex={'wait': True}, interrupt=True)

    def test_empty_multiline_and_invalid_results_preserve_buffer(self):
        for response in ('', 'pwd\neza', '```zsh\npwd\neza\n```'):
            for provider in ('claude', 'codex'):
                with self.subTest(response=response, provider=provider):
                    if provider == 'claude':
                        kwargs = {'claude': success(response)}
                    else:
                        kwargs = {'claude': {'status': 1}, 'codex': {'output': response}}
                    self.assert_unchanged('empty or multiline', **kwargs)

    def test_fences_and_inline_ticks_are_normalized(self):
        for response in ('```zsh\npwd\n```', '`pwd`', ' \r\npwd\r\n '):
            with self.subTest(response=response):
                self.assertEqual(self.run_widget(claude=success(response)), ('pwd', ''))

    def test_passthrough_buffers(self):
        for buffer in ('pwd', '#', '# ', '# comment\npwd', '#\tlist files'):
            with self.subTest(buffer=buffer):
                actual, _ = self.run_widget(buffer=buffer)
                self.assertEqual(actual, buffer)
                self.assertEqual((self.root / 'accepted').read_text(), '1')
                self.assertFalse((self.root / 'claude.args').exists())

    def test_quoting_models_and_provider_isolation(self):
        query = ('''--help "double" 'single' $(touch MARKER) `touch MARKER` \\ end'''
                 .replace('MARKER', str(self.root / 'NEVER')))
        command = "touch '" + str(self.root / 'NEVER') + "'"
        self.assertEqual(self.run_widget(claude={'status': 1}, codex={'output': command},
                                        buffer='# ' + query,
                                        ZSH_CLAUDE_COMMAND_MODEL='claude-test',
                                        ZSH_CLAUDE_COMMAND_CODEX_MODEL='codex-test',
                                        ZSH_CLAUDE_COMMAND_PROMPT_EXTEND='extra instructions'),
                         (command, ''))
        self.assertFalse((self.root / 'NEVER').exists())
        for provider, model in (('claude', 'claude-test'), ('codex', 'codex-test')):
            args = self.args(provider)
            self.assertEqual(args[-2:], ['--', query])
            self.assertEqual(args[args.index('--model') + 1], model)
        args = self.args('codex')
        for flag in ('--ephemeral', '--ignore-user-config', '--ignore-rules'):
            self.assertIn(flag, args)
        self.assertEqual(args[args.index('--sandbox') + 1], 'read-only')
        for setting in ('features.shell_tool=false', 'features.unified_exec=false',
                        'features.hooks=false', 'features.apps=false',
                        'approval_policy="never"', 'project_doc_max_bytes=0'):
            self.assertIn(setting, args)
        prompt = (self.root / 'codex.prompt').read_text()
        self.assertIn('extra instructions', prompt)
        self.assertIn('Current directory: ' + os.getcwd(), prompt)
        self.assertEqual((self.root / 'accepted').read_text(), '0')


if __name__ == '__main__':
    unittest.main(verbosity=2)
