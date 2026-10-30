"""Isolated Windows desktop single-instance smoke; does not exercise tray exit.

Run against a freshly built release and a disposable loopback API fixture:
  python ci/windows_desktop_lifecycle_smoke.py --exe C:\\...\\universal_hmi.exe --api http://127.0.0.1:PORT/
The fixture must be disposable. No production project or database is opened.
All terminated processes are launched by this script. Forced termination is used
only for the crash-recovery scenario and final fixture cleanup, not as evidence
of normal exit. Tray-menu and Alt+F4 interactions require separate UI review.
"""
import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

if sys.platform != 'win32':
    raise SystemExit('Windows only')
user = ctypes.WinDLL('user32', use_last_error=True)
WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user.EnumWindows.argtypes = (WNDENUMPROC, wintypes.LPARAM)
user.GetWindowThreadProcessId.argtypes = (wintypes.HWND, ctypes.POINTER(wintypes.DWORD))
user.IsWindowVisible.argtypes = (wintypes.HWND,)
user.IsIconic.argtypes = (wintypes.HWND,)
user.GetClassNameW.argtypes = (wintypes.HWND, wintypes.LPWSTR, ctypes.c_int)
user.PostMessageW.argtypes = (wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM)
user.ShowWindow.argtypes = (wintypes.HWND, ctypes.c_int)


def windows(pid, visible=None):
    found = []
    @WNDENUMPROC
    def visit(hwnd, _):
        owner = wintypes.DWORD()
        user.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        window_class = ctypes.create_unicode_buffer(256)
        user.GetClassNameW(hwnd, window_class, len(window_class))
        if owner.value == pid and window_class.value == 'FLUTTER_RUNNER_WIN32_WINDOW' and (visible is None or bool(user.IsWindowVisible(hwnd)) == visible):
            found.append(hwnd)
        return True
    if not user.EnumWindows(visit, 0):
        raise ctypes.WinError(ctypes.get_last_error())
    return found


def wait(predicate, description, timeout=30):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = predicate()
        if value:
            return value
        time.sleep(.1)
    raise AssertionError('Timeout: ' + description)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--exe', required=True, type=Path)
    parser.add_argument('--api', required=True, help='disposable loopback HTTP fixture')
    parser.add_argument('--data-root', type=Path, help='existing directory for a new temporary isolated project fixture')
    args = parser.parse_args()
    url = urlsplit(args.api)
    if url.scheme != 'http' or url.hostname not in ('127.0.0.1', 'localhost', '::1') or url.username or url.password:
        parser.error('--api must be an unauthenticated loopback HTTP fixture')
    exe = args.exe.resolve(strict=True)
    spawned = []
    if args.data_root is not None and not args.data_root.is_dir():
        parser.error('--data-root must be an existing directory')
    with tempfile.TemporaryDirectory(prefix='hmi-desktop-smoke-', dir=args.data_root) as root:
        root = Path(root)
        def launch(project, view):
            project.mkdir(exist_ok=True)
            env = os.environ.copy()
            env['HMI_PROJECT_DIR'] = str(project.resolve())
            env['HMI_DATA_DIR'] = str(project.resolve())
            env['HMI_API_BASE_URL'] = args.api
            process = subprocess.Popen([str(exe), '--view='+view], cwd=exe.parent, env=env)
            spawned.append(process)
            return process
        def window_for(process):
            return wait(lambda: windows(process.pid, True), 'visible owner window')[0]
        def duplicate_exits(process):
            code = process.wait(timeout=30)
            if code != 0:
                raise AssertionError('duplicate returned nonzero: '+str(code))
        try:
            a, b = root/'project-a', root/'project-b'
            # Start both before waiting, so the first-frame race is exercised.
            contenders = [launch(a, 'runtime'), launch(a, 'runtime')]
            runtime = wait(lambda: next((p for p in contenders if p.poll() is None and windows(p.pid, True)), None), 'concurrent owner window')
            runtime_window = window_for(runtime)
            duplicate_exits(next(p for p in contenders if p is not runtime))
            assert runtime.poll() is None and windows(runtime.pid, True)
            dup = launch(a, 'runtime')
            duplicate_exits(dup)
            developer = launch(a, 'developer')
            window_for(developer)
            other = launch(b, 'runtime')
            window_for(other)
            # Standard minimize preserves a taskbar window; re-launch must restore it.
            user.ShowWindow(runtime_window, 6)  # SW_MINIMIZE
            dup = launch(a, 'runtime')
            duplicate_exits(dup)
            wait(lambda: user.IsWindowVisible(runtime_window) and not user.IsIconic(runtime_window), 'restore minimized owner')
            # Standard close request tests the default hide-to-tray behavior.
            if not user.PostMessageW(runtime_window, 0x0010, 0, 0):  # WM_CLOSE
                raise ctypes.WinError(ctypes.get_last_error())
            wait(lambda: runtime.poll() is None and not user.IsWindowVisible(runtime_window), 'hide on close')
            dup = launch(a, 'runtime')
            duplicate_exits(dup)
            wait(lambda: user.IsWindowVisible(runtime_window), 'restore hidden owner')
            # Crash scenario is explicitly distinct from graceful tray exit.
            runtime.kill()
            runtime.wait(timeout=10)
            recovered = launch(a, 'runtime')
            window_for(recovered)
            print(json.dumps({'concurrent_and_sequential_duplicates':'passed', 'roles_coexist':'passed',
                              'projects_independent':'passed', 'minimized_restore':'passed',
                              'close_hides_and_reopens':'passed', 'crash_recovery':'passed',
                              'tray_menu_normal_exit':'not tested', 'cleanup':'forced fixture processes only'}, indent=2))
        finally:
            for process in spawned:
                if process.poll() is None:
                    process.kill()
            for process in spawned:
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    pass


if __name__ == '__main__':
    main()
