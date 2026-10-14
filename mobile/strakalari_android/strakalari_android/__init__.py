"""Android pieces of the Strakaláři phone app.

The Python package is only a carrier: ``flet build`` takes the Flutter
plugin from ``flutter/strakalari_android`` (a foreground service, alarm and
boot receivers, the notification icon). The app reaches them through
pyjnius, see ``strakalari/core/android.py``.
"""
