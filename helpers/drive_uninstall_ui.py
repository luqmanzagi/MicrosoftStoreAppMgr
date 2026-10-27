"""Click through uninstall dialogs and UAC prompts that winget leaves on screen.

Based on uni4.py (pywinauto). CapCut and similar uninstallers draw OK/Cancel
themselves, and UAC Yes is not a normal button, so Enter is not used on those
confirms: it would hit Cancel/No. The wanted button is the one left of the
blue default.
"""
import argparse
import ctypes
import os
import re
import sys
import time
from ctypes import wintypes
from typing import List, Optional, Set, Tuple

sys.coinit_flags = 2  # STA, required before pywinauto
from pywinauto import Desktop

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
    re.compile(r"\bskip\b", re.IGNORECASE),
    re.compile(r"\bno thanks\b", re.IGNORECASE),
    re.compile(r"\bnot now\b", re.IGNORECASE),
    re.compile(r"\bcomplete\b", re.IGNORECASE),
    re.compile(r"\bdecline\b", re.IGNORECASE),
]

FORM_PATTERNS: List[re.Pattern] = [
    re.compile(r"^\s*uninstall\s*$", re.IGNORECASE),
    re.compile(r"\bremove\b", re.IGNORECASE),
    re.compile(r"\bdelete\b", re.IGNORECASE),
    re.compile(r"^\s*next\b", re.IGNORECASE),
    re.compile(r"\bcontinue\b", re.IGNORECASE),
    re.compile(r"\bproceed\b", re.IGNORECASE),
    re.compile(r"^\s*yes\s*$", re.IGNORECASE),
    re.compile(r"\bagree\b", re.IGNORECASE),
    re.compile(r"\baccept\b", re.IGNORECASE),
    re.compile(r"\bfinish\b", re.IGNORECASE),
    re.compile(r"^\s*close\s*$", re.IGNORECASE),
    re.compile(r"\bdone\b", re.IGNORECASE),
    re.compile(r"\bskip\b", re.IGNORECASE),
    re.compile(r"\bno thanks\b", re.IGNORECASE),
    re.compile(r"\bcomplete\b", re.IGNORECASE),
    re.compile(r"\bnot now\b", re.IGNORECASE),
]

UAC_PATTERNS: List[re.Pattern] = [re.compile(r"^\s*yes\s*$", re.IGNORECASE)]

UNINSTALL_ONLY_PATTERNS: List[re.Pattern] = [
    re.compile(r"^\s*uninstall\s*$", re.IGNORECASE),
    re.compile(r"\bremove\b", re.IGNORECASE),
    re.compile(r"\bdelete\b", re.IGNORECASE),
]

UNINSTALL_OPTION_RE = re.compile(r"^\s*uninstall\b", re.IGNORECASE)

IGNORE_EXACT = {
    "Cancel", "Back", "Minimize", "Maximize", "Close", "Help",
    "Take the survey", "No",
}

IGNORE_TITLE_RE = re.compile(
    r"(windows terminal|terminal|powershell|command prompt|cmd\.exe|"
    r"microsoft store|microsoft edge|vscode|visual studio code|cursor)",
    re.IGNORECASE,
)

FORM_CLASS_RE = re.compile(
    r"(#32770|TWizardForm|TNewWizardForm|TSetupForm|TUninstallForm|"
    r"MsiDialogCloseClass|WindowsForms10|Uninstall)",
    re.IGNORECASE,
)

RELATED_TITLE_RE = re.compile(
    r"(uninstall|uninstaller|installer|\bsetup\b|\bremove\b|\bwizard\b|"
    r"user account control)",
    re.IGNORECASE,
)

IGNORE_PROCS = {
    "powershell", "pwsh", "cmd", "conhost", "cursor", "code", "explorer",
    "ffmpeg", "python", "pythonw", "windowsterminal", "openconsole",
    "searchhost", "shellexperiencehost", "startmenuexperiencehost",
    "textinputhost", "applicationframehost", "systemsettings", "lockapp",
    "dwm", "sihost", "taskhostw", "ctfmon", "securityhealthsystray",
    "widgets", "widgetservice", "phoneexperiencehost", "runtimebroker",
    "dllhost", "backgroundtaskhost", "svchost", "smartscreen", "comppkgsrv",
    "mitmdump", "screenrec-recorder", "gdigrab", "chrome", "msedge",
    "firefox", "opera", "brave", "iexplore", "devenv", "notepad",
}

UNINSTALL_PROCS = {
    "setup", "msiexec", "consent", "credentialuibroker", "winget", "appinstaller",
}

OPTION_CONTROL_TYPES = ("RadioButton", "ListItem", "CheckBox", "TabItem")

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
kernel32 = ctypes.windll.kernel32

user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowVisible.restype = wintypes.BOOL
user32.IsWindowEnabled.argtypes = [wintypes.HWND]
user32.IsWindowEnabled.restype = wintypes.BOOL

WM_GETTEXT = 0x000D
WM_GETTEXTLENGTH = 0x000E
BM_CLICK = 0x00F5
SW_RESTORE = 9
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
KEYEVENTF_KEYUP = 0x0002
VK_MENU = 0x12
VK_Y = 0x59
SRCCOPY = 0x00CC0020

WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_int, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
user32.EnumWindows.restype = wintypes.BOOL
user32.EnumChildWindows.argtypes = [wintypes.HWND, WNDENUMPROC, wintypes.LPARAM]
user32.EnumChildWindows.restype = wintypes.BOOL


class RECT(ctypes.Structure):
    _fields_ = [
        ("left", ctypes.c_long),
        ("top", ctypes.c_long),
        ("right", ctypes.c_long),
        ("bottom", ctypes.c_long),
    ]


user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(RECT)]
user32.GetWindowRect.restype = wintypes.BOOL

ULONG_PTR = ctypes.c_size_t
INPUT_MOUSE = 0
INPUT_KEYBOARD = 1


class MOUSEINPUT(ctypes.Structure):
    _fields_ = (
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    )


class KEYBDINPUT(ctypes.Structure):
    _fields_ = (
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    )


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = (
        ("uMsg", wintypes.DWORD),
        ("wParamL", wintypes.WORD),
        ("wParamH", wintypes.WORD),
    )


class INPUTUNION(ctypes.Union):
    _fields_ = (("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT))


class INPUT(ctypes.Structure):
    _fields_ = (("type", wintypes.DWORD), ("union", INPUTUNION))


user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
user32.SendInput.restype = wintypes.UINT


class Btn:
    def __init__(self, name, enabled=True, wrap=None, hwnd=0, left=0, top=0, right=0, bottom=0):
        self.name = name
        self.enabled = enabled
        self.wrap = wrap
        self.hwnd = hwnd
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom


_LOG_PATH = None
_APP_NAME = ""
_IGNORE_PID = 0
_uninstall_option_done = set()
_enum_callback_refs = []


def log(msg: str) -> None:
    line = msg if msg.startswith("  ") else "  " + msg
    print(line, flush=True)
    if _LOG_PATH:
        try:
            with open(_LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass


def _center_xy(left, top, right, bottom) -> Tuple[int, int]:
    return (int((left + right) / 2), int((top + bottom) / 2))


def _clean_name(name: str) -> str:
    if not name:
        return ""
    return name.replace("&&", "\u0001").replace("&", "").replace("\u0001", "&").strip()


def _window_text(hwnd: int) -> str:
    buf = ctypes.create_unicode_buffer(512)
    user32.GetWindowTextW(hwnd, buf, 512)
    if buf.value:
        return buf.value
    length = user32.SendMessageW(hwnd, WM_GETTEXTLENGTH, 0, 0)
    if length <= 0 or length > 500:
        return ""
    buf2 = ctypes.create_unicode_buffer(length + 1)
    user32.SendMessageW(hwnd, WM_GETTEXT, length + 1, buf2)
    return buf2.value or ""


def _class_name_hwnd(hwnd: int) -> str:
    buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buf, 256)
    return buf.value or ""


def _pid_of(hwnd: int) -> int:
    pid = wintypes.DWORD(0)
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return int(pid.value)


def _rect_of(hwnd: int) -> Optional[Tuple[int, int, int, int]]:
    r = RECT()
    if not user32.GetWindowRect(hwnd, ctypes.byref(r)):
        return None
    return (r.left, r.top, r.right, r.bottom)


def _process_name(pid: int) -> str:
    if pid <= 0:
        return ""
    handle = kernel32.OpenProcess(0x1000, False, pid)
    if not handle:
        return ""
    try:
        buf = ctypes.create_unicode_buffer(32768)
        size = ctypes.c_uint(32768)
        if kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
            return os.path.splitext(os.path.basename(buf.value))[0]
        return ""
    finally:
        kernel32.CloseHandle(handle)


def _focus_hwnd(hwnd: int) -> None:
    user32.ShowWindow(hwnd, SW_RESTORE)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.05)


def _usable(b: Optional[Btn]) -> bool:
    return bool(b) and (b.right - b.left) >= 8 and (b.bottom - b.top) >= 8


def _click_xy(x: int, y: int) -> bool:
    """SendInput click. mouse_event is ignored by UAC even on the normal desktop."""
    x, y = int(x), int(y)
    user32.SetCursorPos(x, y)
    time.sleep(0.05)
    extra = ULONG_PTR(0)
    down = INPUT(type=INPUT_MOUSE)
    down.union.mi = MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTDOWN, 0, extra)
    up = INPUT(type=INPUT_MOUSE)
    up.union.mi = MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTUP, 0, extra)
    arr = (INPUT * 2)(down, up)
    n = user32.SendInput(2, ctypes.cast(arr, ctypes.POINTER(INPUT)), ctypes.sizeof(INPUT))
    return n == 2


def _click_btn(b: Btn, backend: str, physical_first: bool) -> bool:
    if not _usable(b):
        return False
    x, y = _center_xy(b.left, b.top, b.right, b.bottom)
    if physical_first:
        if _click_xy(x, y):
            log(f"  -> [{backend}] physical click '{b.name}' at {x},{y}")
            return True
        return False
    if b.wrap is not None:
        try:
            b.wrap.invoke()
            log(f"  -> [{backend}] invoke '{b.name}'")
            return True
        except Exception:
            pass
        try:
            b.wrap.click_input()
            log(f"  -> [{backend}] click_input '{b.name}'")
            return True
        except Exception:
            pass
    if b.hwnd:
        if user32.PostMessageW(b.hwnd, BM_CLICK, 0, 0):
            log(f"  -> [{backend}] BM_CLICK '{b.name}'")
            return True
    if _click_xy(x, y):
        log(f"  -> [{backend}] physical click '{b.name}' at {x},{y}")
        return True
    return False


def _key_input(vk: int, flags: int = 0) -> INPUT:
    inp = INPUT(type=INPUT_KEYBOARD)
    inp.union.ki = KEYBDINPUT(vk, 0, flags, 0, ULONG_PTR(0))
    return inp


def _send_alt_y(hwnd: int) -> None:
    _focus_hwnd(hwnd)
    arr = (INPUT * 4)(
        _key_input(VK_MENU),
        _key_input(VK_Y),
        _key_input(VK_Y, KEYEVENTF_KEYUP),
        _key_input(VK_MENU, KEYEVENTF_KEYUP),
    )
    user32.SendInput(4, ctypes.cast(arr, ctypes.POINTER(INPUT)), ctypes.sizeof(INPUT))


def _is_noise_window(title: str) -> bool:
    return bool(IGNORE_TITLE_RE.search(title or ""))


def _is_form(cls: str) -> bool:
    return bool(FORM_CLASS_RE.search(cls or ""))


def _is_related_title(title: str) -> bool:
    return bool(RELATED_TITLE_RE.search(title or ""))


def _is_uninstall_proc(proc: str) -> bool:
    if not proc:
        return False
    p = proc.lower()
    if p in UNINSTALL_PROCS:
        return True
    if p.startswith("unins"):
        return True
    return False


def _is_uac(proc: str, title: str) -> bool:
    if (proc or "").lower() in ("consent", "credentialuibroker"):
        return True
    return bool(title) and "user account control" in title.lower()


def _name_in_title(title: str) -> bool:
    if not _APP_NAME or not title:
        return False
    if len(_APP_NAME) >= 3 and _APP_NAME.lower() in title.lower():
        return True
    compact_app = re.sub(r"[^A-Za-z0-9]", "", _APP_NAME)
    compact_title = re.sub(r"[^A-Za-z0-9]", "", title)
    return len(compact_app) >= 5 and compact_app.lower() in compact_title.lower()


def _patterns_for(uac: bool, is_form: bool, strong: bool) -> List[re.Pattern]:
    if uac:
        return UAC_PATTERNS
    if is_form and not strong:
        return FORM_PATTERNS
    if strong:
        return ACTION_PATTERNS
    return UNINSTALL_ONLY_PATTERNS


def _pick(buttons: List[Btn], patterns: List[re.Pattern]) -> Optional[Btn]:
    for pass_n in (0, 1):
        for pat in patterns:
            for b in buttons:
                if not b.name or b.name in IGNORE_EXACT:
                    continue
                if pass_n == 0 and not b.enabled:
                    continue
                if pat.search(b.name):
                    return b
    return None


def _dedupe(buttons: List[Btn]) -> List[Btn]:
    seen = {}
    uniq = []
    for b in buttons:
        key = (b.name or "").lower()
        if not key:
            uniq.append(b)
            continue
        if key not in seen:
            seen[key] = len(uniq)
            uniq.append(b)
        elif not uniq[seen[key]].enabled and b.enabled:
            uniq[seen[key]] = b
    return uniq


def _uia_buttons(hwnd: int) -> List[Btn]:
    out = []
    try:
        win = Desktop(backend="uia").window(handle=hwnd).wrapper_object()
    except Exception:
        return out
    try:
        win_top = win.rectangle().top
    except Exception:
        win_top = 0
    try:
        elems = win.descendants(control_type="Button")
    except Exception:
        return out
    for e in elems:
        try:
            name = _clean_name(e.window_text() or "")
            if not name or name in IGNORE_EXACT:
                continue
            bw = e.wrapper_object()
            try:
                enabled = bw.is_enabled()
            except Exception:
                enabled = True
            try:
                r = bw.rectangle()
                left, top, right, bottom = r.left, r.top, r.right, r.bottom
            except Exception:
                left = top = right = bottom = 0
            if _is_titlebar(name, left, top, right, bottom, win_top):
                continue
            out.append(Btn(name, enabled, bw, 0, left, top, right, bottom))
        except Exception:
            continue
    return out


def _uia_named(hwnd: int) -> List[Btn]:
    out = []
    try:
        win = Desktop(backend="uia").window(handle=hwnd).wrapper_object()
    except Exception:
        return out
    try:
        elems = win.descendants()
    except Exception:
        elems = []
    scanned = 0
    for e in elems:
        scanned += 1
        if scanned > 120:
            break
        try:
            name = _clean_name(e.window_text() or "")
            if not name or name in IGNORE_EXACT:
                continue
            if not any(pat.search(name) for pat in ACTION_PATTERNS):
                continue
            bw = e.wrapper_object()
            r = bw.rectangle()
            w, h = r.right - r.left, r.bottom - r.top
            if w < 8 or h < 8 or w > 520 or h > 120:
                continue
            try:
                enabled = bw.is_enabled()
            except Exception:
                enabled = True
            out.append(Btn(name, enabled, bw, 0, r.left, r.top, r.right, r.bottom))
        except Exception:
            continue
    return out


def _is_titlebar(name, left, top, right, bottom, win_top) -> bool:
    if name not in ("Close", "Minimize", "Maximize"):
        return False
    w, h = right - left, bottom - top
    if w <= 0 or h <= 0:
        return True
    return w < 80 and h < 50 and top <= win_top + 48


def _is_button_class(cls: str) -> bool:
    return cls in ("Button", "TNewButton", "TButton")


def _win32_buttons(hwnd: int) -> List[Btn]:
    out = []
    wr = _rect_of(hwnd)
    win_top = wr[1] if wr else 0

    def cb(child, _lparam):
        cls = _class_name_hwnd(child)
        if not _is_button_class(cls) or not user32.IsWindowVisible(child):
            return 1
        name = _clean_name(_window_text(child))
        if name in IGNORE_EXACT:
            return 1
        rr = _rect_of(child)
        if not rr:
            return 1
        if name and _is_titlebar(name, rr[0], rr[1], rr[2], rr[3], win_top):
            return 1
        out.append(Btn(
            name, bool(user32.IsWindowEnabled(child)), None, int(child),
            rr[0], rr[1], rr[2], rr[3],
        ))
        return 1

    c_cb = WNDENUMPROC(cb)
    _enum_callback_refs.append(c_cb)
    user32.EnumChildWindows(hwnd, c_cb, 0)
    if len(_enum_callback_refs) > 20:
        del _enum_callback_refs[:10]
    return out


def _put_uninstall_on_form(hwnd: int, title: str) -> bool:
    if hwnd in _uninstall_option_done:
        return False
    try:
        win = Desktop(backend="uia").window(handle=hwnd).wrapper_object()
    except Exception:
        return False
    for ct in OPTION_CONTROL_TYPES:
        try:
            elems = win.descendants(control_type=ct)
        except Exception:
            continue
        for e in elems:
            try:
                name = _clean_name(e.window_text() or "")
                if not name or not UNINSTALL_OPTION_RE.search(name):
                    continue
                bw = e.wrapper_object()
                try:
                    if bw.is_selected():
                        _uninstall_option_done.add(hwnd)
                        return False
                except Exception:
                    pass
                r = bw.rectangle()
                b = Btn(name, True, bw, 0, r.left, r.top, r.right, r.bottom)
                log(f"[target] (uia) {title}")
                if _click_btn(b, "uia", False):
                    _uninstall_option_done.add(hwnd)
                    return True
            except Exception:
                continue
    return False


def _is_accent(color: int) -> bool:
    if color == 0xFFFFFFFF:
        return False
    r = color & 0xFF
    g = (color >> 8) & 0xFF
    b = (color >> 16) & 0xFF
    # Blue (UAC No) or CapCut teal Complete.
    if b > 145 and b > r + 40 and g > 60:
        return True
    if g > 140 and b > 140 and g > r + 40 and b > r + 40:
        return True
    return False


def _lighter_than(at: int, bg: int, delta: int) -> bool:
    if at == 0xFFFFFFFF or bg == 0xFFFFFFFF:
        return False
    al = ((at & 0xFF) + ((at >> 8) & 0xFF) + ((at >> 16) & 0xFF)) // 3
    bl = ((bg & 0xFF) + ((bg >> 8) & 0xFF) + ((bg >> 16) & 0xFF)) // 3
    return al >= bl + delta


def _find_left_of_accent(hwnd: int, lenient: bool) -> Optional[Btn]:
    """OK/Yes sits immediately left of the blue default (Cancel/No)."""
    wr = _rect_of(hwnd)
    if not wr:
        return None
    left, top, right, bottom = wr
    width, height = right - left, bottom - top
    if width < 120 or height < 80 or width > 1600 or height > 1200:
        return None

    screen = user32.GetDC(0)
    if not screen:
        return None
    mem = bmp = old = 0
    try:
        mem = gdi32.CreateCompatibleDC(screen)
        bmp = gdi32.CreateCompatibleBitmap(screen, width, height)
        if not mem or not bmp:
            return None
        old = gdi32.SelectObject(mem, bmp)
        if not gdi32.BitBlt(mem, 0, 0, width, height, screen, left, top, SRCCOPY):
            return None

        step = 2
        y0 = height * 50 // 100
        cols = width // step
        rows = (height - y0) // step
        if cols < 2 or rows < 2 or cols * rows > 500000:
            return None
        accent = [False] * (cols * rows)
        for gy in range(rows):
            for gx in range(cols):
                if _is_accent(gdi32.GetPixel(mem, gx * step, y0 + gy * step)):
                    accent[gy * cols + gx] = True

        seen = [False] * len(accent)
        best = None
        for start in range(len(accent)):
            if not accent[start] or seen[start]:
                continue
            stack = [start]
            seen[start] = True
            min_x, min_y, max_x, max_y, n = width, height, 0, 0, 0
            while stack:
                cur = stack.pop()
                gx, gy = cur % cols, cur // cols
                px, py = gx * step, y0 + gy * step
                min_x, min_y = min(min_x, px), min(min_y, py)
                max_x, max_y = max(max_x, px), max(max_y, py)
                n += 1
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dx == 0 and dy == 0:
                            continue
                        nx, ny = gx + dx, gy + dy
                        if nx < 0 or ny < 0 or nx >= cols or ny >= rows:
                            continue
                        ni = ny * cols + nx
                        if seen[ni] or not accent[ni]:
                            continue
                        seen[ni] = True
                        stack.append(ni)
            bw, bh = max_x - min_x, max_y - min_y
            if n < 12 or bw < 36 or bw > 220 or bh < 14 or bh > 70:
                continue
            if best is None or max_x >= best[2]:
                best = (min_x, min_y, max_x, max_y, n)

        if not best:
            return None
        min_x, min_y, max_x, max_y, _n = best
        accent_btn = Btn(
            "Yes" if lenient else "Complete",
            True, None, 0,
            left + min_x, top + min_y, left + max_x, top + max_y,
        )
        accent_w = max_x - min_x
        gap = min(20, max(4, accent_w // 10))
        ok_left = min_x - gap - accent_w
        # CapCut "Complete" is the only (centered) teal button. Click it.
        # UAC Yes / CapCut OK sit left of the blue default — click that slot
        # only when it looks like a real second button.
        if ok_left < 2:
            return None if lenient else accent_btn
        cx = ok_left + accent_w // 2
        cy = min_y + (max_y - min_y) // 2
        if lenient or _lighter_than(gdi32.GetPixel(mem, cx, cy), gdi32.GetPixel(mem, width // 2, height // 5), 12):
            return Btn(
                "Yes" if lenient else "OK",
                True, None, 0,
                left + ok_left, top + min_y, left + ok_left + accent_w, top + max_y,
            )
        return None if lenient else accent_btn
    except Exception:
        return None
    finally:
        if old and mem:
            gdi32.SelectObject(mem, old)
        if bmp:
            gdi32.DeleteObject(bmp)
        if mem:
            gdi32.DeleteDC(mem)
        user32.ReleaseDC(0, screen)


def _leftmost_bottom_button(buttons: List[Btn], wr) -> Optional[Btn]:
    if not wr:
        return None
    left, top, right, bottom = wr
    width, height = right - left, bottom - top
    hits = []
    for b in buttons:
        bw, bh = b.right - b.left, b.bottom - b.top
        if bw < 24 or bh < 12 or bw > 240 or bh > 80:
            continue
        if b.top < top + height * 0.45:
            continue
        if b.left < left + width * 0.20:
            continue
        if b.name in IGNORE_EXACT:
            continue
        hits.append(b)
    if len(hits) < 1:
        return None
    hits.sort(key=lambda x: x.left)
    # Prefer the left of a right-side pair (OK/Yes left of Cancel/No).
    if len(hits) >= 2:
        return hits[0]
    if not hits[0].name:
        return hits[0]
    return None


def _enum_top_windows() -> list:
    wins = []

    def cb(hwnd, _lparam):
        if not user32.IsWindowVisible(hwnd):
            return 1
        title = (_window_text(hwnd) or "").strip()
        cls = _class_name_hwnd(hwnd)
        pid = _pid_of(hwnd)
        wins.append((int(hwnd), title, cls, pid))
        return 1

    c_cb = WNDENUMPROC(cb)
    _enum_callback_refs.append(c_cb)
    user32.EnumWindows(c_cb, 0)
    return wins


def _handle_window(hwnd, title, cls, pid, baseline: Set[int]) -> bool:
    if _IGNORE_PID and pid == _IGNORE_PID:
        return False
    if _is_noise_window(title):
        return False
    proc = _process_name(pid)
    if proc and proc.lower() in IGNORE_PROCS:
        return False

    is_new = hwnd not in baseline
    proc_hit = _is_uninstall_proc(proc)
    if not is_new and not proc_hit:
        return False

    uac = _is_uac(proc, title)
    form = _is_form(cls)
    title_hit = _is_related_title(title)
    name_hit = _name_in_title(title)
    strong = proc_hit or title_hit or name_hit or uac
    confirm = uac or ("uninstall" in (title or "").lower()) or proc_hit

    if not form and not strong and not is_new:
        return False

    label = title or proc or cls or hex(hwnd)
    if form and not uac:
        if _put_uninstall_on_form(hwnd, label):
            return True

    buttons = _dedupe(_uia_buttons(hwnd) + _win32_buttons(hwnd) + _uia_named(hwnd))
    choice = _pick(buttons, _patterns_for(uac, form, strong))
    if not _usable(choice):
        choice = None
    named = [b.name for b in buttons if b.name]

    if choice is None and confirm:
        choice = _leftmost_bottom_button(buttons, _rect_of(hwnd))
        if choice is not None and not uac:
            choice.name = choice.name or "OK"
        if not _usable(choice):
            choice = None

    if choice is None and confirm:
        choice = _find_left_of_accent(hwnd, uac)
        if not _usable(choice):
            choice = None

    backend = "uac" if uac else "uia"
    if choice:
        _focus_hwnd(hwnd)
        log(f"[target] ({backend}) {label}")
        if named:
            log(f"  [buttons] {named}")
        if _click_btn(choice, backend, physical_first=True):
            return True
        log(f"  [ui] click failed '{choice.name}' rect=({int(choice.left)},{int(choice.top)},{int(choice.right)},{int(choice.bottom)})")

    wr = _rect_of(hwnd)
    if uac and wr:
        left, top, right, bottom = wr
        # Yes is the left command button; No is the blue default on the right.
        x = left + int((right - left) * 0.42)
        y = top + int((bottom - top) * 0.86)
        log(f"[target] (uac) {label}")
        _focus_hwnd(hwnd)
        if _click_xy(x, y):
            log(f"  -> [uac] physical click 'Yes' at {x},{y}")
            _send_alt_y(hwnd)
            log("  -> [kbd] Alt+Y 'Yes'")
            return True
        _send_alt_y(hwnd)
        log("  -> [kbd] Alt+Y 'Yes'")
        return True

    if confirm and not uac and wr:
        left, top, right, bottom = wr
        # CapCut Complete is a centered teal CTA, not bottom-right OK.
        x = (left + right) // 2
        y = top + int((bottom - top) * 0.62)
        log(f"[target] (uia) {label}")
        if named:
            log(f"  [buttons] {named}")
        else:
            log("  [buttons] (none)")
        _focus_hwnd(hwnd)
        if _click_xy(x, y):
            log(f"  -> [pos] physical click 'Complete' at {x},{y}")
            return True

    return False


def _capture_baseline() -> Set[int]:
    return {hwnd for hwnd, _t, _c, _p in _enum_top_windows()}


def _scan_once(baseline: Set[int]) -> bool:
    for hwnd, title, cls, pid in _enum_top_windows():
        try:
            if _handle_window(hwnd, title, cls, pid, baseline):
                return True
        except Exception as ex:
            log(f"[ui] {ex}")
    return False


def watch_loop(timeout_s: int = 0) -> None:
    log(f"[ui] watching for uninstall dialogs (pywinauto) pid={os.getpid()}")
    baseline = _capture_baseline()
    start = time.time()
    while True:
        if timeout_s and (time.time() - start) >= timeout_s:
            log("[timeout] reached UI automation timeout.")
            return
        hit = False
        try:
            hit = _scan_once(baseline)
        except Exception as ex:
            log(f"[ui] {ex}")
        time.sleep(0.8 if hit else 0.4)


def main() -> int:
    global _LOG_PATH, _APP_NAME, _IGNORE_PID

    ap = argparse.ArgumentParser(description="Click uninstall wizard buttons with pywinauto.")
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--timeout", type=int, default=0)
    ap.add_argument("--app-name", default="")
    ap.add_argument("--log", default="")
    ap.add_argument("--ignore-pid", type=int, default=0)
    args = ap.parse_args()

    _APP_NAME = args.app_name or ""
    _LOG_PATH = args.log or None
    _IGNORE_PID = args.ignore_pid or 0

    timeout_s = 0 if args.watch else args.timeout
    try:
        watch_loop(timeout_s=timeout_s)
    except KeyboardInterrupt:
        pass
    except Exception as ex:
        log(f"[ui] fatal {ex}")
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
