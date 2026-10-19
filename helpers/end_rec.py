# end_record.py
import ctypes, json, subprocess, tempfile, time
from ctypes import wintypes
from pathlib import Path

PID_FILE = Path(tempfile.gettempdir()) / "screenrec_ffmpeg.pid"
META_FILE = Path(tempfile.gettempdir()) / "screenrec_meta.json"
ATTACH_PARENT_PROCESS = 0xFFFFFFFF


def _configure_kernel32():
    kernel32 = ctypes.windll.kernel32
    kernel32.FreeConsole.restype = wintypes.BOOL
    kernel32.AttachConsole.argtypes = [wintypes.DWORD]
    kernel32.AttachConsole.restype = wintypes.BOOL
    kernel32.SetConsoleCtrlHandler.argtypes = [ctypes.c_void_p, wintypes.BOOL]
    kernel32.SetConsoleCtrlHandler.restype = wintypes.BOOL
    kernel32.GenerateConsoleCtrlEvent.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel32.GenerateConsoleCtrlEvent.restype = wintypes.BOOL
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    kernel32.GetLastError.restype = wintypes.DWORD
    return kernel32


def _alive(kernel32, pid: int) -> bool:
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
    if not handle:
        return False
    kernel32.CloseHandle(handle)
    return True


def _reattach_parent(kernel32) -> None:
    kernel32.FreeConsole()
    kernel32.AttachConsole(ATTACH_PARENT_PROCESS)


def _stop_ffmpeg(pid: int) -> None:
    """Ctrl+Break on FFmpeg's own process group so the MP4 is finalized.

    FFmpeg is in its own group, so Ctrl+C from the unelevated winget task does
    not reach it. Ctrl+Break still does, and only if it is aimed at that group.
    """
    kernel32 = _configure_kernel32()
    kernel32.FreeConsole()
    if not kernel32.AttachConsole(int(pid)):
        err = kernel32.GetLastError()
        _reattach_parent(kernel32)
        print(f"AttachConsole failed (error {err}). Falling back to terminate...")
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], check=False)
        return

    kernel32.SetConsoleCtrlHandler(None, True)
    CTRL_BREAK_EVENT = 1
    # The process-group id is FFmpeg's pid (CREATE_NEW_PROCESS_GROUP).
    if not kernel32.GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, int(pid)):
        err = kernel32.GetLastError()
        _reattach_parent(kernel32)
        print(f"Ctrl+Break failed (error {err}). Falling back to terminate...")
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], check=False)
        return

    # Stay attached briefly so the event is delivered, then return to the parent.
    time.sleep(1)
    _reattach_parent(kernel32)

    deadline = time.time() + 8
    while time.time() < deadline and _alive(kernel32, pid):
        time.sleep(0.25)
    if _alive(kernel32, pid):
        print("FFmpeg did not exit after Ctrl+Break. Falling back to terminate...")
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], check=False)


def main():
    if not PID_FILE.exists():
        raise SystemExit("No active recording found (pid file missing).")

    pid = int(PID_FILE.read_text().strip())
    meta = {}
    if META_FILE.exists():
        try:
            meta = json.loads(META_FILE.read_text(encoding="utf-8"))
        except Exception:
            meta = {}

    started = meta.get("started")
    if not _alive(_configure_kernel32(), pid):
        print("WARNING: FFmpeg had already exited before the stop request; the recording ended early.")
        log = meta.get("log")
        if log and Path(log).exists():
            ended = Path(log).stat().st_mtime
            if started:
                print(f"FFmpeg stopped {ended - started:.0f}s after the recording started "
                      f"({time.time() - ended:.0f}s ago).")
            tail = Path(log).read_text(encoding="utf-8", errors="replace").splitlines()[-3:]
            for line in tail:
                print(f"  ffmpeg: {line.strip()}")
    else:
        _stop_ffmpeg(pid)

    if PID_FILE.exists():
        PID_FILE.unlink(missing_ok=True)

    out = meta.get("out", "<unknown file>")
    print(f"Recording stopped. File saved to:\n{out}")

    if META_FILE.exists():
        META_FILE.unlink(missing_ok=True)

if __name__ == "__main__":
    main()
