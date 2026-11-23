package io.github.dendlerx.strakalari.android;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * After a reboot or an app update: the wake-up alarms, the morning brief
 * and the widget are armed again right here. So are the alarms when the
 * user allows exact alarms ("Alarms & reminders").
 *
 * <p>The Flet build also posted an "open the app once" notification here,
 * because nothing could start Python without the screen. The Flutter app
 * restarts its background refresh by itself ({@link RefreshReceiver} runs
 * the headless entry on the same broadcasts), so the notice is gone
 * (owner's decision, Checkpoint C note C-N3).
 */
public class BootReceiver extends BroadcastReceiver {
    static final String ACTION_EXACT_ALARMS_CHANGED =
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED";

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent != null ? intent.getAction() : null;
        if (ACTION_EXACT_ALARMS_CHANGED.equals(action)) {
            AlarmReceiver.scheduleNext(context);
            BriefReceiver.scheduleNext(context);
            return;
        }
        if (!Intent.ACTION_BOOT_COMPLETED.equals(action)
                && !Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)) {
            return;
        }
        AlarmReceiver.scheduleNext(context);
        BriefReceiver.scheduleNext(context);
        TimetableWidgetProvider.refreshAll(context);
    }
}
