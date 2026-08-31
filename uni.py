import re
import time
import subprocess
from pywinauto import Desktop
from pywinauto.timings import TimeoutError

# Buttons we try to click, in priority order.
# Add/remove labels as needed for your environment/language.
BUTTON_PATTERNS_PRIORITY = [
    r"uninstall", r"remove", r"delete",
    r"next", r"continue",
    r"yes", r"ok", r"agree", r"accept",
    r"finish", r"close", r"done",
]

# Optional: ignore windows that are obviously unrelated
IGNORE_TITLE_PATTERNS = [
    r"microsoft store",
    r"windows powershell",
]

def _matches_any(patterns, text: str) -> bool:
    t = (text or "").strip().lower()
    return any(re.search(p, t, re.IGNORECASE) for p in patterns)

def _enum_top_windows():
    # UI Automation backend is best for modern installers/uninstallers.
    return Desktop(backend="uia").windows()

def click_uninstallish_buttons(timeout_s=120, poll_interval=0.3, verbose=True):
    """
    Watches for popup windows and clicks the first matching button by priority.
    Returns when no more clicks happen for a while OR timeout is reached.
    """
    start = time.time()
    seen = set()
    last_click_time = 0

    while time.time() - start < timeout_s:
        try:
            wins = _enum_top_windows()
        except Exception:
            time.sleep(poll_interval)
            continue

        did_click = False

        for w in wins:
            try:
                title = (w.window_text() or "").strip()
                if _matches_any(IGNORE_TITLE_PATTERNS, title):
                    continue

                # Identify window reliably
                win_key = (title, w.element_info.control_type, w.element_info.handle)
                if win_key not in seen:
                    seen.add(win_key)
                    if verbose and title:
                        print(f"[window] {title}")

                # Skip minimized/invisible windows
                if not w.is_visible():
                    continue

                # Gather buttons (UIA)
                buttons = w.descendants(control_type="Button")
                if not buttons:
                    continue

                # Try buttons in priority order
                for pat in BUTTON_PATTERNS_PRIORITY:
                    for b in buttons:
                        name = (b.window_text() or "").strip()
                        if not name:
                            continue
                        if re.search(pat, name, re.IGNORECASE):
                            try:
                                # Bring dialog front and click
                                w.set_focus()
                                # Some buttons are wrappers; use invoke if possible
                                b_wrapper = b.wrapper_object()
                                if verbose:
                                    print(f"  -> clicking '{name}' in '{title}'")
                                try:
                                    b_wrapper.invoke()
                                except Exception:
                                    b_wrapper.click_input()
                                did_click = True
                                last_click_time = time.time()
                                break
                            except Exception:
                                # If click fails, keep searching
                                continue
                    if did_click:
                        break

            except Exception:
                continue

        # Exit condition: if we haven't clicked anything for a while, assume done
        if did_click:
            time.sleep(0.6)  # give the UI time to advance
        else:
            # If we've clicked in the past and now nothing appears for a bit, stop.
            if last_click_time and (time.time() - last_click_time) > 4:
                if verbose:
                    print("[done] no more dialogs detected.")
                return
            time.sleep(poll_interval)

    if verbose:
        print("[timeout] reached automation timeout.")

def main():
    """
    Example usage:
      python auto_uninstall_clicker.py --winget-id XPFCWP0SQWXM3V
    Or just run it and it will only click popups (useful if you trigger uninstall elsewhere).
    """
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--winget-id", help="Winget package id to uninstall")
    p.add_argument("--timeout", type=int, default=180)
    args = p.parse_args()

    # 1) wait 2 seconds (per your requirement)
    time.sleep(2)

    # If requested, start winget uninstall first
    if args.winget_id:
        cmd = [
            "winget", "uninstall",
            "--id", args.winget_id,
            "--silent", "--disable-interactivity",
        ]
        print("[run]", " ".join(cmd))
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # give uninstall process time to spawn UI
        time.sleep(2)

    # 2) check whether popup appears + 3) click through
    click_uninstallish_buttons(timeout_s=args.timeout, verbose=True)

if __name__ == "__main__":
    main()
