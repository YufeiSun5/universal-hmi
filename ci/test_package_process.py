import tempfile
import unittest
from pathlib import Path
from package_smoke import child_backend_pid

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

if __name__ == '__main__':
    unittest.main()
