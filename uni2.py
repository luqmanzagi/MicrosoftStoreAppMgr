import time
import subprocess
import re
from pywinauto import Desktop
from pywinauto.mouse import click as mouse_click

WINDOW_TITLE_RE = re.compile(r"CCleaner v.*Uninstall", re.IGNORECASE)

# priority exact labels to click, in order
BUTTON_TEXTS = [
    "Uninstall",
    "Next >",
    "Next",
    "OK",
    "Yes",
    "Finish",
    "Close",
]

def start_winget_uninstall():
    CREATE_NO_WINDOW = 0x08000000
    subprocess.Popen(
        ["winget", "uninstall", "--id", "XPFCWP0SQWXM3V", "--silent", "--disable-interactivity"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=CREATE_NO_WINDOW
    )

def center_of_rect(rect):
    # rect: pywinauto Rectangle
    return (int((rect.left + rect.right) / 2), int((rect.top + rect.bottom) / 2))

def click_button_physically(btn, label):
    r = btn.rectangle()
    x, y = center_of_rect(r)
    # physical click at the control center (most reliable)
    mouse_click(coords=(x, y))
    print(f"  -> physical click '{label}' at {(x,y)}")

def try_click_on_window(win):
    # find the best button by exact name first
    for txt in BUTTON_TEXTS:
        try:
            btn = win.child_window(title=txt, control_type="Button")
            if btn.exists(timeout=0.5):
                w = btn.wrapper_object()

                # 1) try invoke
                try:
                    w.invoke()
                    print(f"  -> invoke '{txt}'")
                    return True
                except Exception as e:
                    # 2) try click_input
                    try:
                        w.click_input()
                        print(f"  -> click_input '{txt}'")
                        return True
                    except Exception:
                        # 3) physical click by rectangle
                        click_button_physically(w, txt)
                        return True
        except Exception:
            pass

    # backup: ALT+N is common for "Next"
    try:
        win.set_focus()
        win.type_keys("%n")  # Alt+N
        print("  -> sent Alt+N fallback")
        return True
    except Exception:
        return False

def main():
    # 1) wait 2 seconds
    time.sleep(2)

    start_winget_uninstall()
    time.sleep(2)

    start = time.time()
    timeout = 180
    last_action = None

    while time.time() - start < timeout:
        wins = Desktop(backend="uia").windows(visible_only=True)
        targets = []
        for w in wins:
            try:
                title = (w.window_text() or "").strip()
                if WINDOW_TITLE_RE.search(title):
                    targets.append(w)
            except Exception:
                pass

        if targets:
            # pick the first matching uninstall window
            win = targets[0]
            print(f"[target] {win.window_text()}")
            try:
                win.wait("ready", timeout=2)
            except Exception:
                pass

            if try_click_on_window(win):
                last_action = time.time()
                time.sleep(0.8)
                continue

        # stop if nothing changed for a bit after we acted
        if last_action and (time.time() - last_action) > 6:
            print("[done] no further progress detected.")
            return

        time.sleep(0.4)

    print("[timeout]")

if __name__ == "__main__":
    main()
