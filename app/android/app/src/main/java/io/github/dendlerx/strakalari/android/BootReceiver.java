package io.github.dendlerx.strakalari.android;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;

/**
 * A reboot or an app update ends the process, and with it the embedded
 * Python: the scheduler only runs again once the app is opened. When
 * background running was on, say so with a notification (texts saved by
 * KeepAliveService in the app's language); a tap opens the app.
 *
 * <p>The wake-up alarms and the widget need no Python: their queued alarm
 * and refresh are armed again right here. So is the alarm when the user
 * allows exact alarms ("Alarms & reminders").
 */
public class BootReceiver extends BroadcastReceiver {
    static final int NOTIFICATION_ID = 7302;
    static final String ACTION_EXACT_ALARMS_CHANGED =
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED";

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent != null ? intent.getAction() : null;
        if (ACTION_EXACT_ALARMS_CHANGED.equals(action)) {
            AlarmReceiver.scheduleNext(context);
            return;
        }
        if (!Intent.ACTION_BOOT_COMPLETED.equals(action)
                && !Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)) {
            return;
        }
        AlarmReceiver.scheduleNext(context);
        TimetableWidgetProvider.refreshAll(context);
        SharedPreferences prefs = context.getSharedPreferences(
                KeepAliveService.PREFS, Context.MODE_PRIVATE);
        if (!prefs.getBoolean("enabled", false)) {
            return;
        }
        String title = prefs.getString("boot_title", null);
        String text = prefs.getString("boot_text", null);
        if (title == null || text == null) {
            return;
        }
        Notifications.show(context, "strakalari_events",
                prefs.getString("events_channel", "Strakaláři"), title, text, NOTIFICATION_ID);
    }
}
