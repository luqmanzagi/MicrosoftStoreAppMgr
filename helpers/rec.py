# record.py
import argparse, ctypes, datetime as dt, json, os, shutil, subprocess, tempfile, time
from pathlib import Path
from ctypes import wintypes

FFMPEG = "ffmpeg"  # or r"C:\ffmpeg\bin\ffmpeg.exe"
PID_FILE = Path(tempfile.gettempdir()) / "screenrec_ffmpeg.pid"
META_FILE = Path(tempfile.gettempdir()) / "screenrec_meta.json"
LOG_DIR = Path(tempfile.gettempdir()) / "screenrec_logs"
# Uninstallers (CapCut, ...) close every "ffmpeg.exe" by name while removing
# their bundled copy, which ended the recording mid-uninstall.
RECORDER_EXE = Path(tempfile.gettempdir()) / "screenrec" / "screenrec-recorder.exe"


def recorder_exe() -> str:
    src = shutil.which(FFMPEG) or FFMPEG
    if not os.path.isfile(src):
        return src
    RECORDER_EXE.parent.mkdir(parents=True, exist_ok=True)
    try:
        if RECORDER_EXE.exists() and os.path.samefile(src, RECORDER_EXE):
            return str(RECORDER_EXE)
        st_src, st_dst = os.stat(src), (RECORDER_EXE.stat() if RECORDER_EXE.exists() else None)
        if st_dst and st_dst.st_size == st_src.st_size and st_dst.st_mtime >= st_src.st_mtime:
            return str(RECORDER_EXE)
        RECORDER_EXE.unlink(missing_ok=True)
        try:
            os.link(src, RECORDER_EXE)
        except OSError:
            shutil.copy2(src, RECORDER_EXE)
        return str(RECORDER_EXE)
    except OSError as e:
        print(f"Could not create renamed recorder ({e}); using {src}")
        return src

def default_output():
    ts = dt.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    videos = Path.home() / "Videos"
    videos.mkdir(parents=True, exist_ok=True)
    return videos / f"screen_{ts}.mp4"

def main():
    ap = argparse.ArgumentParser(description="Start screen recording (Windows).")
    ap.add_argument("--out", type=Path, default=default_output(),
                    help="Output MP4 file path (default: ~/Videos/screen_YYYY-mm-dd_HH-MM-SS.mp4)")
    ap.add_argument("--fps", type=int, default=30, help="Frame rate (default: 30)")
    ap.add_argument("--cursor", action="store_true", help="Show cursor (for gdigrab only)")
    ap.add_argument("--grab", choices=["ddagrab","gdigrab"], default="ddagrab",
                    help="Windows screen grabber (default: ddagrab; use gdigrab for older Windows)")
    args = ap.parse_args()

    if PID_FILE.exists():
        raise SystemExit(f"Recording already in progress (pid file exists at {PID_FILE}). "
                         f"Run end_record.py first.")

    # Build FFmpeg input(s)
    # Video (whole desktop)
    if args.grab == "ddagrab":
        video_in = ["-f","ddagrab","-framerate",str(args.fps),"-i","desktop"]
    else:
        # gdigrab supports cursor toggle
        video_in = ["-f","gdigrab","-framerate",str(args.fps),"-i","desktop"]
        if args.cursor:
            video_in = ["-f","gdigrab","-framerate",str(args.fps),"-draw_mouse","1","-i","desktop"]

    # Output settings: H.264, faststart for web playback.
    # Leave stdin on the new console. FFmpeg only installs its quit handler
    # (Ctrl+C / "q") when stdin is a console, so do not redirect it or pass -nostdin.
    out = str(args.out)
    cmd = [
        recorder_exe(), "-y",
        *video_in,
        "-pix_fmt","yuv420p",
        "-c:v","libx264","-preset","veryfast","-crf","23",
        "-movflags","+faststart",
        out
    ]

    # Own console and process group. The unelevated winget scheduled task
    # signals the PowerShell process group; FFmpeg used to be in that group,
    # so the recording died on "Using winget ... [unelevated]".
    # Ctrl+C is disabled for this group. end_rec.py sends Ctrl+Break instead.
    creationflags = subprocess.CREATE_NEW_CONSOLE | subprocess.CREATE_NEW_PROCESS_GROUP
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / f"{Path(out).stem}.log"
    err_log = open(log_path, "w", encoding="utf-8", errors="replace")
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=err_log,
        creationflags=creationflags,
    )
    err_log.close()

    # Persist pid + meta so end_record.py can stop it and report
    PID_FILE.write_text(str(proc.pid), encoding="utf-8")
    META_FILE.write_text(json.dumps({"out": out, "log": str(log_path), "started": time.time(), "grab": args.grab}, ensure_ascii=False))

    print(f"\n**************************************************")
    print(f"Recording started (PID {proc.pid}). Writing to:\n{out}\n"
          f"To stop: python end_record.py", flush=True)
    print(f"**************************************************\n")
    hide_ffmpeg_console(proc.pid)


def hide_ffmpeg_console(pid: int) -> None:
    """Hide the extra console window FFmpeg needs in order to take Ctrl+C."""
    kernel32 = ctypes.windll.kernel32
    user32 = ctypes.windll.user32
    kernel32.FreeConsole.restype = wintypes.BOOL
    kernel32.AttachConsole.argtypes = [wintypes.DWORD]
    kernel32.AttachConsole.restype = wintypes.BOOL
    kernel32.GetConsoleWindow.restype = wintypes.HWND
    user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
    user32.ShowWindow.restype = wintypes.BOOL

    kernel32.FreeConsole()
    attached = False
    for _ in range(25):
        if kernel32.AttachConsole(int(pid)):
            attached = True
            break
        time.sleep(0.1)
    if attached:
        hwnd = kernel32.GetConsoleWindow()
        if hwnd:
            user32.ShowWindow(hwnd, 0)  # SW_HIDE
        kernel32.FreeConsole()
    kernel32.AttachConsole(0xFFFFFFFF)  # ATTACH_PARENT_PROCESS

if __name__ == "__main__":
    main()
