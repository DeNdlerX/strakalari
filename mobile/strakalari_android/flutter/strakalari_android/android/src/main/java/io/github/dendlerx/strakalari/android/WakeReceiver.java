package io.github.dendlerx.strakalari.android;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.PowerManager;

/**
 * The alarm Python sets for the next due refresh lands here: the CPU is
 * kept awake for a few minutes, long enough for the scheduler (which ticks
 * every few seconds) to notice and start the refresh, which then holds
 * its own wake lock until it is done.
 */
public class WakeReceiver extends BroadcastReceiver {
    static final long HOLD_MS = 3 * 60 * 1000L;

    // Held statically: a collected WakeLock object would let go early.
    private static PowerManager.WakeLock lock;

    @Override
    public void onReceive(Context context, Intent intent) {
        PowerManager pm = context.getSystemService(PowerManager.class);
        if (pm == null) {
            return;
        }
        synchronized (WakeReceiver.class) {
            if (lock == null) {
                lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "strakalari:scheduled-refresh");
                lock.setReferenceCounted(false);
            }
            lock.acquire(HOLD_MS);
        }
    }
}
