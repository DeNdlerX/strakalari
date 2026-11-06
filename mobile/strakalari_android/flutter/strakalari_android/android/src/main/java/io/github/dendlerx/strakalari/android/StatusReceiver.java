package io.github.dendlerx.strakalari.android;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * New texts for the background service's notification (the overview of
 * today's lunch, the next lesson, …), sent by Python whenever they change
 * (strakalari/core/android.py: update_background_notification). Extras:
 * "title", "text", "sub". See {@link KeepAliveService#update}.
 */
public class StatusReceiver extends BroadcastReceiver {
    static final String ACTION_UPDATE =
            "io.github.dendlerx.strakalari.android.ACTION_UPDATE_STATUS";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || !ACTION_UPDATE.equals(intent.getAction())) {
            return;
        }
        KeepAliveService.update(context, intent.getStringExtra("title"),
                intent.getStringExtra("text"), intent.getStringExtra("sub"));
    }
}
