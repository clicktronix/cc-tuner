#!/usr/bin/env python3
"""Pause real owner publication and check readers and the independent workload lock."""
import builtins
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

HEAVY = Path(__file__).resolve().parents[2] / 'scripts/heavy.sh'


def wait_for(path, process=None):
    end = time.monotonic() + 5
    while not path.exists():
        if time.monotonic() >= end or (process and process.poll() is not None):
            raise AssertionError('did not reach ' + str(path))
        time.sleep(0.01)


def worker(script, mode, directory):
    program = script.read_text().split("<<'PY' || true\n", 1)[1].split('\nPY\n', 1)[0]
    paused = False
    real_flock = fcntl.flock

    def observed_open(file, access='r', *args, **kwargs):
        nonlocal paused
        opened = builtins.open(file, access, *args, **kwargs)
        if mode == 'run' and access == 'w' and not paused:
            paused = True
            (directory / 'writing').touch()
            wait_for(directory / 'publish')
        return opened

    def observed_flock(fd, operation):
        if mode == 'status':
            (directory / 'reading').touch()
        return real_flock(fd, operation)

    fcntl.flock = observed_flock
    command = [sys.executable, '-c',
               'import pathlib,time,sys; p=pathlib.Path(sys.argv[1]); '
               'end=time.monotonic()+10; '
               'exec("while not p.exists() and time.monotonic()<end: time.sleep(0.01)")',
               str(directory / 'finish')]
    sys.argv = ['heavy', mode, str(directory), '1', '1', '0.01', 'new-holder', *command]
    exec(compile(program, str(script), 'exec'), {'open': observed_open, '__name__': '__main__'})


class OwnerPublication(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.directory = Path(self.tmp.name)
        self.processes = []

    def tearDown(self):
        (self.directory / 'publish').touch()
        (self.directory / 'finish').touch()
        for process in self.processes:
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.communicate(timeout=5)
        self.tmp.cleanup()

    def start(self, mode):
        process = subprocess.Popen([sys.executable, __file__, 'worker', str(HEAVY), mode,
                                    str(self.directory)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(process)
        return process

    def assert_locked(self):
        with open(self.directory / 'slot-1.lock', 'r') as lock:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_atomic_owner_replacement(self):
        owner = self.directory / 'slot-1.owner'
        owner.write_text('previous-holder\n')
        self.start('run')
        wait_for(self.directory / 'writing', self.processes[0])
        self.assert_locked()
        self.assertEqual(owner.read_text(), 'previous-holder\n', 'readers must never see a truncated owner')

    def check_publication(self, previous):
        if previous:
            (self.directory / 'slot-1.owner').write_text('previous-holder\n')
        self.start('run')
        wait_for(self.directory / 'writing', self.processes[0])
        self.assert_locked()
        reader = self.start('status')
        wait_for(self.directory / 'reading', reader)
        with self.assertRaises(subprocess.TimeoutExpired, msg='status must wait for publication, not return an unknown or stale owner'):
            reader.communicate(timeout=0.2)
        (self.directory / 'publish').touch()
        output, error = reader.communicate(timeout=5)
        self.assertEqual(reader.returncode, 0, error)
        self.assertIn('new-holder', output)
        self.assertNotIn('unknown holder', output)
        self.assertNotIn('previous-holder', output)
        self.assert_locked()

    def test_first_publication(self):
        self.check_publication(previous=False)

    def test_previous_owner_is_not_reused(self):
        self.check_publication(previous=True)

    def test_exit_during_publication_releases_both_locks(self):
        writer = self.start('run')
        wait_for(self.directory / 'writing', writer)
        reader = self.start('status')
        wait_for(self.directory / 'reading', reader)
        writer.terminate()
        writer.communicate(timeout=5)
        output, error = reader.communicate(timeout=5)
        self.assertEqual(reader.returncode, 0, error)
        self.assertIn('all slots free', output)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'worker':
        worker(Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]))
    else:
        unittest.main()
