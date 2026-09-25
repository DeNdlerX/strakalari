import os
import sys
from xml.sax.saxutils import escape as _xml_escape

APP_NAME = "Strakalari"


def _launch_argv(minimized: bool = True) -> list:
    """Launch command as an argv list (single source of truth)."""
    args = ["--minimized"] if minimized else []
    if getattr(sys, "frozen", False):
        return [sys.executable, *args]
    else:
        # Running from source - launch main.py for Desktop GUI & System Tray.
        # On Windows prefer pythonw.exe (no console flash at login).
        project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        main_script = os.path.join(project_root, "main.py")
        exe = sys.executable
        if sys.platform == "win32" and exe.lower().endswith("python.exe"):
            exe = exe[: -len("python.exe")] + "pythonw.exe"
        return [exe, main_script, *args]


def get_launch_command(minimized: bool = True) -> str:
    """Generates the appropriate launch command for startup execution."""
    argv = _launch_argv(minimized)
    # Windows registry Run values and freedesktop Exec lines both need
    # double-quoted paths with spaces (shlex single-quotes are NOT parsed
    # by desktop-file parsers, so shlex.join would break them).
    return " ".join(f'"{a}"' if (" " in a or "\t" in a) and not (a.startswith('"') and a.endswith('"')) else a
                    for a in argv)


def _startup_shortcut_path() -> str:
    """Path of the legacy Startup-folder shortcut created by older installers.

    Older installers created a ``{userstartup}`` shortcut while the app
    reads the HKCU Run value, so the shortcut still counts as "enabled"
    (and is adopted on the next toggle).
    """
    base = os.environ.get("APPDATA") or os.path.expanduser("~")
    return os.path.join(
        base, "Microsoft", "Windows", "Start Menu", "Programs", "Startup",
        f"{APP_NAME}.lnk",
    )


def _remove_legacy_shortcut() -> None:
    """Best-effort removal of the legacy Startup-folder shortcut."""
    try:
        path = _startup_shortcut_path()
        if os.path.exists(path):
            os.remove(path)
    except Exception:
        pass


def is_autostart_enabled() -> bool:
    """Checks whether autostart on system boot is enabled."""
    if sys.platform == "win32":
        try:
            import winreg
            key = winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Run",
                0,
                winreg.KEY_READ,
            )
            try:
                winreg.QueryValueEx(key, APP_NAME)
                winreg.CloseKey(key)
                return True
            except FileNotFoundError:
                winreg.CloseKey(key)
            except Exception:
                try:
                    winreg.CloseKey(key)
                except Exception:
                    pass
                return False
        except Exception:
            pass
        # Fall through: no Run value — an older installer may have left
        # a Startup-folder shortcut behind, which launches the app too.
        try:
            return os.path.exists(_startup_shortcut_path())
        except Exception:
            return False

    elif sys.platform == "darwin":
        plist_path = os.path.expanduser("~/Library/LaunchAgents/cz.strakalari.app.plist")
        return os.path.exists(plist_path)

    else:
        # Linux
        desktop_file = os.path.expanduser(f"~/.config/autostart/{APP_NAME.lower()}.desktop")
        return os.path.exists(desktop_file)


def set_autostart(enabled: bool, minimized: bool = True) -> bool:
    """Enables or disables autostart on system boot."""
    if sys.platform == "win32":
        try:
            import winreg
            key = winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Run",
                0,
                winreg.KEY_SET_VALUE,
            )
            try:
                if enabled:
                    cmd = get_launch_command(minimized)
                    winreg.SetValueEx(key, APP_NAME, 0, winreg.REG_SZ, cmd)
                else:
                    try:
                        winreg.DeleteValue(key, APP_NAME)
                    except FileNotFoundError:
                        pass
            finally:
                winreg.CloseKey(key)
            # Adopt the legacy installer shortcut: from now on the Run value
            # above is the single source of truth, so the shortcut must go —
            # otherwise the app would launch twice (or keep launching after
            # the user switched autostart off).
            _remove_legacy_shortcut()
            return True
        except Exception as e:
            print(f"Warning: Could not update Windows startup registry: {e}")
            return False

    elif sys.platform == "darwin":
        plist_dir = os.path.expanduser("~/Library/LaunchAgents")
        plist_path = os.path.join(plist_dir, "cz.strakalari.app.plist")
        if enabled:
            os.makedirs(plist_dir, exist_ok=True)
            if getattr(sys, "frozen", False):
                prog_args = [sys.executable]
            else:
                project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
                prog_args = [sys.executable, os.path.join(project_root, "main.py")]
            if minimized:
                prog_args.append("--minimized")

            args_xml = "\n        ".join(f"<string>{_xml_escape(a)}</string>" for a in prog_args)
            plist_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>cz.strakalari.app</string>
    <key>ProgramArguments</key>
    <array>
        {args_xml}
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
"""
            try:
                with open(plist_path, "w", encoding="utf-8") as f:
                    f.write(plist_content)
                return True
            except Exception as e:
                print(f"Warning: Could not create macOS launch agent: {e}")
                return False
        else:
            if os.path.exists(plist_path):
                try:
                    os.remove(plist_path)
                    return True
                except Exception:
                    return False
            return True

    else:
        # Linux
        autostart_dir = os.path.expanduser("~/.config/autostart")
        desktop_path = os.path.join(autostart_dir, f"{APP_NAME.lower()}.desktop")
        if enabled:
            os.makedirs(autostart_dir, exist_ok=True)
            cmd = get_launch_command(minimized)
            desktop_content = f"""[Desktop Entry]
Type=Application
Version=1.0
Name=Strakaláři
Comment=Automated school absence excusing and food ordering
Exec={cmd}
Terminal=false
Categories=Utility;Education;
"""
            try:
                with open(desktop_path, "w", encoding="utf-8") as f:
                    f.write(desktop_content)
                return True
            except Exception as e:
                print(f"Warning: Could not create Linux autostart desktop entry: {e}")
                return False
        else:
            if os.path.exists(desktop_path):
                try:
                    os.remove(desktop_path)
                    return True
                except Exception:
                    return False
            return True
