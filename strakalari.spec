# -*- mode: python ; coding: utf-8 -*-
import sys
import os
from PyInstaller.utils.hooks import collect_all


def _app_version() -> str:
    """Single source: strakalari.__version__, overridable via STRAKALARI_VERSION.

    CI stamps the release version (tag v1.2.3 -> 1.2.3) before building so
    the frozen app and the macOS bundle report the real release.
    """
    env = os.environ.get("STRAKALARI_VERSION", "").strip().lstrip("vV")
    if env:
        return env
    try:
        sys.path.insert(0, os.path.abspath("."))
        from strakalari import __version__ as pkg_version

        return str(pkg_version).strip().lstrip("vV") or "0.0.1"
    except Exception:
        return "0.0.1"


APP_VERSION = _app_version()


def _version_tuple():
    """APP_VERSION -> (major, minor, patch, build) ints for Win32 resources.

    Only the numeric core counts: '0.1.0-beta.1' -> (0, 1, 0, 0), so a
    pre-release suffix never leaks into the build field.
    """
    parts = []
    core = str(APP_VERSION).split("-", 1)[0].split("+", 1)[0]
    for bit in core.split("."):
        digits = ""
        for ch in bit:
            if not ch.isdigit():
                break
            digits += ch
        parts.append(int(digits) if digits else 0)
    while len(parts) < 4:
        parts.append(0)
    return tuple(parts[:4])


# Numeric 'X.Y.Z' for places that reject pre-release suffixes (macOS plist).
APP_VERSION_NUMERIC = "%d.%d.%d" % _version_tuple()[:3]


def _write_version_file():
    """Generates a Win32 version resource so Strakalari.exe shows a File
    version in Explorer. Returns the path, or None when it cannot be
    written (the EXE `version` param is Windows-only and ignored on
    Linux/macOS, so None is always safe)."""
    major, minor, patch, build = _version_tuple()
    ver_str = "%d.%d.%d.%d" % (major, minor, patch, build)
    content = (
        "VSVersionInfo(\n"
        "  ffi=FixedFileInfo(\n"
        "    filevers=(%d, %d, %d, %d),\n"
        "    prodvers=(%d, %d, %d, %d),\n"
        "    mask=0x3f,\n"
        "    flags=0x0,\n"
        "    OS=0x40004,\n"
        "    fileType=0x1,\n"
        "    subtype=0x0,\n"
        "    date=(0, 0)\n"
        "  ),\n"
        "  kids=[\n"
        "    StringFileInfo([\n"
        "      StringTable(\n"
        "        '040904B0',\n"
        "        [StringStruct('CompanyName', 'Strakaláři'),\n"
        "        StringStruct('FileDescription', 'Strakaláři'),\n"
        "        StringStruct('FileVersion', '%s'),\n"
        "        StringStruct('InternalName', 'Strakalari'),\n"
        "        StringStruct('OriginalFilename', 'Strakalari.exe'),\n"
        "        StringStruct('ProductName', 'Strakaláři'),\n"
        "        StringStruct('ProductVersion', '%s')])\n"
        "    ]),\n"
        "    VarFileInfo([VarStruct('Translation', [1033, 1200])])\n"
        "  ]\n"
        ")\n" % (major, minor, patch, build,
                  major, minor, patch, build, ver_str, ver_str)
    )
    try:
        out_dir = os.path.join(os.path.abspath("."), "build")
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, "strakalari-version-info.txt")
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(content)
        return out_path
    except Exception:
        return None


VERSION_FILE = _write_version_file()

block_cipher = None

# ---- Shared automation payload (Playwright + helpers) ----
# The frozen GUI bundles this plus the Flet desktop UI below.
base_datas = [
    ('config.example.json', '.'),
    ('strava_blacklist.example.json', '.'),
    ('already_excused_lessons.example.json', '.'),
]
base_binaries = []
base_hiddenimports = [
    'playwright',
    'playwright.sync_api',
    'cryptography',
    'plyer',
    # Explicit: nothing in app code imports certifi directly (TLS goes
    # through stdlib urllib), so without this PyInstaller would not bundle
    # its CA store and every frozen HTTPS call would fail verification.
    'certifi',
]

try:
    p_datas, p_binaries, p_hiddenimports = collect_all('playwright')
    base_datas += p_datas
    base_binaries += p_binaries
    base_hiddenimports += p_hiddenimports
except Exception:
    pass

try:
    c_datas, c_binaries, c_hiddenimports = collect_all('certifi')
    base_datas += c_datas
    base_binaries += c_binaries
    base_hiddenimports += c_hiddenimports
except Exception:
    pass

try:
    # keyring discovers its backends through entry points (Windows
    # Credential Manager, macOS Keychain, Secret Service): collect the
    # package + metadata or the frozen app silently falls back to
    # secret.key.
    k_datas, k_binaries, k_hiddenimports = collect_all('keyring')
    base_datas += k_datas
    base_binaries += k_binaries
    base_hiddenimports += k_hiddenimports + [
        'keyring.backends.Windows',
        'keyring.backends.macOS',
        'keyring.backends.SecretService',
        'keyring.backends.libsecret',
        'keyring.backends.chainer',
        'keyring.backends.fail',
        'keyring.backends.null',
        # Windows Credential Manager backend's ctypes binding.
        'win32ctypes.pywin32.win32cred',
        'win32ctypes.pywin32.pywintypes',
    ]
except Exception:
    pass

try:
    # plyer loads platform backends dynamically (plyer.platforms.*),
    # which a bare 'plyer' hiddenimport misses — collect everything so
    # the last-resort notifier survives freezing.
    pl_datas, pl_binaries, pl_hiddenimports = collect_all('plyer')
    base_datas += pl_datas
    base_binaries += pl_binaries
    base_hiddenimports += pl_hiddenimports
except Exception:
    pass

# ---- GUI-only payload (Flet desktop UI + tray) ----
# NOTE: flet_web (browser view, ~27 MB on disk) is deliberately excluded:
# the frozen GUI always opens a desktop window. flet_desktop IS bundled —
# without it the exe crashes on launch (it tries `pip install flet-desktop`
# with the frozen exe as interpreter, which fails).
gui_datas = base_datas + [('assets', 'assets')]
gui_binaries = list(base_binaries)
gui_hiddenimports = base_hiddenimports + [
    'flet',
    'pystray',
    'PIL',
    'PIL.Image',
    'PIL.ImageDraw',
]
if sys.platform == 'darwin':
    # pystray picks its backend at runtime; the macOS tray (menu bar icon,
    # reopen handler, main-thread calls) needs these PyObjC modules.
    gui_hiddenimports += [
        'pystray._darwin',
        'AppKit',
        'Foundation',
        'objc',
        'PyObjCTools.AppHelper',
        'PyObjCTools.MachSignals',
    ]

try:
    f_datas, f_binaries, f_hiddenimports = collect_all('flet')
    gui_datas += f_datas
    gui_binaries += f_binaries
    gui_hiddenimports += f_hiddenimports
except Exception:
    pass

try:
    d_datas, d_binaries, d_hiddenimports = collect_all('flet_desktop')
    gui_datas += d_datas
    gui_binaries += d_binaries
    gui_hiddenimports += d_hiddenimports
except Exception:
    pass

# 1. Main GUI Executable (windowed / no console popup)
a_gui = Analysis(
    ['main.py'],
    pathex=[],
    binaries=gui_binaries,
    datas=gui_datas,
    hiddenimports=gui_hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=['rthook_frozen_builtins.py'],
    excludes=['tkinter', 'test', 'unittest'],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz_gui = PYZ(a_gui.pure, a_gui.zipped_data, cipher=block_cipher)

# macOS ships an onedir .app: a onefile bundle is deprecated by PyInstaller
# (an error from v7), clashes with code signing, and re-extracts the whole
# payload on every launch, which the tray pays again for each window it
# opens. Windows and Linux stay onefile (installer / AppImage).
MAC_ONEDIR = sys.platform == 'darwin'

exe_gui = EXE(
    pyz_gui,
    a_gui.scripts,
    *([] if MAC_ONEDIR else [a_gui.binaries, a_gui.zipfiles, a_gui.datas]),
    [],
    exclude_binaries=MAC_ONEDIR,
    name='Strakalari',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    # NOTE: UPX stays off. It saves ~20-30% but its decompression +
    # re-extraction on every launch is slow under Defender (notably in
    # clean sandboxes/VMs), and packed binaries trip antivirus heuristics.
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,  # GUI: no black console window
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon='assets/icon.ico',
    version=VERSION_FILE,
)

# 2. macOS App Bundle wrapper (only active on macOS)
if MAC_ONEDIR:
    coll_gui = COLLECT(
        exe_gui,
        a_gui.binaries,
        a_gui.zipfiles,
        a_gui.datas,
        strip=False,
        upx=False,
        upx_exclude=[],
        name='Strakalari',
    )
    app = BUNDLE(
        coll_gui,
        name='Strakalari.app',
        icon='assets/icon.icns',
        bundle_identifier='cz.strakalari.app',
        info_plist={
            'CFBundleName': 'Strakalari',
            'CFBundleDisplayName': 'Strakaláři',
            'CFBundleIdentifier': 'cz.strakalari.app',
            'CFBundleVersion': APP_VERSION_NUMERIC,
            'CFBundleShortVersionString': APP_VERSION_NUMERIC,
            'NSHighResolutionCapable': 'True',
            # Menu-bar app: the tray process hosts the window (a Flet
            # client with its own Dock icon), see strakalari/flet_ui/macos.py.
            'LSUIElement': True,
        },
    )
