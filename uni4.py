import os
import sys
import time
import re
import subprocess
from datetime import datetime
from typing import List, Tuple, Optional

from pywinauto import Desktop
from pywinauto.mouse import click as mouse_click

# Buttons we WANT to click, roughly in order of "progress uninstall"
# Regex patterns let this work across slightly different labels ("Next >", "Finish", etc.)
ACTION_PATTERNS: List[re.Pattern] = [
    re.compile(r"^\s*uninstall\s*$", re.IGNORECASE),
    re.compile(r"\bremove\b", re.IGNORECASE),
    re.compile(r"\bdelete\b", re.IGNORECASE),
    re.compile(r"^\s*next\b", re.IGNORECASE),
    re.compile(r"\bcontinue\b", re.IGNORECASE),
    re.compile(r"\bproceed\b", re.IGNORECASE),
    re.compile(r"^\s*yes\s*$", re.IGNORECASE),
    re.compile(r"^\s*ok\s*$", re.IGNORECASE),
    re.compile(r"\bagree\b", re.IGNORECASE),
    re.compile(r"\baccept\b", re.IGNORECASE),
    re.compile(r"\bfinish\b", re.IGNORECASE),
    re.compile(r"^\s*close\s*$", re.IGNORECASE),
    re.compile(r"\bdone\b", re.IGNORECASE),
    re.compile(r"\bexit\b", re.IGNORECASE),
    # Optional “skip upsell/survey” patterns (kept late so we prefer actual uninstall progress)
    re.compile(r"\bskip\b", re.IGNORECASE),
    re.compile(r"\bno thanks\b", re.IGNORECASE),
    re.compile(r"\bnot now\b", re.IGNORECASE),
    re.compile(r"\bdecline\b", re.IGNORECASE),
]

# Buttons we should NOT click (common “stop” or unrelated controls)
IGNORE_EXACT = {
    "Cancel", "Back",
    "Minimize", "Maximize", "Close",  # system buttons often appear as Button controls in UIA
    "Help",
    "Take the survey",  # common in some uninstallers; keep it ignored
}

IGNORE_TITLE_RE = re.compile(
    r"(windows terminal|terminal|powershell|command prompt|cmd\.exe|microsoft store|microsoft edge|vscode|cursor)",
    re.IGNORECASE
)

_LOG_PATH = None


def _setup_log() -> str:
    """Create logs/uninstall/<YYYY-MM-DD>.log next to this script (repo root)."""
    global _LOG_PATH
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs", "uninstall")
    os.makedirs(log_dir, exist_ok=True)
    date_str = datetime.now().strftime("%Y-%m-%d")
    _LOG_PATH = os.path.join(log_dir, f"{date_str}.log")
    return _LOG_PATH


def log(msg: str) -> None:
    """Write progress to the terminal and append it to the daily uninstall log."""
    print(msg)
    if _LOG_PATH:
        with open(_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(msg + "\n")


def _fmt_elapsed(seconds: float) -> str:
    total = int(round(seconds))
    mm, ss = divmod(max(total, 0), 60)
    return f"{mm:02d}:{ss:02d}"


def _center(rect) -> Tuple[int, int]:
    return (int((rect.left + rect.right) / 2), int((rect.top + rect.bottom) / 2))

def _click_physically(ctrl_wrap) -> bool:
    try:
        r = ctrl_wrap.rectangle()
        x, y = _center(r)
        mouse_click(coords=(x, y))
        return True
    except Exception:
        return False

def _try_click(win_wrap, btn_wrap, label: str, backend: str) -> bool:
    # Try not to fight focus, but some apps need focus for click_input / keyboard
    try:
        win_wrap.set_focus()
    except Exception:
        pass

    # 1) invoke (best for UIA)
    try:
        btn_wrap.invoke()
        log(f"  -> [{backend}] invoke '{label}'")
        return True
    except Exception:
        pass

    # 2) click_input
    try:
        btn_wrap.click_input()
        log(f"  -> [{backend}] click_input '{label}'")
        return True
    except Exception:
        pass

    # 3) physical click by rectangle center
    if _click_physically(btn_wrap):
        log(f"  -> [{backend}] physical click '{label}'")
        return True

    return False

def _enumerate_buttons(win_wrap) -> List[Tuple[str, object, bool]]:
    """Return candidate buttons: (name, wrapper, enabled)."""
    out = []
    try:
        elems = win_wrap.descendants(control_type="Button")
    except Exception:
        return out

    for e in elems:
        try:
            name = (e.window_text() or "").strip()
            if not name:
                continue
            if name in IGNORE_EXACT:
                continue

            bw = e.wrapper_object()
            try:
                enabled = bw.is_enabled()
            except Exception:
                enabled = True

            out.append((name, bw, enabled))
        except Exception:
            continue

    # de-dup by name (keep first)
    seen = set()
    uniq = []
    for n, w, en in out:
        key = n.lower()
        if key not in seen:
            seen.add(key)
            uniq.append((n, w, en))
    return uniq

def _pick_best_button(buttons: List[Tuple[str, object, bool]]) -> Optional[Tuple[str, object, bool]]:
    # Prefer enabled buttons first, and earliest match in ACTION_PATTERNS
    for pat in ACTION_PATTERNS:
        for (name, bw, enabled) in buttons:
            if enabled and pat.search(name):
                return (name, bw, enabled)

    # If none enabled match, try disabled anyway (some UIs misreport)
    for pat in ACTION_PATTERNS:
        for (name, bw, enabled) in buttons:
            if pat.search(name):
                return (name, bw, enabled)

    return None

def _keyboard_fallback(win_wrap) -> bool:
    try:
        win_wrap.set_focus()

        # 1) Try ENTER (often clicks Next/OK/Uninstall if it's the default)
        win_wrap.type_keys("{ENTER}")
        log("  -> [kbd] ENTER fallback")
        time.sleep(0.2)

        # 2) Try Alt+N (wizard Next accelerator)
        win_wrap.type_keys("%n")
        log("  -> [kbd] Alt+N fallback")
        time.sleep(0.2)

        # 3) LAST resort: limited tabbing (much smaller than 8)
        for _ in range(2):
            win_wrap.type_keys("{TAB}")
            time.sleep(0.05)
        win_wrap.type_keys("{ENTER}")
        log("  -> [kbd] TAB x2 + ENTER last resort")
        return True
    except Exception:
        return False


def _get_top_windows(backend: str):
    return Desktop(backend=backend).windows(visible_only=True)

def _reconnect_by_handle(backend: str, handle: int):
    # Avoid stale elements by re-acquiring each loop
    return Desktop(backend=backend).window(handle=handle).wrapper_object()

def _is_noise_window(title: str) -> bool:
    return bool(IGNORE_TITLE_RE.search(title or ""))

def run_winget_uninstall(package_id: str):
    # some apps have same package ID https://github.com/microsoft/winget-cli/issues/4312
    cmd = ["winget", "uninstall", "--id", package_id, "--silent", "--disable-interactivity", "--accept-source-agreements", "--all-versions"]
    CREATE_NO_WINDOW = 0x08000000
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=CREATE_NO_WINDOW)

def drive_uninstall_ui(timeout_s: int = 30, no_dialog_grace_s:int = 5):
    """
    Watches for dialog windows and clicks the best uninstall-progress button.
    Stops if no progress for a while.
    """
    start = time.time()
    last_progress = None
    first_dialog_seen_at = None

    while time.time() - start < timeout_s:
        progressed = False
        any_dialog_seen = False

        # Try UIA first (best for modern apps), then Win32
        for backend in ("uia", "win32"):
            try:
                wins = _get_top_windows(backend)
            except Exception:
                continue

            for w in wins:
                try:
                    title = (w.window_text() or "").strip()
                    if not title or _is_noise_window(title):
                        continue

                    # Reconnect to avoid stale UIA trees
                    win = _reconnect_by_handle(backend, w.handle)

                    # Only act on dialogs/windows that look like an installer/uninstaller.
                    # Heuristic: has actionable buttons OR common keywords in title.
                    title_l = title.lower()
                    looks_related = any(k in title_l for k in ("uninstall", "setup", "install", "remove", "wizard")) or True

                    any_dialog_seen = True
                    if first_dialog_seen_at is None:
                        first_dialog_seen_at = time.time()

                    if not looks_related:
                        continue

                    # Give time for controls to materialize
                    try:
                        win.wait("ready", timeout=1.5)
                    except Exception:
                        pass

                    buttons = _enumerate_buttons(win)
                    choice = _pick_best_button(buttons)

                    # If we see nothing, try keyboard fallback once
                    if choice is None and not buttons:
                        # avoid spamming keyboard on every random window:
                        # only do fallback if title hints it's a wizard/uninstall-ish window
                        if any(k in title_l for k in ("uninstall", "setup", "wizard", "install", "remove")):
                            log(f"[target] ({backend}) {title}")
                            if _keyboard_fallback(win):
                                progressed = True
                                last_progress = time.time()
                                time.sleep(0.8)
                                break
                        continue

                    if choice:
                        name, bw, en = choice
                        log(f"[target] ({backend}) {title}")
                        if _try_click(win, bw, name, backend):
                            progressed = True
                            last_progress = time.time()
                            time.sleep(0.8)
                            break

                except Exception:
                    continue

            if progressed:
                break

        if not any_dialog_seen and first_dialog_seen_at is None:
            if (time.time() - start) > no_dialog_grace_s:
                log(f"[done] no dialogs appeared within {no_dialog_grace_s}s.")
                return
                
        if not progressed:
            if last_progress and (time.time() - last_progress) > 12:
                log("[done] no further progress detected.")
                return
            time.sleep(0.4)

    log("[timeout] reached UI automation timeout.")

def main():
    if len(sys.argv) != 2:
        print("Usage: python uninstall.py <winget_id>")
        sys.exit(2)

    pkg_id = sys.argv[1]
    log_path = _setup_log()
    start_time = time.time()

    log(f"package: {pkg_id}")

    # 1) wait 2 seconds
    time.sleep(2)

    # Start uninstall (2) then automate UI (3)
    log(f"[run] winget uninstall --id {pkg_id}")
    run_winget_uninstall(pkg_id)
    log(f"Done running winget uninstall --id {pkg_id}")

    # give uninstaller time to spawn UI
    time.sleep(2)

    drive_uninstall_ui(timeout_s=5)

    elapsed = _fmt_elapsed(time.time() - start_time)
    log(f"Uninstallation on {pkg_id} took {elapsed}")

if __name__ == "__main__":
    main()
