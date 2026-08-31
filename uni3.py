import time
import re
import subprocess
from pywinauto import Desktop
from pywinauto.mouse import click as mouse_click

TITLE_RE = re.compile(r"ccleaner.*uninstall", re.IGNORECASE)

# Buttons that typically advance uninstall
ACTION_RE = re.compile(r"^(uninstall|next|yes|ok|finish|close|done)\b", re.IGNORECASE)

# Buttons that should NOT be clicked
IGNORE_NAMES = {
    "Cancel", "Back", "Minimize", "Maximize", "Close", "Take the survey"
}

def start_winget_uninstall():
    CREATE_NO_WINDOW = 0x08000000
    subprocess.Popen(
        ["winget", "uninstall", "--id", "XPFCWP0SQWXM3V", "--silent", "--disable-interactivity"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=CREATE_NO_WINDOW,
    )

def center(rect):
    return (int((rect.left + rect.right) / 2), int((rect.top + rect.bottom) / 2))

def click_button_wrapper(win_wrap, btn_wrap, name: str):
    # Avoid focus fights: focus once, then click
    try:
        win_wrap.set_focus()
    except Exception:
        pass

    # 1) invoke (UIA)
    try:
        btn_wrap.invoke()
        print(f"  -> invoke '{name}'")
        return True
    except Exception:
        pass

    # 2) click_input
    try:
        btn_wrap.click_input()
        print(f"  -> click_input '{name}'")
        return True
    except Exception:
        pass

    # 3) physical click by rectangle
    try:
        r = btn_wrap.rectangle()
        x, y = center(r)
        mouse_click(coords=(x, y))
        print(f"  -> physical click '{name}' at {(x, y)}")
        return True
    except Exception:
        return False

def enumerate_action_buttons(win_wrap):
    """Return list of (name, wrapper, enabled) for action-ish buttons."""
    btns = []
    try:
        elems = win_wrap.descendants(control_type="Button")
    except Exception:
        return btns

    for e in elems:
        try:
            name = (e.window_text() or "").strip()
            if not name:
                continue
            if name in IGNORE_NAMES:
                continue
            if not ACTION_RE.search(name):
                continue

            w = e.wrapper_object()
            try:
                enabled = w.is_enabled()
            except Exception:
                enabled = True
            btns.append((name, w, enabled))
        except Exception:
            continue

    # Prefer enabled + strong action ordering
    priority = {"uninstall": 0, "next": 1, "yes": 2, "ok": 3, "finish": 4, "close": 5, "done": 6}
    def score(item):
        name, _, enabled = item
        key = name.strip().lower().split()[0]
        return (0 if enabled else 1, priority.get(key, 99), len(name))

    btns.sort(key=score)
    return btns

def keyboard_fallback(win_wrap):
    """
    Wizard fallback: TAB through controls then ENTER.
    This avoids reliance on UIA button discovery.
    """
    try:
        win_wrap.set_focus()
        # Common pattern: default button is reachable by Tab few times
        for _ in range(6):
            win_wrap.type_keys("{TAB}")
            time.sleep(0.05)
        win_wrap.type_keys("{ENTER}")
        print("  -> [kbd] TAB x6 + ENTER fallback")
        return True
    except Exception:
        return False

def find_target_windows():
    found = []
    for backend in ("uia", "win32"):
        try:
            wins = Desktop(backend=backend).windows()
        except Exception:
            continue

        for w in wins:
            try:
                title = (w.window_text() or "").strip()
                if not title:
                    continue
                if TITLE_RE.search(title):
                    found.append((backend, w, title))
            except Exception:
                continue
    # prefer UIA first, then win32
    found.sort(key=lambda x: 0 if x[0] == "uia" else 1)
    return found

def reconnect_by_handle(backend: str, handle: int):
    """Re-acquire wrapper by handle to avoid stale UIA elements."""
    return Desktop(backend=backend).window(handle=handle).wrapper_object()

def main():
    time.sleep(2)  # requirement

    start_winget_uninstall()
    time.sleep(2)

    start = time.time()
    timeout_s = 240
    last_progress = None

    while time.time() - start < timeout_s:
        targets = find_target_windows()

        progressed = False
        for backend, w, title in targets:
            try:
                # IMPORTANT: reconnect each time (stale element fix)
                win = reconnect_by_handle(backend, w.handle)
            except Exception:
                continue

            print(f"[target] ({backend}) {title}")

            # Give the dialog time to fully materialize controls
            try:
                win.wait("ready", timeout=2)
            except Exception:
                pass

            buttons = enumerate_action_buttons(win)
            if buttons:
                print("  [buttons]", [f"{n}{'' if en else ' (disabled)'}" for n, _, en in buttons])
                name, btn_wrap, _ = buttons[0]
                if click_button_wrapper(win, btn_wrap, name):
                    progressed = True
                    last_progress = time.time()
                    time.sleep(0.8)
                    break
            else:
                print("  [buttons] (none)")
                # If UIA sees none, try keyboard fallback (works on many wizards)
                if keyboard_fallback(win):
                    progressed = True
                    last_progress = time.time()
                    time.sleep(0.8)
                    break

        if not progressed:
            if last_progress and (time.time() - last_progress) > 10:
                print("[done] no further progress detected.")
                return
            time.sleep(0.4)

    print("[timeout]")

if __name__ == "__main__":
    main()
