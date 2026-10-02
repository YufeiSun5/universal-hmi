import tempfile
import subprocess
import unittest
from pathlib import Path
from unittest.mock import Mock
from package_smoke import child_backend_pid, wait_for_desktop_exit

class ProcessOwnership(unittest.TestCase):
    def test_ppid_lookup_without_optional_children_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / 'server'
            executable.write_text('fixture')
            for pid, parent in [(8, 123), (9, 999)]:
                entry = root / str(pid)
                entry.mkdir()
                (entry / 'status').write_text(f'Name:\tfixture\nPPid:\t{parent}\n')
                (entry / 'exe').symlink_to(executable)
            self.assertEqual(child_backend_pid(123, executable, root), 8)
            self.assertIsNone(child_backend_pid(456, executable, root))


class DesktopExitEvidence(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.log = Path(self.directory.name) / 'desktop.log'
        self.log.write_text('HMI lifecycle: engine disposed\nHMI lifecycle: application shutdown complete\n')
        self.process = Mock(pid=123)
        self.process.wait.return_value = 0
        self.evidence = {}

    def test_normal_exit_requires_engine_cleanup_before_shutdown(self):
        wait_for_desktop_exit(self.process, self.log, self.evidence, 'reused-1')
        outcome = self.evidence['desktop_exits'][0]
        self.assertEqual(outcome['exit_code'], 0)
        self.assertTrue(outcome['engine_disposed_before_shutdown'])

    def test_crash_exit_code_is_preserved_and_never_accepted(self):
        self.process.wait.return_value = -6
        with self.assertRaisesRegex(AssertionError, 'code -6'):
            wait_for_desktop_exit(self.process, self.log, self.evidence, 'reused-1')
        self.assertEqual(self.evidence['desktop_exits'][0]['exit_code'], -6)

    def test_zero_exit_without_engine_cleanup_is_not_a_lifecycle_pass(self):
        self.log.write_text('HMI lifecycle: application shutdown complete\nHMI lifecycle: engine disposed\n')
        with self.assertRaisesRegex(AssertionError, 'engine outlived'):
            wait_for_desktop_exit(self.process, self.log, self.evidence, 'reused-1')
        self.assertFalse(self.evidence['desktop_exits'][0]['engine_disposed_before_shutdown'])

    def test_shutdown_timeout_is_preserved(self):
        self.process.wait.side_effect = subprocess.TimeoutExpired('desktop', 15)
        with self.assertRaisesRegex(AssertionError, 'did not close'):
            wait_for_desktop_exit(self.process, self.log, self.evidence, 'reused-1')
        self.assertTrue(self.evidence['desktop_exits'][0]['timed_out'])


if __name__ == '__main__':
    unittest.main()
