#!/usr/bin/env python3
"""Exercise the boot recovery without a Docker daemon or mounted data disk."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


MOCK = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
scenario = os.environ['SCENARIO']
if command == 'mountpoint':
    sys.exit(1 if scenario == 'unmounted' else 0)
if command == 'stat':
    print('1' if args[-1] == '/' or scenario == 'root-disk' else '2')
    sys.exit(0)
if command == 'sleep':
    sys.exit(0)
if command != 'docker':
    sys.exit(2)
with open(os.environ['EVENTS'], 'a') as events:
    events.write(' '.join(args) + '\n')
if args[0] == 'start':
    sys.exit(0)
container = args[-1]
if scenario == 'missing' and container == 'skin-trader-compute':
    sys.exit(1)
template = args[2]
if 'com.docker.compose.project' in template:
    print('other' if scenario == 'other-project' else 'skin-trader')
elif '.Mounts' in template:
    if scenario == 'wrong-mount' and container == 'skin-trader-api':
        print('bind:/tmp/postgres:false')
    else:
        print('bind:' + os.environ['DATA'] + ':' + ('true' if container == 'skin-trader-postgres' else 'false'))
elif '.State.Status' in template:
    counter = Path(os.environ['COUNTER'])
    count = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(count + 1))
    print('running healthy' if scenario != 'recovering' or count >= 2 else 'running starting')
else:
    sys.exit(2)
'''


class StartupTests(unittest.TestCase):
    def run_startup(self, scenario):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            disk = directory / 'disk'
            data = disk / 'skin-trader/postgres'
            (data / 'global').mkdir(parents=True)
            (data / 'PG_VERSION').write_text('16' if scenario == 'wrong-version' else '17')
            if scenario != 'missing-cluster':
                (data / 'global/pg_control').write_bytes(b'' if scenario == 'empty-cluster' else b'control')
            script = directory / 'startup.sh'
            source = Path(__file__).with_name('skin-trader-startup.sh').read_text()
            script.write_text(source.replace('disk=/mnt/media3', 'disk=' + str(disk)))
            for command in ('docker', 'mountpoint', 'stat', 'sleep'):
                executable = directory / command
                executable.write_text(MOCK)
                executable.chmod(0o755)
            events = directory / 'events'
            environment = os.environ | {
                'PATH': str(directory) + os.pathsep + os.environ['PATH'],
                'SCENARIO': scenario,
                'EVENTS': str(events),
                'COUNTER': str(directory / 'counter'),
                'DATA': str(data),
            }
            result = subprocess.run(
                ['bash', str(script)],
                env=environment, text=True, capture_output=True, check=False,
            )
            return result, events.read_text() if events.exists() else ''

    def test_invalid_storage_fails_before_docker(self):
        for scenario in ('unmounted', 'root-disk', 'missing-cluster', 'empty-cluster', 'wrong-version'):
            with self.subTest(scenario=scenario):
                result, events = self.run_startup(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, '')

    def test_invalid_containers_fail_before_start(self):
        for scenario in ('missing', 'other-project', 'wrong-mount'):
            with self.subTest(scenario=scenario):
                result, events = self.run_startup(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('start skin-trader', events)

    def test_recovery_gates_workers_without_restarting_postgres(self):
        result, events = self.run_startup('recovering')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events.count('start skin-trader-postgres\n'), 1)
        self.assertEqual(events.count('.State.Status'), 3)
        self.assertGreater(events.index('start skin-trader-api'), events.rindex('.State.Status'))

    def test_already_healthy_is_idempotent(self):
        for _ in range(2):
            result, events = self.run_startup('healthy')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('stop ', events)
            self.assertNotIn('create ', events)
            self.assertNotIn('rm ', events)


if __name__ == '__main__':
    unittest.main()
