"""Click uninstall controls that are painted, not exposed as UI Automation buttons.

pywinauto (and FlaUI) read the UI Automation tree. Avast's Uninstall card,
Movavi's "Stay with 40% off" page, the Citrix Yes/No prompt, the Malwarebytes
"Skip this step" survey, and the WeChat uninstaller draw their own pixels, so
that tree has no button to click. This driver screenshots the window, reads
the labels with the Windows OCR engine, and clicks the right label with
PyAutoGUI.

UAC Yes is the exception: consent.exe ignores PyAutoGUI's mouse_event, so
that one click is sent with SendInput.
"""
import argparse
import asyncio
import ctypes
import io
import os
import re
import subprocess
import sys
import time
from ctypes import wintypes
from typing import List, Optional, Set, Tuple

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    try:
        ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass

import pyautogui
from PIL import Image, ImageFilter, ImageGrab

pyautogui.FAILSAFE = False
pyautogui.PAUSE = 0

# Whole short line must match. "Uninstalling..." and "What's your next step?"
# do not. "Yes, but not resolved" does not. A long sentence that merely
# contains the word is not a button.
_RANKS = (
    # "Uninstall complete" and "Uninstall Successful" are headings.
    # "Uninstall Malwarebytes" is the button.
    ("uninstall", re.compile(
        r"^\s*(uninstall\b(?!\s+(?:complete|successful)\b)|卸载)",
        re.IGNORECASE,
    )),
    ("submit", re.compile(r"^\s*submit and uninstall\b", re.IGNORECASE)),
    ("remove", re.compile(r"^\s*(remove\b|删除)", re.IGNORECASE)),
    ("delete", re.compile(r"^\s*delete\b", re.IGNORECASE)),
    ("yes", re.compile(r"^\s*(yes|是)\s*$", re.IGNORECASE)),
    ("skip", re.compile(r"^\s*(skip\b|no thanks\b|not now\b|跳过)", re.IGNORECASE)),
    ("next", re.compile(r"^\s*(next\b|下一步)", re.IGNORECASE)),
    ("continue", re.compile(
        r"^\s*(continue uninstalling[.!]?|continue\b|继续)\s*$",
        re.IGNORECASE,
    )),
    ("proceed", re.compile(r"^\s*proceed\b", re.IGNORECASE)),
    ("ok", re.compile(r"^\s*(ok|okay|确定)\s*$", re.IGNORECASE)),
    ("agree", re.compile(r"^\s*(i agree|agree|accept)\b", re.IGNORECASE)),
    ("finish", re.compile(r"^\s*(finish|done|完成)\b", re.IGNORECASE)),
    ("complete", re.compile(r"^\s*complete\b", re.IGNORECASE)),
    # Only eligible once the screen says the uninstall already finished.
    ("close", re.compile(r"^\s*close\s*$", re.IGNORECASE)),
)
# These advance a wizard. They are only safe once the window is already an
# uninstaller (title, process, or the text "uninstall" / "why you're leaving").
_PROGRESS = {"yes", "skip", "next", "continue", "proceed", "ok", "agree", "finish", "complete", "close"}
# Survey radios are painted. Windows OCR reads the circle as "C)", so the
# line is "C) Other" rather than "Other".
_RADIO_PREFIX = re.compile(r"^\s*[A-Za-z0-9]\s*\)\s*")
_OTHER_RE = re.compile(
    r"^other\b(\s*[:.\-]|(\s+(reason|please specify|\(please specify\))))?\s*$",
    re.IGNORECASE,
)
_BUTTONISH = re.compile(r"^(continue|cancel|back|close|skip|next|ok|yes|no)\b", re.IGNORECASE)
_REASON_FIELD = re.compile(
    r"(tell us what made you|please (enter|fill)|fill in the rea)",
    re.IGNORECASE,
)
_COMPLETE_HEADING = re.compile(r"^\s*uninstall complete\b", re.IGNORECASE)
# CapCut OK and Citrix Yes are low-contrast. The colored button beside them is Cancel or No.
_CONFIRM_RE = re.compile(r"are you sure", re.IGNORECASE)
# "Close" is ignored until one of these is on screen. Otherwise it dismisses the wizard.
_DONE_RE = re.compile(
    r"(uninstall\s+successful|successfully\s+uninstalled|has\s+been\s+uninstalled|"
    r"uninstall(?:ation)?\s+complete)",
    re.IGNORECASE,
)
_REASON = "MSProjectUninstall"

_IGNORE_LINE = {
    "cancel", "back", "no", "close", "help", "repair", "update", "stay", "keep",
    "minimize", "maximize", "nee", "annuleren",
}

_IGNORE_TITLE_RE = re.compile(
    r"(windows terminal|terminal|powershell|command prompt|cmd\.exe|"
    r"visual studio code|cursor)",
    re.IGNORECASE,
)
_RELATED_TITLE_RE = re.compile(
    r"(uninstall|uninstaller|installer|\bsetup\b|\bremove\b|\bwizard\b|"
    r"user account control)",
    re.IGNORECASE,
)
_RELATED_TEXT_RE = re.compile(
    r"(uninstall|uninstaller|you.?re leaving|you are leaving|sorry to see you)",
    re.IGNORECASE,
)
_TOKEN_STOP = {
    "free", "software", "windows", "video", "editor", "antivirus", "workspace",
    "connect", "files", "deleted", "movie", "maker", "application", "recover",
    "recovery", "your", "from", "with", "that", "lost",
}

_IGNORE_PROCS = {
    "powershell", "pwsh", "cmd", "conhost", "cursor", "code", "explorer",
    "ffmpeg", "python", "pythonw", "windowsterminal", "openconsole",
    "searchhost", "shellexperiencehost", "startmenuexperiencehost",
    "textinputhost", "applicationframehost", "systemsettings", "lockapp",
    "dwm", "sihost", "taskhostw", "ctfmon", "securityhealthsystray",
    "widgets", "widgetservice", "phoneexperiencehost", "runtimebroker",
    "dllhost", "backgroundtaskhost", "svchost", "smartscreen", "comppkgsrv",
    "mitmdump", "screenrec-recorder", "gdigrab", "devenv", "notepad",
}
_BROWSERS = {"chrome", "msedge", "firefox", "opera", "brave", "iexplore"}
_SHELL_CLASS = {"Progman", "WorkerW", "Shell_TrayWnd", "NotifyIconOverflowWindow"}
_UNINSTALL_PROCS = {"setup", "msiexec", "consent", "credentialuibroker", "winget", "appinstaller"}

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32

user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowVisible.restype = wintypes.BOOL
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.QueryFullProcessImageNameW.argtypes = [
    wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD),
]
kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]

WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_int, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
user32.EnumWindows.restype = wintypes.BOOL


class RECT(ctypes.Structure):
    _fields_ = [
        ("left", ctypes.c_long),
        ("top", ctypes.c_long),
        ("right", ctypes.c_long),
        ("bottom", ctypes.c_long),
    ]


user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(RECT)]
user32.GetWindowRect.restype = wintypes.BOOL
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.PostMessageW.restype = wintypes.BOOL
WM_CLOSE = 0x0010

ULONG_PTR = ctypes.c_size_t
INPUT_MOUSE = 0
INPUT_KEYBOARD = 1
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
KEYEVENTF_KEYUP = 0x0002
VK_MENU = 0x12
VK_Y = 0x59
SW_RESTORE = 9


class MOUSEINPUT(ctypes.Structure):
    _fields_ = (
        ("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR),
    )


class KEYBDINPUT(ctypes.Structure):
    _fields_ = (
        ("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR),
    )


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = (("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD))


class INPUTUNION(ctypes.Union):
    _fields_ = (("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT))


class INPUT(ctypes.Structure):
    _fields_ = (("type", wintypes.DWORD), ("union", INPUTUNION))


user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
user32.SendInput.restype = wintypes.UINT


class Line:
    def __init__(self, text, x, y, w, h):
        self.text = text
        self.x = x
        self.y = y
        self.w = w
        self.h = h


_LOG_PATH = None
_APP_NAME = ""
_IGNORE_PID = 0
_CLOSE_CHROME = False
_FILL_OTHER = False
_enum_callback_refs = []
_engines = None
_loop = None
_logged = set()
_click_counts = {}
_MAX_CLICKS = 12
# The same labels are still on screen after this many clicks, so that label is not a button.
_STUCK_CLICKS = 2
_stuck = {}
_other_filled = set()
_other_tries = {}
_reason_tries = {}
_chrome_closed = set()


def log(msg: str) -> None:
    line = msg if msg.startswith("  ") else "  " + msg
    print(line, flush=True)
    if _LOG_PATH:
        try:
            with open(_LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass


def _app_tokens() -> List[str]:
    found = re.findall(r"[A-Za-z][A-Za-z0-9]{3,}", _APP_NAME or "")
    return [t.lower() for t in found if t.lower() not in _TOKEN_STOP]


def _token_in(text: str) -> bool:
    hay = (text or "").lower()
    if not hay:
        return False
    for token in _app_tokens():
        if token in hay:
            return True
    # "Data Recovery Software ..." shows its window as "Drecov".
    compact = re.sub(r"[^a-z0-9]", "", (_APP_NAME or "").lower())
    if "recovery" in compact and re.search(r"drec", hay):
        return True
    return False


def _window_text(hwnd: int) -> str:
    buf = ctypes.create_unicode_buffer(512)
    user32.GetWindowTextW(hwnd, buf, 512)
    return buf.value or ""


def _class_name(hwnd: int) -> str:
    buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buf, 256)
    return buf.value or ""


def _pid_of(hwnd: int) -> int:
    pid = wintypes.DWORD(0)
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return int(pid.value)


def _process_name(pid: int) -> str:
    if pid <= 0:
        return ""
    handle = kernel32.OpenProcess(0x1000, False, pid)
    if not handle:
        return ""
    try:
        buf = ctypes.create_unicode_buffer(32768)
        size = wintypes.DWORD(32768)
        if kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
            return os.path.splitext(os.path.basename(buf.value))[0]
        return ""
    finally:
        kernel32.CloseHandle(handle)


def _rect_of(hwnd: int) -> Optional[Tuple[int, int, int, int]]:
    r = RECT()
    if not user32.GetWindowRect(hwnd, ctypes.byref(r)):
        return None
    if r.right <= r.left or r.bottom <= r.top:
        return None
    return (int(r.left), int(r.top), int(r.right), int(r.bottom))


def _enum_top_windows() -> list:
    wins = []

    def cb(hwnd, _lparam):
        if not user32.IsWindowVisible(hwnd):
            return 1
        wins.append((int(hwnd), (_window_text(hwnd) or "").strip(), _class_name(hwnd), _pid_of(hwnd)))
        return 1

    c_cb = WNDENUMPROC(cb)
    _enum_callback_refs.append(c_cb)
    user32.EnumWindows(c_cb, 0)
    if len(_enum_callback_refs) > 20:
        del _enum_callback_refs[:10]
    return wins


def _is_uac(proc: str, title: str) -> bool:
    if (proc or "").lower() in ("consent", "credentialuibroker"):
        return True
    return "user account control" in (title or "").lower()


def _is_uninstall_proc(proc: str) -> bool:
    p = (proc or "").lower()
    if not p:
        return False
    if p in _UNINSTALL_PROCS or p.startswith("unins"):
        return True
    return "uninstall" in p


def _structural(title: str, proc: str) -> bool:
    if _is_uac(proc, title) or _is_uninstall_proc(proc):
        return True
    if _RELATED_TITLE_RE.search(title or ""):
        return True
    if _token_in(title) or _token_in(proc):
        return True
    return False


def _rank_of(text: str) -> Optional[int]:
    for i, (_name, pat) in enumerate(_RANKS):
        if pat.search(text):
            return i
    return None


def _iter_controls(lines: List[Line], related: bool, uac: bool, done: bool = False):
    for line in lines:
        text = " ".join((line.text or "").split())
        if not text or len(text) > 42:
            continue
        # Close stays ignored until the uninstall has finished.
        if text.lower().rstrip(".!") in _IGNORE_LINE and not (done and text.lower().rstrip(".!") == "close"):
            continue
        if line.y < 28 and line.h < 36:
            continue
        if line.w < 12 or line.h < 8 or line.w > 460 or line.h > 90:
            continue
        rank = _rank_of(text)
        if rank is None:
            continue
        name = _RANKS[rank][0]
        if uac and name != "yes":
            continue
        if name in _PROGRESS and not related and not uac:
            continue
        yield rank, name, Line(text, line.x, line.y, line.w, line.h)


def pick_control(
    lines: List[Line],
    related: bool,
    uac: bool,
    blocked: Optional[Set[str]] = None,
    done: bool = False,
) -> Optional[Line]:
    """Choose the label to click. Coordinates are whatever the caller used."""
    blocked = blocked or set()
    best = None
    best_key = None
    for rank, name, line in _iter_controls(lines, related, uac, done):
        if name in blocked:
            continue
        # Lower rank wins. Same label: prefer the wider phrase ("Skip this step"
        # over the word "Skip"), then the one further down the window.
        key = (rank, -line.w, -line.y)
        if best_key is None or key < best_key:
            best_key = key
            best = line
    return best


def _sync_stuck(hwnd: int, names: Set[str]) -> dict:
    """Forget a stuck label once a label shows up that this screen has not shown."""
    state = _stuck.get(hwnd)
    if state is None:
        state = {"seen": set(names), "counts": {}, "blocked": set()}
        _stuck[hwnd] = state
        return state
    if names and not names <= state["seen"]:
        state["seen"] = set(names)
        state["counts"].clear()
        state["blocked"].clear()
    return state


def _choose_label(hwnd: int, lines: List[Line], related: bool, uac: bool, done: bool = False) -> Optional[Line]:
    """Best label. After two clicks that leave the same labels up, try the next one."""
    names = {name for _rank, name, _line in _iter_controls(lines, related, uac, done)}
    state = _sync_stuck(hwnd, names)
    if len(_stuck) > 200:
        _stuck.clear()
        _stuck[hwnd] = state
    choice = pick_control(lines, related, uac, state["blocked"], done)
    if choice is None:
        return None
    name = _RANKS[_rank_of(choice.text)][0]
    if state["counts"].get(name, 0) >= _STUCK_CLICKS:
        state["blocked"].add(name)
        alt = pick_control(lines, related, uac, state["blocked"], done)
        if alt is None:
            state["blocked"].discard(name)
        else:
            log(f"[ui] '{choice.text}' still on screen after {_STUCK_CLICKS} clicks, trying '{alt.text}'")
            choice = alt
            name = _RANKS[_rank_of(choice.text)][0]
    state["counts"][name] = state["counts"].get(name, 0) + 1
    return choice


def _engines_for_ocr():
    global _engines
    if _engines is not None:
        return _engines
    from winrt.windows.globalization import Language
    from winrt.windows.media.ocr import OcrEngine

    found = []
    for tag in ("en-US", "zh-Hans", "nl-NL"):
        try:
            lang = Language(tag)
            if OcrEngine.is_language_supported(lang):
                eng = OcrEngine.try_create_from_language(lang)
                if eng is not None:
                    found.append(eng)
        except Exception:
            continue
    if not found:
        try:
            eng = OcrEngine.try_create_from_user_profile_languages()
            if eng is not None:
                found.append(eng)
        except Exception:
            pass
    _engines = found
    return _engines


def _clahe_luminance(lum, grid: int = 8, clip: float = 2.0):
    """CLAHE on one 8-bit plane. Returns a uint8 array of the same shape."""
    import numpy as np

    h, w = lum.shape
    tile_h = int(np.ceil(h / grid))
    tile_w = int(np.ceil(w / grid))
    padded = np.pad(lum, ((0, tile_h * grid - h), (0, tile_w * grid - w)), mode="edge")
    tiles = padded.reshape(grid, tile_h, grid, tile_w).transpose(0, 2, 1, 3)
    flat = tiles.reshape(grid, grid, -1)
    hist = np.zeros((grid, grid, 256), np.float32)
    for i in range(grid):
        for j in range(grid):
            hist[i, j] = np.bincount(flat[i, j], minlength=256)
    limit = max(1.0, clip * (tile_h * tile_w) / 256.0)
    excess = np.clip(hist - limit, 0, None).sum(axis=2)
    hist = np.minimum(hist, limit)
    hist += (excess / 256.0)[:, :, None]
    cdf = np.cumsum(hist, axis=2)
    span = np.maximum(cdf[:, :, -1:] - cdf[:, :, :1], 1e-6)
    lut = np.clip(np.round((cdf - cdf[:, :, :1]) / span * 255), 0, 255).astype(np.uint8)

    ys = np.arange(h)
    xs = np.arange(w)
    fy = ys / tile_h - 0.5
    fx = xs / tile_w - 0.5
    y0 = np.clip(np.floor(fy), 0, grid - 1).astype(int)
    x0 = np.clip(np.floor(fx), 0, grid - 1).astype(int)
    y1 = np.clip(y0 + 1, 0, grid - 1)
    x1 = np.clip(x0 + 1, 0, grid - 1)
    wy = np.clip(fy - np.floor(fy), 0, 1)
    wx = np.clip(fx - np.floor(fx), 0, 1)
    wy = np.where(y0 == y1, 0, wy)
    wx = np.where(x0 == x1, 0, wx)
    src = lum.astype(np.int32)
    top = lut[y0[:, None], x0[None, :], src] * (1 - wx)[None, :] + lut[y0[:, None], x1[None, :], src] * wx[None, :]
    bot = lut[y1[:, None], x0[None, :], src] * (1 - wx)[None, :] + lut[y1[:, None], x1[None, :], src] * wx[None, :]
    mixed = top * (1 - wy)[:, None] + bot * wy[:, None]
    return np.clip(np.round(mixed), 0, 255).astype(np.uint8)


def _enhance_for_ocr(image: Image.Image) -> Optional[Image.Image]:
    """Enlarge, stretch local contrast, and sharpen. Used only after a miss."""
    try:
        import numpy as np
    except Exception:
        return None
    long_side = max(image.size)
    # WinRT OCR rejects a side longer than about 2600 px.
    if long_side * 3 <= 2500:
        scale = 3
    elif long_side * 2 <= 2500:
        scale = 2
    else:
        scale = 1
    resample = getattr(getattr(Image, "Resampling", Image), "LANCZOS")
    if scale > 1:
        image = image.resize((image.width * scale, image.height * scale), resample)
    rgb = np.asarray(image.convert("RGB"), np.float32)
    lum = (0.2126 * rgb[:, :, 0] + 0.7152 * rgb[:, :, 1] + 0.0722 * rgb[:, :, 2])
    stretched = _clahe_luminance(np.clip(lum, 0, 255).astype(np.uint8)).astype(np.float32)
    factor = np.clip(stretched / np.maximum(lum, 1.0), 0.4, 3.0)
    out = np.clip(rgb * factor[:, :, None], 0, 255).astype(np.uint8)
    sharp = Image.fromarray(out, "RGB").filter(ImageFilter.UnsharpMask(radius=1.2, percent=70, threshold=2))
    return sharp


def _recognize_sync(image: Image.Image) -> List[Line]:
    global _loop
    engines = _engines_for_ocr()
    if not engines:
        return []
    if _loop is None:
        _loop = asyncio.new_event_loop()
    return _loop.run_until_complete(_recognize(image, engines[0]))


async def _recognize(image: Image.Image, engine) -> List[Line]:
    from winrt.windows.graphics.imaging import BitmapAlphaMode, BitmapDecoder, BitmapPixelFormat, SoftwareBitmap
    from winrt.windows.storage.streams import DataWriter, InMemoryRandomAccessStream

    buf = io.BytesIO()
    image.convert("RGB").save(buf, format="PNG")
    stream = InMemoryRandomAccessStream()
    writer = DataWriter(stream)
    writer.write_bytes(buf.getvalue())
    await writer.store_async()
    writer.detach_stream()
    stream.seek(0)
    decoder = await BitmapDecoder.create_async(stream)
    bitmap = await decoder.get_software_bitmap_async()
    bitmap = SoftwareBitmap.convert(bitmap, BitmapPixelFormat.BGRA8, BitmapAlphaMode.PREMULTIPLIED)
    result = await engine.recognize_async(bitmap)
    lines = []

    def add(words):
        if not words:
            return
        left = min(w.bounding_rect.x for w in words)
        top = min(w.bounding_rect.y for w in words)
        right = max(w.bounding_rect.x + w.bounding_rect.width for w in words)
        bottom = max(w.bounding_rect.y + w.bounding_rect.height for w in words)
        text = " ".join(w.text for w in words).strip()
        if text:
            lines.append(Line(text, int(left), int(top), int(right - left), int(bottom - top)))

    for line in result.lines:
        words = list(line.words)
        if not words:
            continue
        add(words)
        # Cards on one row ("Update  Repair  Uninstall") come back as one line.
        # A wide gap means they are separate controls. A sentence has no such gap,
        # so its words are not turned into buttons.
        text = " ".join(w.text for w in words).strip()
        split = False
        if len(words) >= 2 and len(text) <= 42:
            for a, b in zip(words, words[1:]):
                gap = b.bounding_rect.x - (a.bounding_rect.x + a.bounding_rect.width)
                if gap > 24:
                    split = True
                    break
        if split:
            for w in words:
                add([w])
    return lines


def _map_lines(lines: List[Line], ocr_w: int, ocr_h: int, win_w: int, win_h: int) -> List[Line]:
    """OCR pixels -> window pixels. Works after a downscale and when the grab is denser than the rect."""
    sx = win_w / max(1, ocr_w)
    sy = win_h / max(1, ocr_h)
    out = []
    for line in lines:
        out.append(Line(
            line.text,
            int(line.x * sx),
            int(line.y * sy),
            max(1, int(line.w * sx)),
            max(1, int(line.h * sy)),
        ))
    return out


def _grab(rect) -> Optional[Image.Image]:
    try:
        im = ImageGrab.grab(bbox=rect, all_screens=True)
    except Exception:
        return None
    if im.width < 8 or im.height < 8:
        return None
    return im


def _focus(hwnd: int) -> None:
    fg = user32.GetForegroundWindow()
    fg_tid = user32.GetWindowThreadProcessId(fg, None) if fg else 0
    our = kernel32.GetCurrentThreadId()
    attached = False
    if fg_tid and fg_tid != our:
        attached = bool(user32.AttachThreadInput(our, fg_tid, True))
    user32.ShowWindow(hwnd, SW_RESTORE)
    user32.SetForegroundWindow(hwnd)
    if attached:
        user32.AttachThreadInput(our, fg_tid, False)
    time.sleep(0.05)


def _sendinput_click(x: int, y: int) -> bool:
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.05)
    extra = ULONG_PTR(0)
    down = INPUT(type=INPUT_MOUSE)
    down.union.mi = MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTDOWN, 0, extra)
    up = INPUT(type=INPUT_MOUSE)
    up.union.mi = MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTUP, 0, extra)
    arr = (INPUT * 2)(down, up)
    return user32.SendInput(2, ctypes.cast(arr, ctypes.POINTER(INPUT)), ctypes.sizeof(INPUT)) == 2


def _send_alt_y() -> None:
    def key(vk, flags=0):
        inp = INPUT(type=INPUT_KEYBOARD)
        inp.union.ki = KEYBDINPUT(vk, 0, flags, 0, ULONG_PTR(0))
        return inp

    arr = (INPUT * 4)(
        key(VK_MENU), key(VK_Y), key(VK_Y, KEYEVENTF_KEYUP), key(VK_MENU, KEYEVENTF_KEYUP),
    )
    user32.SendInput(4, ctypes.cast(arr, ctypes.POINTER(INPUT)), ctypes.sizeof(INPUT))


def _plain(text: str) -> str:
    return " ".join((text or "").split())


def _radio_body(text: str) -> str:
    return _RADIO_PREFIX.sub("", _plain(text)).strip()


def _other_line(lines: List[Line]) -> Optional[Line]:
    best = None
    best_key = None
    for line in lines:
        body = _radio_body(line.text)
        if not body or len(body) > 42 or not _OTHER_RE.search(body):
            continue
        key = (len(body), -line.y)
        if best_key is None or key < best_key:
            best_key = key
            best = line
    return best


def _reason_field(lines: List[Line], other: Line) -> Optional[Line]:
    """The reason box is the non-radio line under Other. OCR reads its placeholder."""
    found = []
    for line in lines:
        text = _plain(line.text)
        if not text or line is other:
            continue
        if _RADIO_PREFIX.match(text) or _BUTTONISH.match(text):
            continue
        if _OTHER_RE.search(_radio_body(text)):
            continue
        if line.y < other.y:
            continue
        found.append(line)
    if not found:
        return None
    found.sort(key=lambda line: (line.y, -line.w))
    return found[0]


def _reason_box_line(lines: List[Line]) -> Optional[Line]:
    """Placeholder drawn inside the reason box, not the paragraph above it."""
    best = None
    best_len = None
    for line in lines:
        text = _plain(line.text)
        if not text or not _REASON_FIELD.search(text):
            continue
        if best_len is None or len(text) < best_len:
            best_len = len(text)
            best = line
    return best


def _type_reason() -> None:
    pyautogui.hotkey("ctrl", "a")
    pyautogui.write(_REASON, interval=0.02)


def _fill_reason_box(hwnd: int, lines: List[Line], left: int, top: int) -> bool:
    field = _reason_box_line(lines)
    if field is None:
        return False
    x = left + field.x + max(1, field.w // 2)
    y = top + field.y + max(1, field.h // 2)
    _click(hwnd, x, y, "reason", False)
    time.sleep(0.2)
    try:
        _type_reason()
    except Exception as ex:
        log(f"[ui] could not type uninstall reason: {ex}")
        return False
    log(f"[ui] entered {_REASON}")
    return True


def _completion_line(lines: List[Line]) -> Optional[Line]:
    for line in lines:
        if _COMPLETE_HEADING.search(_plain(line.text)):
            return line
    return None


def _is_accent_rgb(r: int, g: int, b: int) -> bool:
    # Blue (Citrix No) or teal (CapCut Cancel).
    if b > 145 and b > r + 40 and g > 60:
        return True
    if g > 140 and b > 140 and g > r + 40 and b > r + 40:
        return True
    return False


def _mean_lum(px, x0: int, y0: int, x1: int, y1: int, width: int, height: int) -> int:
    total = 0
    count = 0
    for y in range(max(0, y0), min(height, y1), 2):
        for x in range(max(0, x0), min(width, x1), 2):
            r, g, b = px[x, y]
            total += r + g + b
            count += 1
    if count == 0:
        return 0
    return total // (count * 3)


def _left_of_accent(image: Image.Image) -> Optional[Tuple[int, int]]:
    """Center of the button left of the blue or teal default. Image pixels.

    OK and Yes are the plain button. Cancel and No are the colored one on the right.
    An empty slot, or a colored button with nothing beside it, is not a click.
    """
    rgb = image.convert("RGB")
    px = rgb.load()
    width, height = rgb.size
    if width < 120 or height < 80:
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
            r, g, b = px[gx * step, min(height - 1, y0 + gy * step)]
            if _is_accent_rgb(r, g, b):
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
            px_x, py = gx * step, y0 + gy * step
            min_x = min(min_x, px_x)
            min_y = min(min_y, py)
            max_x = max(max_x, px_x)
            max_y = max(max_y, py)
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
            best = (min_x, min_y, max_x, max_y)
    if best is None:
        return None
    min_x, min_y, max_x, max_y = best
    accent_w = max_x - min_x
    gap = min(20, max(4, accent_w // 10))
    ok_left = min_x - gap - accent_w
    if ok_left < 2:
        return None
    bg = _mean_lum(px, width // 2 - 8, height // 5, width // 2 + 8, height // 5 + 16, width, height)
    slot = _mean_lum(px, ok_left, min_y, ok_left + accent_w, max_y, width, height)
    if slot < bg + 12:
        return None
    return ok_left + accent_w // 2, min_y + (max_y - min_y) // 2


def _blue_button(image: Image.Image, below_y: int) -> Optional[Tuple[int, int]]:
    """Center of the solid blue button under a heading. White 'Done' is invisible to OCR."""
    rgb = image.convert("RGB")
    px = rgb.load()
    width, height = rgb.size
    y0 = min(height - 1, max(0, below_y + 4))
    y1 = min(height, y0 + 180)
    xs = []
    ys = []
    for y in range(y0, y1, 2):
        for x in range(0, width, 2):
            r, g, b = px[x, y]
            if b > 160 and r < 90 and g < 150 and b > r + 80:
                xs.append(x)
                ys.append(y)
    if len(xs) < 20:
        return None
    left, right = min(xs), max(xs)
    top, bottom = min(ys), max(ys)
    if right - left < 40 or bottom - top < 8:
        return None
    return (left + right) // 2, (top + bottom) // 2


def _fill_other_reason(hwnd: int, lines: List[Line], left: int, top: int, width: int, height: int) -> bool:
    """Select the Other radio and type the reason. Painted radios are only a label."""
    other = _other_line(lines)
    if other is None:
        return False

    radio_y = top + other.y + max(1, other.h // 2)
    radio_x = left + other.x + min(14, max(6, other.w // 8))
    _click(hwnd, radio_x, radio_y, "Other", False)
    time.sleep(0.15)

    field = _reason_field(lines, other)
    if field is not None:
        field_x = left + field.x + max(1, field.w // 2)
        field_y = top + field.y + max(1, field.h // 2)
    else:
        gap_right = width - (other.x + other.w)
        if gap_right > 80:
            field_x = left + other.x + other.w + min(gap_right // 2, 160)
            field_y = radio_y
        else:
            field_x = left + other.x + max(other.w // 2, 24)
            field_y = top + min(height - 8, other.y + other.h + 22)
    _click(hwnd, field_x, field_y, "reason", False)
    time.sleep(0.2)
    try:
        _type_reason()
    except Exception as ex:
        log(f"[ui] could not type uninstall reason: {ex}")
        return False
    log(f"[ui] selected Other and entered {_REASON}")
    return True


def _close_chrome(hwnd: int, pid: int, title: str) -> bool:
    if pid and pid in _chrome_closed:
        return False
    label = title or "Chrome"
    log(f"[ui] closing Chrome '{label}' pid={pid}")
    try:
        user32.PostMessageW(hwnd, WM_CLOSE, 0, 0)
    except Exception as ex:
        log(f"[ui] Chrome WM_CLOSE failed: {ex}")
    if pid:
        try:
            result = subprocess.run(
                ["taskkill", "/PID", str(pid), "/T", "/F"],
                capture_output=True,
                text=True,
                timeout=15,
            )
            if result.returncode == 0:
                _chrome_closed.add(pid)
            else:
                detail = (result.stderr or result.stdout or "").strip()
                log(f"[ui] taskkill Chrome pid={pid} exited {result.returncode} {detail}")
        except Exception as ex:
            log(f"[ui] could not close Chrome pid={pid}: {ex}")
    return True


def _click(hwnd: int, x: int, y: int, label: str, uac: bool) -> bool:
    _focus(hwnd)
    if uac:
        ok = _sendinput_click(x, y)
        _send_alt_y()
        if ok:
            log(f"  -> [pyautogui] SendInput click '{label}' at {x},{y}")
        return ok
    try:
        pyautogui.click(x=int(x), y=int(y))
    except Exception as ex:
        log(f"  [ui] click failed '{label}': {ex}")
        return False
    log(f"  -> [pyautogui] click '{label}' at {x},{y}")
    return True


def _log_once(key: str, msg: str) -> None:
    if key in _logged:
        return
    _logged.add(key)
    if len(_logged) > 400:
        _logged.clear()
    log(msg)


def _handle_window(hwnd, title, cls, pid, baseline: Set[int]) -> bool:
    if _IGNORE_PID and pid == _IGNORE_PID:
        return False
    if cls in _SHELL_CLASS:
        return False
    if _IGNORE_TITLE_RE.search(title or ""):
        return False
    proc = _process_name(pid)
    if proc and proc.lower() in _IGNORE_PROCS:
        return False
    if _CLOSE_CHROME and proc and proc.lower() == "chrome":
        return _close_chrome(hwnd, pid, title)
    if proc and proc.lower() in _BROWSERS and not _token_in(title) and "uninstall" not in (title or "").lower():
        return False

    uac = _is_uac(proc, title)
    structural = _structural(title, proc)
    is_new = hwnd not in baseline
    if not is_new and not structural and not uac:
        return False

    rect = _rect_of(hwnd)
    if not rect:
        return False
    left, top, right, bottom = rect
    width, height = right - left, bottom - top
    if width < 160 or height < 90 or width > 2200 or height > 1400:
        return False

    image = _grab(rect)
    if image is None:
        return False
    if image.width > 1100:
        nh = max(1, int(image.height * (1100 / image.width)))
        image = image.resize((1100, nh))
    ocr_image = image
    enhanced = False
    while True:
        try:
            lines = _recognize_sync(ocr_image)
        except Exception as ex:
            _log_once(f"ocr:{hwnd}", f"[ui] ocr failed on '{title or proc}': {ex}")
            return False

        mapped = _map_lines(lines, ocr_image.width, ocr_image.height, width, height)

        blob = "\n".join(line.text for line in mapped)
        related = structural or bool(_RELATED_TEXT_RE.search(blob)) or _token_in(blob)
        if _FILL_OTHER and related and not uac and hwnd not in _other_filled and _other_line(mapped) is not None:
            tries = _other_tries.get(hwnd, 0)
            if tries < 3:
                _other_tries[hwnd] = tries + 1
                if _fill_other_reason(hwnd, mapped, left, top, width, height):
                    _other_filled.add(hwnd)
                return True
        if _FILL_OTHER and related and not uac and _reason_box_line(mapped) is not None and _REASON.lower() not in blob.lower():
            tries = _reason_tries.get(hwnd, 0)
            if tries < 3:
                _reason_tries[hwnd] = tries + 1
                _fill_reason_box(hwnd, mapped, left, top)
                return True
        done = bool(_DONE_RE.search(blob))
        choice = _choose_label(hwnd, mapped, related, uac, done)
        label = title or proc or cls or hex(hwnd)
        shown = " | ".join(line.text for line in mapped[:12]) or "(none)"
        if choice is None and not uac and _CONFIRM_RE.search(blob.replace("\n", " ")):
            point = _left_of_accent(image)
            if point is not None:
                key = (hwnd, "Yes")
                count = _click_counts.get(key, 0)
                if count < _MAX_CLICKS:
                    _click_counts[key] = count + 1
                    sx = width / max(1, image.width)
                    sy = height / max(1, image.height)
                    x = left + int(point[0] * sx)
                    y = top + int(point[1] * sy)
                    log(f"[target] (pyautogui) {label}")
                    log(f"  [ocr] {shown}")
                    return _click(hwnd, x, y, "Yes", False)
        if choice is None and _completion_line(lines) is not None:
            heading = _completion_line(lines)
            sy_img = image.height / max(1, ocr_image.height)
            point = _blue_button(image, int((heading.y + heading.h) * sy_img))
            if point is not None:
                sx = width / max(1, image.width)
                sy = height / max(1, image.height)
                x = left + int(point[0] * sx)
                y = top + int(point[1] * sy)
                log(f"[target] (pyautogui) {label}")
                log(f"  [ocr] {shown}")
                return _click(hwnd, x, y, "Done", False)
        # A progress readout has nothing to click. Enhancing it only slows the watcher.
        progress_only = bool(re.search(r"uninstalling", blob, re.IGNORECASE)) and not _CONFIRM_RE.search(blob)
        if choice is None and not enhanced and not progress_only:
            nxt = _enhance_for_ocr(image)
            if nxt is not None:
                _log_once(
                    f"enhance:{hwnd}:{shown}",
                    "[ui] no button read, retrying OCR on an enlarged contrast-enhanced image",
                )
                ocr_image = nxt
                enhanced = True
                continue
        if choice is None:
            if structural or uac or _RELATED_TEXT_RE.search(blob):
                _log_once(f"miss:{hwnd}:{shown}", f"[ocr] ({label}) {shown}")
            return False
        break

    key = (hwnd, choice.text)
    count = _click_counts.get(key, 0)
    if count >= _MAX_CLICKS:
        _log_once(f"cap:{hwnd}:{choice.text}", f"[ui] stopped retrying '{choice.text}' on {label}")
        return False
    _click_counts[key] = count + 1

    x = left + choice.x + choice.w // 2
    y = top + choice.y + choice.h // 2
    log(f"[target] (pyautogui) {label}")
    log(f"  [ocr] {shown}")
    return _click(hwnd, x, y, choice.text, uac)


def _capture_baseline() -> Set[int]:
    return {hwnd for hwnd, _t, _c, _p in _enum_top_windows()}


def watch_loop(timeout_s: int = 0) -> None:
    log(f"[ui] watching for uninstall dialogs (PyAutoGUI) pid={os.getpid()}")
    baseline = _capture_baseline()
    start = time.time()
    while True:
        if timeout_s and (time.time() - start) >= timeout_s:
            log("[timeout] reached UI automation timeout.")
            return
        hit = False
        for hwnd, title, cls, pid in _enum_top_windows():
            try:
                if _handle_window(hwnd, title, cls, pid, baseline):
                    hit = True
                    break
            except Exception as ex:
                log(f"[ui] {ex}")
        time.sleep(0.8 if hit else 0.45)


def main() -> int:
    global _LOG_PATH, _APP_NAME, _IGNORE_PID, _CLOSE_CHROME, _FILL_OTHER

    ap = argparse.ArgumentParser(description="Click uninstall buttons with PyAutoGUI and Windows OCR.")
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--timeout", type=int, default=0)
    ap.add_argument("--app-name", default="")
    ap.add_argument("--log", default="")
    ap.add_argument("--ignore-pid", type=int, default=0)
    ap.add_argument("--close-chrome", action="store_true")
    ap.add_argument("--fill-other", action="store_true")
    args = ap.parse_args()

    _APP_NAME = args.app_name or ""
    _LOG_PATH = args.log or None
    _IGNORE_PID = args.ignore_pid or 0
    _CLOSE_CHROME = bool(args.close_chrome)
    _FILL_OTHER = bool(args.fill_other)
    if _LOG_PATH:
        parent = os.path.dirname(_LOG_PATH)
        if parent:
            os.makedirs(parent, exist_ok=True)

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
