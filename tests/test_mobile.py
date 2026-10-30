"""The phone app: platform layer, narrow layout, Back button, build tool."""
import importlib.util
import sys
import zipfile
from pathlib import Path

import flet as ft
import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture()
def android(monkeypatch):
    monkeypatch.setenv("FLET_PLATFORM", "android")


class TestPlatform:
    def test_desktop_is_not_mobile(self, monkeypatch):
        from strakalari.core.packaging import is_mobile, mobile_platform

        monkeypatch.delenv("FLET_PLATFORM", raising=False)
        assert mobile_platform() is None and not is_mobile()

    @pytest.mark.parametrize("value", ["android", "ios", "IOS "])
    def test_flet_platform_env(self, monkeypatch, value):
        from strakalari.core.packaging import is_mobile, mobile_platform

        monkeypatch.setenv("FLET_PLATFORM", value)
        assert mobile_platform() == value.strip().lower() and is_mobile()

    def test_desktop_flet_build_is_not_mobile(self, monkeypatch):
        from strakalari.core.packaging import is_mobile

        monkeypatch.setenv("FLET_PLATFORM", "windows")
        assert not is_mobile()

    def test_sys_platform(self, monkeypatch):
        from strakalari.core.packaging import mobile_platform

        monkeypatch.delenv("FLET_PLATFORM", raising=False)
        monkeypatch.setattr(sys, "platform", "android")
        assert mobile_platform() == "android"


class TestDataDir:
    def test_app_storage(self, monkeypatch, tmp_path, android):
        from strakalari.core.helpers import get_user_data_dir

        target = tmp_path / "app" / "data"
        monkeypatch.delenv("STRAKALARI_DATA_DIR", raising=False)
        monkeypatch.setenv("FLET_APP_STORAGE_DATA", str(target))
        assert get_user_data_dir() == str(target)
        assert target.is_dir()

    def test_override_still_wins(self, monkeypatch, tmp_path, android):
        from strakalari.core.helpers import get_user_data_dir

        monkeypatch.setenv("STRAKALARI_DATA_DIR", str(tmp_path / "x"))
        monkeypatch.setenv("FLET_APP_STORAGE_DATA", str(tmp_path / "y"))
        assert get_user_data_dir() == str(tmp_path / "x")


class TestEntry:
    def test_main_routes_to_mobile(self, monkeypatch, android):
        import main as entry
        import strakalari.flet_ui.app as app

        calls = []
        monkeypatch.setattr(app, "run_mobile", lambda: calls.append("mobile"))
        monkeypatch.setattr(app, "run", lambda: calls.append("desktop"))
        monkeypatch.setattr(sys, "argv", ["main.py", "--minimized"])
        entry.main()
        assert calls == ["mobile"]


@pytest.mark.parametrize("platform, channel, managed", [
    ("android", None, False),      # dev run / no marker: like the GitHub APK
    ("android", "github", False),  # sideloaded APK: checks GitHub releases
    ("android", "play", True),     # Google Play updates it
    ("ios", None, True),           # App Store only
])
def test_update_check_per_distribution(monkeypatch, platform, channel, managed):
    import types

    from strakalari.core.update import updates_managed_externally

    monkeypatch.setenv("FLET_PLATFORM", platform)
    if channel is not None:
        module = types.ModuleType("strakalari.core._distribution")
        module.CHANNEL = channel
        monkeypatch.setitem(sys.modules, "strakalari.core._distribution", module)
    assert updates_managed_externally() is managed


def test_repo_has_no_distribution_marker():
    # Only staged builds carry it; a stray copy would turn off update checks.
    assert not (ROOT / "strakalari" / "core" / "_distribution.py").exists()


def test_mobile_wording(monkeypatch):
    from strakalari.core.i18n import set_language
    from strakalari.flet_ui.strings import MOBILE_STRINGS, STRINGS, S

    set_language("cs")
    monkeypatch.delenv("FLET_PLATFORM", raising=False)
    assert "počítači" in S("wiz_disclaimer_p")
    monkeypatch.setenv("FLET_PLATFORM", "android")
    assert "telefonu" in S("wiz_disclaimer_p")
    for key, entry in MOBILE_STRINGS.items():
        assert key in STRINGS and entry.get("cs") and entry.get("en"), key


@pytest.mark.parametrize("platform, shown", [
    (None, True),        # desktop: autostart / tray, notifications
    ("android", True),   # background running, notifications
    ("ios", False),      # neither yet
])
def test_settings_sections_per_platform(monkeypatch, platform, shown):
    from strakalari.flet_ui.views.settings.view import _sections_here

    monkeypatch.delenv("FLET_PLATFORM", raising=False)
    if platform:
        monkeypatch.setenv("FLET_PLATFORM", platform)
    assert ({"browser", "notifications"} <= _sections_here()) is shown


# -- Android: notifications, key storage, background running --------------------------------
class FakeKeystore:
    """Stands in for core.android's Keystore helpers (XOR with a device key)."""

    def __init__(self, broken_unwrap=False, broken_wrap=False):
        self.secret = b"device-bound-key-0123456789abcdef"
        self.broken_unwrap, self.broken_wrap = broken_unwrap, broken_wrap

    def available(self):
        return True

    def _xor(self, data):
        return bytes(b ^ self.secret[i % len(self.secret)] for i, b in enumerate(data))

    def keystore_wrap(self, data):
        if self.broken_wrap:
            raise RuntimeError("keystore busy")
        return b"\x01" * 12 + self._xor(data)

    def keystore_unwrap(self, blob):
        if self.broken_unwrap:
            raise RuntimeError("key permanently invalidated")
        return self._xor(blob[12:])


@pytest.fixture()
def keystore(monkeypatch, tmp_path):
    from strakalari.core import secret_store

    fake = FakeKeystore()
    monkeypatch.setattr(secret_store, "_android_keystore", lambda: fake)
    secret_store.clear_cache()
    yield fake, tmp_path
    secret_store.clear_cache()


class TestKeystoreKey:
    def test_fresh_install_keeps_only_the_wrapped_key(self, keystore):
        from cryptography.fernet import Fernet

        from strakalari.core import secret_store

        fake, data = keystore
        key = secret_store.get_key(str(data))
        Fernet(key)  # a usable key
        assert not (data / "secret.key").exists()
        assert (data / "secret.key.wrapped").exists()
        secret_store.clear_cache()
        assert secret_store.get_key(str(data)) == key  # unwrapped again
        assert secret_store.storage_location(str(data)) == "keystore"

    def test_plain_key_from_an_older_build_is_migrated(self, keystore):
        from cryptography.fernet import Fernet

        from strakalari.core import secret_store

        fake, data = keystore
        old = Fernet.generate_key()
        (data / "secret.key").write_bytes(old)
        assert secret_store.get_key(str(data)) == old  # passwords stay readable
        assert not (data / "secret.key").exists()
        secret_store.clear_cache()
        assert secret_store.get_key(str(data)) == old

    def test_lost_keystore_key_quarantines_and_starts_over(self, keystore):
        from strakalari.core import secret_store

        fake, data = keystore
        first = secret_store.get_key(str(data))
        secret_store.clear_cache()
        fake.broken_unwrap = True
        fake.broken_wrap = True  # and the Keystore refuses new keys too
        second = secret_store.get_key(str(data))
        assert second != first
        assert list(data.glob("secret.key.wrapped.corrupt-*"))
        assert (data / "secret.key").exists()  # the plain fallback

    def test_forget_removes_the_wrapped_key(self, keystore):
        from strakalari.core import secret_store

        fake, data = keystore
        secret_store.get_key(str(data))
        assert secret_store.forget_key(str(data))
        assert not (data / "secret.key.wrapped").exists() and not (data / "secret.key").exists()


def test_notifications_go_through_android(monkeypatch):
    from strakalari.core import android, notify

    sent = []
    monkeypatch.setenv("FLET_PLATFORM", "android")
    monkeypatch.setattr(android, "notify", lambda title, text, channel: sent.append(text) or True)
    assert notify.notify("excuse_sent", "Omluvenka odeslána") is True
    assert sent == ["Omluvenka odeslána"]
    monkeypatch.setenv("FLET_PLATFORM", "ios")  # no backend yet: printed, not sent
    assert notify.notify("excuse_sent", "x") is False


def test_android_helpers_are_noops_off_android(monkeypatch):
    from strakalari.core import android

    monkeypatch.delenv("FLET_PLATFORM", raising=False)
    assert not android.available() and android.context() is None
    assert android.notify("t", "x", "c") is False
    assert android.start_background({}) is False and android.schedule_wake(0) is False
    with android.KeepAwake(minutes=1):
        pass


class TestPhoneBackground:
    def _wire(self, monkeypatch, app_state, on=True):
        from strakalari.core import android
        from strakalari.core.scheduler import PeriodicRunner
        from strakalari.flet_ui import app

        calls = []
        monkeypatch.setattr(android, "available", lambda: True)
        monkeypatch.setattr(android, "context", lambda: object())
        monkeypatch.setattr(android, "request_notification_permission",
                            lambda: calls.append("ask"))
        monkeypatch.setattr(android, "start_background", lambda texts: calls.append(texts))
        monkeypatch.setattr(android, "stop_background", lambda: calls.append("stop"))
        monkeypatch.setattr(android, "schedule_wake", lambda at: calls.append(("wake", at)))
        app_state.wizard_dismissed = True
        app_state.save({"run_in_background": on, "check_interval_minutes": 30})
        runner = PeriodicRunner(interval_minutes=30)
        app._setup_phone_background(app_state, runner)
        return calls, runner

    def test_starts_service_with_texts_and_wake_up(self, monkeypatch, app_state):
        calls, runner = self._wire(monkeypatch, app_state)
        texts = next(c for c in calls if isinstance(c, dict))
        assert "30" in texts["text"] and texts["boot_text"] and texts["channel"]
        assert "ask" in calls and any(isinstance(c, tuple) for c in calls)

    def test_switching_off_stops_and_on_restarts(self, monkeypatch, app_state):
        calls, runner = self._wire(monkeypatch, app_state)
        calls.clear()
        app_state.save({"run_in_background": False})
        assert calls == ["stop"]
        app_state.save({"theme": "dark"})  # unrelated save: nothing happens
        assert calls == ["stop"]
        app_state.save({"run_in_background": True})
        assert any(isinstance(c, dict) for c in calls)

    def test_every_run_sets_the_next_wake_up(self, monkeypatch, app_state):
        calls, runner = self._wire(monkeypatch, app_state)
        calls.clear()
        runner.add_job("refresh", lambda: "ok")
        runner._run_all_once()
        assert [c for c in calls if isinstance(c, tuple)]


def test_scheduler_holds_runs_while_paused(monkeypatch):
    from strakalari.core import scheduler

    ran = []
    hidden = {"value": True}
    runner = scheduler.PeriodicRunner(interval_minutes=60, paused=lambda: hidden["value"])
    runner.add_job("refresh", lambda: ran.append(1))
    ticks = iter(range(4))

    class FakeStop:
        def wait(self, timeout):
            n = next(ticks, None)
            if n == 2:
                hidden["value"] = False  # the app came back
            return n is None

        def is_set(self):
            return False

    monkeypatch.setattr(runner, "_stop", FakeStop())
    runner._loop()
    assert ran == [1]  # held twice, then the overdue run fired once


# -- narrow (phone) layout ------------------------------------------------------------------
class FakePage:
    def __init__(self, width=390):
        self.width, self.height = width, 844
        self.controls, self.overlay = [], []
        self.bgcolor = self.theme_mode = None
        self.navigation_bar = None
        self.views = [ft.View()]

    def add(self, *controls):
        self.controls.extend(controls)

    def update(self):
        pass


@pytest.fixture()
def shell(app_state):
    from strakalari.flet_ui.app import Shell

    app_state.wizard_dismissed = True
    app_state.set_tutorials_enabled(False)
    return Shell(FakePage(), app_state)


class TestNarrowShell:
    def test_bottom_bar_instead_of_rail(self, shell):
        shell.render()
        assert shell.state.narrow
        assert shell.page.navigation_bar is shell.nav_bar
        assert isinstance(shell.page.controls[0], ft.SafeArea)
        # The bar covers the gesture area: no second inset above it.
        area = shell.page.controls[0]
        assert area.avoid_intrusions_bottom is False
        # Not positioned: left/top/right/bottom only work inside a Stack
        # (set elsewhere, Flutter can't lay the page out: grey screen).
        assert (area.left, area.top, area.right, area.bottom) == (None, None, None, None)

    def test_refresh_ticks_repaint_only_the_topbar(self, shell, monkeypatch):
        shell.go("timetable")
        built = []
        monkeypatch.setattr(shell, "_render_inner", lambda: built.append(shell.route))
        shell.state.refresh_running = True
        shell.render_progress()
        assert built == []  # the grid is left alone while the refresh runs
        shell.route = shell._last_built_route = "activity"
        shell.render_progress()
        assert built == ["activity"]  # the live log still updates
        shell.state.refresh_running = False

    def test_wide_page_keeps_the_rail(self, shell):
        shell.page.width = 1240
        shell.render()
        assert not shell.state.narrow and shell.page.navigation_bar is None
        assert shell.page.controls[0].controls[0] is shell.rail

    def test_more_screens_select_more(self, shell):
        shell.render()
        shell.go("settings")
        assert shell.nav_bar.selected_index == 4
        shell.go("marks")
        assert shell.nav_bar.selected_index == 2

    def test_landscape_phone_gets_side_rail(self, shell):
        shell.page.width, shell.page.height = 915, 411
        shell.render()
        assert shell.state.narrow and shell.state.nav_side
        assert shell.page.navigation_bar is None
        row = shell.page.controls[0]
        rail_frame = row.controls[0]
        assert rail_frame.content.content is shell.side_rail  # inside its SafeArea
        assert rail_frame.bgcolor == shell.state.tok.surface  # the inset is rail-colored
        for area in (rail_frame.content, row.controls[2]):
            assert (area.left, area.top, area.right, area.bottom) == (None,) * 4
        shell.go("planner")
        assert shell.side_rail.selected_index == 4  # More

    def test_rotating_swaps_bar_and_side_rail(self, shell):
        shell.render()
        assert shell.page.navigation_bar is shell.nav_bar
        shell.page.width, shell.page.height = 844, 390
        shell.on_resize()
        assert shell.page.navigation_bar is None and shell._layout == "side"
        shell.page.width, shell.page.height = 390, 844
        shell.on_resize()
        assert shell.page.navigation_bar is shell.nav_bar and shell._layout == "bar"

    @pytest.mark.parametrize("size, layout", [
        ((390, 844), "bar"), ((844, 390), "side"),    # phone
        ((600, 960), "bar"), ((960, 600), "wide"),    # small tablet
        ((768, 1024), "wide"), ((1024, 768), "wide"),  # iPad
        ((1240, 800), "wide"),                         # desktop window
    ])
    def test_layout_by_size(self, size, layout):
        from strakalari.flet_ui.app import layout_for

        page = FakePage()
        page.width, page.height = size
        assert layout_for(page) == layout

    def test_phone_timetable_grid_scrolls_sideways(self, shell):
        from strakalari.flet_ui.views import timetable as tt

        lessons = [{"time": f"{p} (8:00 - 8:45)", "subject": f"Předmět {p}"} for p in range(1, 9)]
        week = {tt.date(2026, 10, 12): lessons}
        shell.state.narrow = True
        grid = tt._table_view(shell.state, shell.page, week, tt._day_names())
        gutter, scroller = grid.controls
        assert scroller.scroll == ft.ScrollMode.AUTO  # 8 periods don't fit 390 px
        header = scroller.controls[0].controls[0].content.controls
        assert len(header) == 8 and all(h.width == tt.PHONE_CELL_MIN_W for h in header)
        shell.page.width = 915  # landscape: cells grow to fill the width instead
        wide = tt._table_view(shell.state, shell.page, week, tt._day_names())
        assert wide.controls[1].controls[0].controls[0].content.controls[0].width > \
            tt.PHONE_CELL_MIN_W

    def test_widening_leaves_more(self, shell):
        shell.go("more")
        shell.page.width = 1240
        shell.on_resize()
        assert shell.route == "today" and shell.page.navigation_bar is None

    @pytest.mark.parametrize("route", ["today", "timetable", "absences", "marks", "planner",
                                       "lunches", "activity", "settings", "more"])
    def test_every_screen_builds(self, shell, route):
        reports = []
        shell.state.report_error = lambda where, exc: reports.append((where, exc))
        shell.go(route)
        assert reports == []

    def test_back_steps_up(self, shell):
        shell.enable_back_navigation()
        shell.render()
        assert shell.back_target() is None and shell.page.views[0].can_pop
        shell.go("planner")
        assert shell.back_target() == "more" and not shell.page.views[0].can_pop
        shell.go("more")
        assert shell.back_target() == "today"

    def test_back_closes_open_settings_section_first(self, shell):
        shell.enable_back_navigation()
        shell.go("settings")
        shell.state.set_settings_section("accounts")
        assert shell._subpage_open() == "settings"
        shell._close_subpage()
        assert not shell.state.settings_open and shell.route == "settings"


# -- build tool ------------------------------------------------------------------------------
def _make_mobile():
    spec = importlib.util.spec_from_file_location("make_mobile", ROOT / "tools" / "make_mobile.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestMakeMobile:
    def test_build_numbers_grow(self):
        mm = _make_mobile()
        order = ["0.1.3", "0.2.0-alpha.3", "0.2.0-beta.1", "0.2.0-beta.2", "0.2.0-rc.1",
                 "0.2.0", "1.0.0"]
        numbers = [mm.build_number(v) for v in order]
        assert numbers == sorted(numbers) and len(set(numbers)) == len(numbers)

    def test_pep440(self):
        mm = _make_mobile()
        assert mm.pep440("0.2.0-beta.1") == "0.2.0b1" and mm.pep440("0.1.3") == "0.1.3"

    def test_flet_pin_matches_desktop(self):
        text = (ROOT / "requirements.txt").read_text(encoding="utf-8")
        assert f"flet=={_make_mobile().FLET_VERSION}" in text

    def test_stage_has_no_personal_files(self, monkeypatch, tmp_path):
        mm = _make_mobile()
        monkeypatch.setattr(mm, "STAGE", str(tmp_path / "stage"))
        mm.stage("1.2.3")
        stage = tmp_path / "stage"
        assert (stage / "main.py").is_file() and (stage / "assets" / "icon.png").is_file()
        init = (stage / "strakalari" / "__init__.py").read_text(encoding="utf-8")
        assert '__version__ = "1.2.3"' in init
        pyproject = (stage / "pyproject.toml").read_text(encoding="utf-8")
        assert 'bundle_id = "io.github.dendlerx.strakalari"' in pyproject
        assert 'allowBackup = "false"' in pyproject  # secret.key stays off cloud backups
        assert not list(stage.rglob("__pycache__"))
        assert not [p for p in stage.rglob("*") if mm.PERSONAL.search(str(p.relative_to(stage)))]
        marker = stage / "strakalari" / "core" / "_distribution.py"
        assert 'CHANNEL = "github"' in marker.read_text(encoding="utf-8")
        mm.stage("1.2.3", channel="play")
        assert 'CHANNEL = "play"' in marker.read_text(encoding="utf-8")

    def test_signing_from_properties_file(self, monkeypatch, tmp_path):
        mm = _make_mobile()
        monkeypatch.delenv("FLET_ANDROID_SIGNING_KEY_STORE", raising=False)
        (tmp_path / "release.jks").write_bytes(b"x")
        props = tmp_path / "release.properties"
        props.write_text("# comment\nstoreFile=release.jks\nstorePassword=s3cret\n"
                         "keyAlias=upload\n", encoding="utf-8")
        env = mm.signing_env(str(props))
        assert env["FLET_ANDROID_SIGNING_KEY_STORE"] == str(tmp_path / "release.jks")
        assert env["FLET_ANDROID_SIGNING_KEY_PASSWORD"] == "s3cret"  # PKCS12: one password
        assert env["FLET_ANDROID_SIGNING_KEY_ALIAS"] == "upload"

    def test_signing_absent_or_from_ci(self, monkeypatch, tmp_path):
        mm = _make_mobile()
        monkeypatch.delenv("FLET_ANDROID_SIGNING_KEY_STORE", raising=False)
        assert mm.signing_env(str(tmp_path / "missing.properties")) is None
        monkeypatch.setenv("FLET_ANDROID_SIGNING_KEY_STORE", "/ci/key.jks")
        assert mm.signing_env(str(tmp_path / "missing.properties")) == {}

    def test_extension_wheel(self, tmp_path):
        mm = _make_mobile()
        path = mm.extension_wheel(str(tmp_path))
        with zipfile.ZipFile(path) as zf:
            names = zf.namelist()
            record = zf.read(next(n for n in names if n.endswith("/RECORD"))).decode()
        for needed in ("flutter/strakalari_android/pubspec.yaml",
                       "flutter/strakalari_android/lib/strakalari_android.dart",
                       "flutter/strakalari_android/android/src/main/AndroidManifest.xml",
                       "strakalari_android/__init__.py"):
            assert needed in names and needed in record
        assert not [n for n in names if "__pycache__" in n or n.endswith(".pyc")]
        # Same content, same version: flet's package cache stays valid.
        assert Path(mm.extension_wheel(str(tmp_path / "again"))).name == Path(path).name

    def test_r8_keeps_the_classes_python_calls(self):
        # Release builds shrink Java code; pyjnius looks the classes up by
        # name, and a stripped one aborts the whole app on first use.
        android = ROOT / "mobile" / "strakalari_android" / "flutter" / "strakalari_android" / "android"
        from strakalari.core.android import JAVA_PACKAGE

        assert f"-keep class {JAVA_PACKAGE}.** {{ *; }}" in (
            android / "consumer-rules.pro").read_text(encoding="utf-8")
        assert "consumerProguardFiles 'consumer-rules.pro'" in (
            android / "build.gradle").read_text(encoding="utf-8")

    def test_package_check_finds_nested_personal_file(self, tmp_path):
        mm = _make_mobile()
        inner = tmp_path / "app.zip"
        with zipfile.ZipFile(inner, "w") as zf:
            zf.writestr("config.json", "{}")
        apk = tmp_path / "app.apk"
        with zipfile.ZipFile(apk, "w") as zf:
            zf.write(inner, "assets/app.zip")
        with pytest.raises(SystemExit):
            mm.check_package(str(apk))


# -- Android: the Clock app shortcut ------------------------------------------------------------
class _FakeBundle:
    """Records the typed puts (``putInt`` / ``putString`` / ``putBoolean``)."""

    def __init__(self):
        self.values = {}

    def putInt(self, key, value):
        self.values[key] = ("int", value)

    def putString(self, key, value):
        self.values[key] = ("str", value)

    def putBoolean(self, key, value):
        self.values[key] = ("bool", value)

    def putIntegerArrayList(self, key, value):
        self.values[key] = ("int_list", list(value))


class _FakeIntent:
    FLAG_ACTIVITY_NEW_TASK = 0x10000000

    def __init__(self, action):
        self.action, self.extras, self.flags = action, None, 0

    def putExtras(self, bundle):
        self.extras = bundle

    def addFlags(self, flags):
        self.flags |= flags


class _FakeList(list):
    def add(self, value):
        self.append(value)


class _FakeInteger:
    @staticmethod
    def valueOf(value):
        return ("Integer", value)


class _FakeAlarmClock:
    EXTRA_DAYS = "android.intent.extra.alarm.DAYS"
    ACTION_SET_ALARM = "android.intent.action.SET_ALARM"
    ACTION_SHOW_ALARMS = "android.intent.action.SHOW_ALARMS"
    EXTRA_HOUR = "android.intent.extra.alarm.HOUR"
    EXTRA_MINUTES = "android.intent.extra.alarm.MINUTES"
    EXTRA_MESSAGE = "android.intent.extra.alarm.MESSAGE"
    EXTRA_SKIP_UI = "android.intent.extra.alarm.SKIP_UI"


@pytest.mark.parametrize("set_alarm_works", [True, False])
def test_open_system_alarm_sends_typed_extras(monkeypatch, set_alarm_works):
    from strakalari.core import android

    started = []

    class _Ctx:
        def startActivity(self, intent):
            if intent.action == _FakeAlarmClock.ACTION_SET_ALARM and not set_alarm_works:
                raise RuntimeError("ActivityNotFoundException")
            started.append(intent)

    classes = {"android.provider.AlarmClock": _FakeAlarmClock,
               "android.content.Intent": _FakeIntent,
               "android.os.Bundle": _FakeBundle}
    monkeypatch.setattr(android, "context", lambda: _Ctx())
    monkeypatch.setattr(android, "_autoclass", lambda name: classes[name])

    assert android.open_system_alarm(6, 45, "Strakaláři · Matematika") is True
    (intent,) = started
    assert intent.flags & _FakeIntent.FLAG_ACTIVITY_NEW_TASK
    if set_alarm_works:
        assert intent.action == _FakeAlarmClock.ACTION_SET_ALARM
        assert intent.extras.values == {
            _FakeAlarmClock.EXTRA_HOUR: ("int", 6),
            _FakeAlarmClock.EXTRA_MINUTES: ("int", 45),
            _FakeAlarmClock.EXTRA_MESSAGE: ("str", "Strakaláři · Matematika"),
            _FakeAlarmClock.EXTRA_SKIP_UI: ("bool", False),
        }
    else:  # no app takes a new alarm: at least the alarm list opens
        assert intent.action == _FakeAlarmClock.ACTION_SHOW_ALARMS and intent.extras is None


def test_open_system_alarm_weekday_becomes_clock_days(monkeypatch):
    """Monday (0) goes to the Clock app as java.util.Calendar.MONDAY (2)."""
    from strakalari.core import android

    started = []
    classes = {"android.provider.AlarmClock": _FakeAlarmClock,
               "android.content.Intent": _FakeIntent,
               "android.os.Bundle": _FakeBundle,
               "java.util.ArrayList": _FakeList,
               "java.lang.Integer": _FakeInteger}
    monkeypatch.setattr(android, "context",
                        lambda: type("Ctx", (), {"startActivity": lambda self, i: started.append(i)})())
    monkeypatch.setattr(android, "_autoclass", lambda name: classes[name])

    assert android.open_system_alarm(7, 0, "x", weekday=0) is True
    assert started[0].extras.values[_FakeAlarmClock.EXTRA_DAYS] == ("int_list", [("Integer", 2)])
    started.clear()
    assert android.open_system_alarm(7, 0, "x", weekday=6) is True  # Sunday
    assert started[0].extras.values[_FakeAlarmClock.EXTRA_DAYS] == ("int_list", [("Integer", 1)])
    started.clear()
    assert android.open_system_alarm(7, 0, "x") is True
    assert _FakeAlarmClock.EXTRA_DAYS not in started[0].extras.values
