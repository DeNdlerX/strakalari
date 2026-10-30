"""Android system services for the phone app, called through pyjnius.

Everything here talks to Android directly from Python (no Flutter
channel), so it keeps working after the user closes the app's screen:
the process, and this Python with it, stays alive while the background
service (``mobile/strakalari_android``) runs.

Off Android (desktop, tests) every function is a harmless no-op that
reports failure; nothing imports ``jnius`` at module import time.
"""

from __future__ import annotations

import threading
import time
from typing import Any

#: The Java side, from the bundled extension (mobile/strakalari_android).
JAVA_PACKAGE = "io.github.dendlerx.strakalari.android"

#: Notification channels: automation events, and the ongoing "running in
#: the background" one (owned by KeepAliveService).
EVENTS_CHANNEL = "strakalari_events"

_lock = threading.Lock()
_context: Any = None


def _live_env(name: str) -> str:
    """An environment variable as the process has it now (Java's
    ``Os.setenv`` after Python started is invisible to ``os.environ``)."""
    try:
        import ctypes

        getenv = ctypes.CDLL(None).getenv
        getenv.restype = ctypes.c_char_p
        value = getenv(name.encode())
        return value.decode() if value else ""
    except Exception:  # noqa: BLE001
        return ""


def available() -> bool:
    """True inside the Android app once pyjnius can be used safely.

    A wrong pyjnius call aborts the whole process (no Python exception),
    so both preconditions are checked first: serious_python loaded
    pyjnius's JNI helper (``FLET_JNI_READY``), and the app's Activity has
    attached (pyjnius finds the app's classes through it). After the first
    attach this stays true, also with the screen closed later.
    """
    import os

    from .packaging import mobile_platform

    if mobile_platform() != "android":
        return False
    jni_ready = os.environ.get("FLET_JNI_READY") == "1"
    activity = _live_env("MAIN_ACTIVITY_CLASS_NAME")
    _trace(f"bridge check: jni_ready={jni_ready} activity={activity or '-'}")
    if not jni_ready or not activity:
        return False
    try:
        _trace("importing jnius")
        import jnius  # noqa: F401
    except Exception as exc:  # noqa: BLE001 - missing or broken: treat as absent
        _trace(f"jnius import failed: {exc!r}")
        return False
    return True


_traced: set = set()


def _trace(message: str) -> None:
    """One-time diagnostic line (adb logcat -s strakalari)."""
    if message not in _traced:
        _traced.add(message)
        print(f"Info: android: {message}", flush=True)


def _autoclass(name: str):
    """A Java class by name. Android framework / Java classes only: the
    app's own classes (the bundled Java code, and pyjnius's own helper
    behind ``PythonJavaClass``) can't be looked up from Python's threads;
    pyjnius aborts the whole process trying. The bundled ones are only
    ever named in Intents (``setClassName``)."""
    from jnius import autoclass

    if name.startswith(JAVA_PACKAGE):
        raise ValueError(f"{name}: app classes can't be loaded through pyjnius")
    return autoclass(name)


def _service(ctx, name: str, java_class: str):
    """``ctx.getSystemService(name)`` typed as ``java_class`` (pyjnius
    otherwise sees a plain Object without the service's methods)."""
    from jnius import cast

    return cast(java_class, ctx.getSystemService(name))


def _activity():
    """The app's Activity while its screen exists (set by serious_python)."""
    return _autoclass("com.flet.serious_python_android.PythonActivity").mActivity


def context():
    """The application Context (cached: it outlives every Activity), or None.

    The first call must happen while the app's screen is open; afterwards
    it also works in the background.
    """
    global _context
    with _lock:
        if _context is None and available():
            try:
                _trace("looking up the activity")
                activity = _activity()
                _trace(f"activity: {'present' if activity is not None else 'none'}")
                if activity is not None:
                    _context = activity.getApplicationContext()
                    _trace("context ready")
            except Exception as exc:  # noqa: BLE001 - reported, not fatal
                print(f"Warning: Android context unavailable ({type(exc).__name__}: {exc})")
        return _context


#: Android log priorities (android/log.h).
_LOG_INFO, _LOG_WARN = 4, 5


class _LogcatTee:
    """Copies complete lines written to a stream into ``adb logcat`` (tag
    ``strakalari``): release builds otherwise keep Python's output in a
    private file that only the app can read.

    Goes through liblog with ctypes, not pyjnius: logging must work from
    the first line, before Java classes can be looked up.
    """

    def __init__(self, stream, priority: int, write_log) -> None:
        self._stream = stream
        self._priority = priority
        self._write_log = write_log
        self._buffer = ""

    def write(self, text: str) -> int:
        written = self._stream.write(text) if self._stream is not None else len(text)
        try:
            self._buffer += str(text)
            while "\n" in self._buffer:
                line, self._buffer = self._buffer.split("\n", 1)
                if line.strip():
                    self._write_log(self._priority, b"strakalari",
                                    line[:3000].encode("utf-8", "replace"))
        except Exception:  # noqa: BLE001 - logging must never break the app
            pass
        return written

    def __getattr__(self, name: str):
        return getattr(self._stream, name)


def log_to_logcat() -> None:
    """Mirrors stdout / stderr into ``adb logcat -s strakalari``. Never raises."""
    import sys

    from .packaging import mobile_platform

    if mobile_platform() != "android" or isinstance(sys.stdout, _LogcatTee):
        return
    try:
        import ctypes

        write_log = ctypes.CDLL("liblog.so").__android_log_write
        write_log.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p]
        sys.stdout = _LogcatTee(sys.stdout, _LOG_INFO, write_log)
        sys.stderr = _LogcatTee(sys.stderr, _LOG_WARN, write_log)
    except Exception:  # noqa: BLE001
        pass


def sdk_int() -> int:
    try:
        return int(_autoclass("android.os.Build$VERSION").SDK_INT)
    except Exception:  # noqa: BLE001
        return 0


# -- notifications ---------------------------------------------------------------------------
_next_id = [1000]


def _notification_manager(ctx):
    return _service(ctx, _autoclass("android.content.Context").NOTIFICATION_SERVICE,
                    "android.app.NotificationManager")


def _open_app_intent(ctx):
    """A PendingIntent opening the app (a tap on a notification)."""
    intent_class = _autoclass("android.content.Intent")
    launch = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName())
    if launch is None:
        return None
    launch.addFlags(intent_class.FLAG_ACTIVITY_NEW_TASK
                    | intent_class.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
    pending = _autoclass("android.app.PendingIntent")
    return pending.getActivity(ctx, 0, launch,
                               pending.FLAG_IMMUTABLE | pending.FLAG_UPDATE_CURRENT)


def notify(title: str, text: str, channel_name: str) -> bool:
    """Shows a notification (a tap opens the app). True when posted.

    Framework classes only: pyjnius cannot look up the app's own classes
    from Python's threads (that aborts the app), so the bundled Java code
    is never called from here, only referred to by name.
    """
    ctx = context()
    if ctx is None:
        return False
    try:
        with _lock:
            # Distinct ids (several stay visible), cycling within a range.
            _next_id[0] = 1000 + (_next_id[0] - 1000 + 1) % 5000
            nid = _next_id[0]
        string = _autoclass("java.lang.String")
        manager = _notification_manager(ctx)
        builder_class = _autoclass("android.app.Notification$Builder")
        if sdk_int() >= 26:
            channel = _autoclass("android.app.NotificationChannel")(
                EVENTS_CHANNEL, string(channel_name),
                _autoclass("android.app.NotificationManager").IMPORTANCE_DEFAULT)
            manager.createNotificationChannel(channel)
            builder = builder_class(ctx, EVENTS_CHANNEL)
        else:
            builder = builder_class(ctx)
        icon = ctx.getResources().getIdentifier("ic_stat_strakalari", "drawable",
                                                ctx.getPackageName())
        builder.setSmallIcon(icon)
        builder.setContentTitle(string(title))
        builder.setContentText(string(text))
        builder.setStyle(_autoclass("android.app.Notification$BigTextStyle")().bigText(string(text)))
        builder.setAutoCancel(True)
        open_app = _open_app_intent(ctx)
        if open_app is not None:
            builder.setContentIntent(open_app)
        manager.notify(nid, builder.build())
        return notifications_enabled()
    except Exception as exc:  # noqa: BLE001 - must never break a job
        print(f"Warning: notification failed ({type(exc).__name__}: {exc})")
        return False


def notifications_enabled() -> bool:
    ctx = context()
    if ctx is None:
        return False
    try:
        return bool(_notification_manager(ctx).areNotificationsEnabled())
    except Exception:  # noqa: BLE001
        return False


def request_notification_permission() -> None:
    """Shows Android 13+'s "allow notifications?" prompt when it applies.

    Needs the app's screen; Android itself stops asking after the user
    declined twice (then only the system settings can turn them on).
    """
    if not available() or sdk_int() < 33 or notifications_enabled():
        return
    try:
        activity = _activity()
        if activity is not None:
            # Straight from this thread: it only starts the system's
            # permission screen. (A Runnable for the main thread would need
            # pyjnius's own Java class, which it can't load here either.)
            _trace("asking for the notification permission")
            activity.requestPermissions(["android.permission.POST_NOTIFICATIONS"], 7301)
    except Exception as exc:  # noqa: BLE001
        print(f"Warning: could not ask for the notification permission ({exc})")


def open_notification_settings() -> None:
    """Opens the system's notification settings for this app (where the user
    turns them on once Android stopped asking)."""
    ctx = context()
    if ctx is None:
        return
    try:
        settings = _autoclass("android.provider.Settings")
        intent_class = _autoclass("android.content.Intent")
        intent = intent_class(settings.ACTION_APP_NOTIFICATION_SETTINGS)
        intent.putExtra(settings.EXTRA_APP_PACKAGE, ctx.getPackageName())
        intent.addFlags(intent_class.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
    except Exception as exc:  # noqa: BLE001
        print(f"Warning: could not open the notification settings ({exc})")


# -- background service ----------------------------------------------------------------------
def _service_intent(ctx):
    intent = _autoclass("android.content.Intent")()
    intent.setClassName(ctx.getPackageName(), f"{JAVA_PACKAGE}.KeepAliveService")
    return intent


def start_background(texts: dict[str, str]) -> bool:
    """Starts (or updates) the background service. ``texts``: the ongoing
    notification's ``title`` / ``text`` / ``channel`` and the reboot
    reminder's ``boot_title`` / ``boot_text`` / ``events_channel``.

    Android only allows starting it while the app's screen is open.
    """
    ctx = context()
    if ctx is None:
        return False
    try:
        intent = _service_intent(ctx)
        for key, value in texts.items():
            intent.putExtra(key, str(value))
        if sdk_int() >= 26:
            ctx.startForegroundService(intent)
        else:
            ctx.startService(intent)
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"Warning: could not start the background service ({type(exc).__name__}: {exc})")
        return False


def stop_background() -> None:
    ctx = context()
    if ctx is None:
        return
    try:
        ctx.stopService(_service_intent(ctx))
        cancel_wake()
    except Exception as exc:  # noqa: BLE001
        print(f"Warning: could not stop the background service ({exc})")


# -- waking up for due refreshes -------------------------------------------------------------
def _wake_pending_intent(ctx):
    intent = _autoclass("android.content.Intent")()
    intent.setClassName(ctx.getPackageName(), f"{JAVA_PACKAGE}.WakeReceiver")
    pending = _autoclass("android.app.PendingIntent")
    flags = pending.FLAG_IMMUTABLE | pending.FLAG_UPDATE_CURRENT
    return pending.getBroadcast(ctx, 0, intent, flags)


def schedule_wake(epoch_s: float) -> bool:
    """Wakes the CPU at about ``epoch_s`` (also in Doze; replaces the
    previous alarm). WakeReceiver then keeps it awake for a few minutes."""
    ctx = context()
    if ctx is None:
        return False
    try:
        alarms = _service(ctx, _autoclass("android.content.Context").ALARM_SERVICE,
                          "android.app.AlarmManager")
        manager = _autoclass("android.app.AlarmManager")
        at_ms = int(max(epoch_s, time.time() + 5) * 1000)
        alarms.setAndAllowWhileIdle(manager.RTC_WAKEUP, at_ms, _wake_pending_intent(ctx))
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"Warning: could not schedule the next wake-up ({type(exc).__name__}: {exc})")
        return False


def cancel_wake() -> None:
    ctx = context()
    if ctx is None:
        return
    try:
        alarms = _service(ctx, _autoclass("android.content.Context").ALARM_SERVICE,
                          "android.app.AlarmManager")
        alarms.cancel(_wake_pending_intent(ctx))
    except Exception:  # noqa: BLE001
        pass


# -- wake-up alarm before the first lesson ----------------------------------------------------
ALARM_PREFS = "strakalari_alarm"
ACTION_RESCHEDULE_ALARM = f"{JAVA_PACKAGE}.ACTION_RESCHEDULE_ALARM"


def _alarm_manager(ctx):
    return _service(ctx, _autoclass("android.content.Context").ALARM_SERVICE,
                    "android.app.AlarmManager")


def set_wakeup_alarms(queue_json: str, channel_name: str, dismiss_label: str) -> bool:
    """Hands the upcoming wake-up alarms to ``AlarmReceiver`` (``[]`` cancels them).

    ``queue_json``: a JSON list of ``at`` / ``lesson`` (epoch ms), ``title``,
    ``text``. The receiver arms the earliest and chains the rest by itself
    (also after a reboot), so they ring on days the app never runs.
    """
    ctx = context()
    if ctx is None:
        return False
    try:
        prefs = ctx.getSharedPreferences(ALARM_PREFS, 0).edit()
        prefs.putString("queue", str(queue_json))
        prefs.putString("channel", str(channel_name))
        prefs.putString("dismiss", str(dismiss_label))
        prefs.commit()
        intent = _autoclass("android.content.Intent")(ACTION_RESCHEDULE_ALARM)
        intent.setClassName(ctx.getPackageName(), f"{JAVA_PACKAGE}.AlarmReceiver")
        ctx.sendBroadcast(intent)
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"Warning: could not hand over the wake-up alarms ({type(exc).__name__}: {exc})")
        return False


def exact_alarms_allowed() -> bool:
    """False when Android 12+ withholds exact alarms ("Alarms & reminders"
    off): the wake-up alarm then rings a few minutes late at worst."""
    ctx = context()
    if ctx is None:
        return False
    if sdk_int() < 31:
        return True
    try:
        return bool(_alarm_manager(ctx).canScheduleExactAlarms())
    except Exception:  # noqa: BLE001
        return False


def open_exact_alarm_settings() -> None:
    """Opens the system's "Alarms & reminders" switch for this app (Android 12+)."""
    ctx = context()
    if ctx is None or sdk_int() < 31:
        return
    try:
        settings = _autoclass("android.provider.Settings")
        intent_class = _autoclass("android.content.Intent")
        uri = _autoclass("android.net.Uri").parse(f"package:{ctx.getPackageName()}")
        intent = intent_class(settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, uri)
        intent.addFlags(intent_class.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
    except Exception as exc:  # noqa: BLE001
        print(f"Warning: could not open the alarm settings ({exc})")


#: Python's weekday (Monday = 0) -> java.util.Calendar's (Sunday = 1).
_CALENDAR_DAYS = (2, 3, 4, 5, 6, 7, 1)


def open_system_alarm(hour: int, minute: int, message: str = "Strakaláři",
                      weekday: int | None = None) -> bool:
    """Opens the phone's Clock app on a new alarm at ``hour:minute`` (else on
    its alarm list). True when an app was opened.

    The Clock app takes no date: without ``weekday`` the alarm rings at the
    next ``hour:minute``; with it (Monday = 0) it repeats weekly on that day
    (see ``core.wakeup.clock_app_weekday``).

    The extras go in through a Bundle: ``Intent.putExtra`` has an overload
    per number type, pyjnius can't tell which one a Python int means, and
    the Clock app ignores an hour that doesn't arrive as an ``int``.
    """
    ctx = context()
    if ctx is None:
        return False
    try:
        clock_class = _autoclass("android.provider.AlarmClock")
        intent_class = _autoclass("android.content.Intent")
        extras = _autoclass("android.os.Bundle")()
        extras.putInt(clock_class.EXTRA_HOUR, int(hour))
        extras.putInt(clock_class.EXTRA_MINUTES, int(minute))
        extras.putString(clock_class.EXTRA_MESSAGE, str(message))
        extras.putBoolean(clock_class.EXTRA_SKIP_UI, False)
        if weekday is not None:
            days = _autoclass("java.util.ArrayList")()
            days.add(_autoclass("java.lang.Integer").valueOf(_CALENDAR_DAYS[int(weekday) % 7]))
            extras.putIntegerArrayList(clock_class.EXTRA_DAYS, days)
        actions = ((clock_class.ACTION_SET_ALARM, extras), (clock_class.ACTION_SHOW_ALARMS, None))
    except Exception as exc:  # noqa: BLE001
        print(f"Warning: could not open the Clock app ({type(exc).__name__}: {exc})")
        return False
    for action, action_extras in actions:
        try:
            intent = intent_class(action)
            if action_extras is not None:
                intent.putExtras(action_extras)
            intent.addFlags(intent_class.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
            return True
        except Exception as exc:  # noqa: BLE001 - e.g. no Clock app handles it
            print(f"Warning: could not open the Clock app ({type(exc).__name__}: {exc})")
    return False


# -- home-screen timetable widget -------------------------------------------------------------
WIDGET_PREFS = "strakalari_widget"
ACTION_REFRESH_WIDGET = f"{JAVA_PACKAGE}.ACTION_REFRESH_WIDGET"


def update_timetable_widget(payload_json: str) -> bool:
    """Saves the widget data (``core.wakeup.build_widget_payload``) and redraws the widget."""
    ctx = context()
    if ctx is None:
        return False
    try:
        prefs = ctx.getSharedPreferences(WIDGET_PREFS, 0).edit()
        prefs.putString("payload", str(payload_json))
        prefs.commit()
        intent = _autoclass("android.content.Intent")(ACTION_REFRESH_WIDGET)
        intent.setClassName(ctx.getPackageName(), f"{JAVA_PACKAGE}.TimetableWidgetProvider")
        ctx.sendBroadcast(intent)
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"Warning: could not update the timetable widget ({type(exc).__name__}: {exc})")
        return False


class KeepAwake:
    """Holds the CPU awake while a refresh runs (screen may be off).

    ``with KeepAwake(minutes=30): ...`` — the timeout is a safety net, the
    lock is released as soon as the block ends. A no-op off Android.
    """

    def __init__(self, minutes: float = 30) -> None:
        self.minutes = minutes
        self._lock = None

    def __enter__(self) -> "KeepAwake":
        ctx = context()
        if ctx is not None:
            try:
                power = _service(ctx, _autoclass("android.content.Context").POWER_SERVICE,
                                 "android.os.PowerManager")
                manager = _autoclass("android.os.PowerManager")
                self._lock = power.newWakeLock(manager.PARTIAL_WAKE_LOCK, "strakalari:refresh")
                self._lock.setReferenceCounted(False)
                self._lock.acquire(int(self.minutes * 60 * 1000))
            except Exception as exc:  # noqa: BLE001
                print(f"Warning: could not keep the CPU awake ({exc})")
                self._lock = None
        return self

    def __exit__(self, *exc_info) -> None:
        lock, self._lock = self._lock, None
        if lock is not None:
            try:
                if lock.isHeld():
                    lock.release()
            except Exception:  # noqa: BLE001
                pass


# -- Android Keystore (protects the password key) ---------------------------------------------
KEYSTORE_ALIAS = "strakalari-secret-key"


def _keystore_key():
    """The app's AES key in the Android Keystore (created once; it never
    leaves the secure hardware and is lost when the app is uninstalled)."""
    _trace("opening the Keystore")
    keystore = _autoclass("java.security.KeyStore").getInstance("AndroidKeyStore")
    keystore.load(None)
    _trace("Keystore open")
    if keystore.containsAlias(KEYSTORE_ALIAS):
        return keystore.getKey(KEYSTORE_ALIAS, None)
    props = _autoclass("android.security.keystore.KeyProperties")
    # Varargs (String...): pyjnius packs the arguments into the array
    # itself; a list here would become an array inside the array.
    spec = (
        _autoclass("android.security.keystore.KeyGenParameterSpec$Builder")(
            KEYSTORE_ALIAS, props.PURPOSE_ENCRYPT | props.PURPOSE_DECRYPT)
        .setBlockModes(props.BLOCK_MODE_GCM)
        .setEncryptionPaddings(props.ENCRYPTION_PADDING_NONE)
        .setKeySize(256)
        .build()
    )
    generator = _autoclass("javax.crypto.KeyGenerator").getInstance(
        props.KEY_ALGORITHM_AES, "AndroidKeyStore")
    generator.init(spec)
    return generator.generateKey()


def _bytes(java_bytes) -> bytes:
    # pyjnius hands byte[] back as signed values or bytes, depending on version.
    return bytes(b & 0xFF for b in java_bytes)


def keystore_wrap(data: bytes) -> bytes:
    """``data`` encrypted with the Keystore key: 12-byte IV + AES-GCM output."""
    cipher_class = _autoclass("javax.crypto.Cipher")
    cipher = cipher_class.getInstance("AES/GCM/NoPadding")
    cipher.init(cipher_class.ENCRYPT_MODE, _keystore_key())
    return _bytes(cipher.getIV()) + _bytes(cipher.doFinal(bytearray(data)))


def keystore_unwrap(blob: bytes) -> bytes:
    """Reverses :func:`keystore_wrap`. Raises when the Keystore key is gone
    or the blob was tampered with."""
    if len(blob) < 12 + 16:
        raise ValueError("wrapped key too short")
    cipher_class = _autoclass("javax.crypto.Cipher")
    cipher = cipher_class.getInstance("AES/GCM/NoPadding")
    spec = _autoclass("javax.crypto.spec.GCMParameterSpec")(128, bytearray(blob[:12]))
    cipher.init(cipher_class.DECRYPT_MODE, _keystore_key(), spec)
    return _bytes(cipher.doFinal(bytearray(blob[12:])))
