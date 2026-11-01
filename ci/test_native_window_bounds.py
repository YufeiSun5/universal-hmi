"""Window-bound arithmetic and wiring contracts, not native mouse/DPI tests."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LINUX = ROOT / 'app/linux/runner/my_application.cc'
MACOS = ROOT / 'app/macos/Runner/MainFlutterWindow.swift'


class NativeWindowBounds(unittest.TestCase):
    def test_linux_compiles_real_bound_function(self):
        compiler = shutil.which('c++') or shutil.which('g++') or shutil.which('clang++')
        if not compiler:
            self.skipTest('No C++ compiler; native Linux build is a separate CI job')
        source = LINUX.read_text(encoding='utf-8')
        function = re.search(r'static int bounded_window_extent\([^}]+}', source).group(0)
        program = '#include <algorithm>\n#include <cassert>\n' + function + '''
int main() {
  // Server-side decoration is outside GTK window geometry.
  assert(bounded_window_extent(900, 1920, 16, 0) == 900);
  assert(bounded_window_extent(600, 1080, 38, 0) == 600);
  assert(bounded_window_extent(900, 800, 16, 0) == 784);
  assert(bounded_window_extent(600, 580, 38, 0) == 542);
  // Client titlebar is inside GTK geometry; reserve it above Flutter content.
  assert(bounded_window_extent(600, 1080, 0, 48) == 648);
  assert(bounded_window_extent(600, 580, 0, 48) == 580);
  assert(bounded_window_extent(600, 580, 12, 48) == 568);
  assert(bounded_window_extent(600, 540, 38, 0) == 502); // logical HiDPI dimensions
  assert(bounded_window_extent(600, 1, 38, 0) == 1);
}
'''
        with tempfile.TemporaryDirectory() as temp:
            cpp = Path(temp) / 'bounds.cc'
            exe = Path(temp) / 'bounds'
            cpp.write_text(program)
            subprocess.run([compiler, '-std=c++14', '-Wall', '-Wextra', '-Werror', str(cpp), '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True)

    @unittest.skipUnless(sys.platform == 'darwin', 'Cocoa arithmetic runs on macOS CI')
    def test_macos_compiles_real_bound_function(self):
        swift = shutil.which('swift')
        if not swift:
            self.skipTest('No Swift compiler; macOS CI executes this arithmetic test')
        source = MACOS.read_text(encoding='utf-8')
        function = re.search(r'func hmiMinimumContentSize\([^}]+}', source).group(0)
        program = 'import Cocoa\n' + function + '''
assert(hmiMinimumContentSize(available: NSSize(width: 1920, height: 1042)) == NSSize(width: 900, height: 600))
assert(hmiMinimumContentSize(available: NSSize(width: 800, height: 540)) == NSSize(width: 800, height: 540))
assert(hmiMinimumContentSize(available: NSSize(width: 960, height: 502)) == NSSize(width: 900, height: 502))
assert(hmiMinimumContentSize(available: NSSize(width: 0, height: 0)) == NSSize(width: 1, height: 1))
'''
        with tempfile.TemporaryDirectory() as temp:
            script = Path(temp) / 'bounds.swift'
            script.write_text(program)
            subprocess.run([swift, str(script)], check=True)

    def test_linux_tracks_workarea_without_fixed_size_or_resize_loop(self):
        source = LINUX.read_text(encoding='utf-8')
        self.assertIn('gdk_monitor_get_workarea(monitor, &work_area)', source)
        self.assertIn('gdk_display_get_monitor_at_window(display, native)', source)
        self.assertIn('gdk_window_get_frame_extents(native, &frame)', source)
        self.assertIn('gdk_window_get_geometry(native,', source)
        update = source.split('static void update_window_minimum', 1)[1].split('static void window_size_allocated', 1)[0]
        self.assertNotIn('gtk_widget_get_allocated_', update)
        self.assertIn('g_signal_connect_after(window, "size-allocate"', source)
        self.assertIn('allocation->height - gtk_widget_get_allocated_height(child)', source)
        self.assertIn('gtk_widget_get_preferred_height(titlebar,', source)
        self.assertIn('border_height + internal_height, 0)', source)
        self.assertIn('GDK_HINT_MIN_SIZE)', source)
        self.assertIn('"configure-event"', source)
        self.assertIn('"monitors-changed"', source)
        self.assertIn('"size-changed"', source)
        self.assertIn('== min_height)', source)
        self.assertNotIn('GDK_HINT_MAX_SIZE', source)
        self.assertNotIn('gtk_window_set_resizable', source)
        self.assertNotIn('gtk_window_resize(', source)

    def test_macos_uses_points_visible_content_and_preserves_flutter_delegate(self):
        source = MACOS.read_text(encoding='utf-8')
        self.assertIn('contentRect(forFrameRect: targetScreen.visibleFrame).size', source)
        self.assertIn('if contentMinSize != minimum', source)
        self.assertIn('NSWindow.didChangeScreenNotification', source)
        self.assertIn('NSApplication.didChangeScreenParametersNotification', source)
        self.assertEqual(source.count('[weak self]'), 2)
        self.assertIn('NotificationCenter.default.removeObserver', source)
        self.assertNotIn('delegate =', source)
        self.assertNotIn('contentMaxSize', source)
        self.assertNotIn('backingScaleFactor', source)
        self.assertIn('RegisterGeneratedPlugins(registry: flutterViewController)', source)


if __name__ == '__main__':
    unittest.main()
