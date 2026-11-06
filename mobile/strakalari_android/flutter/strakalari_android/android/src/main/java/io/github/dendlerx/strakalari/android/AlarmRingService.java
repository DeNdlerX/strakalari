package io.github.dendlerx.strakalari.android;

import android.app.Activity;
import android.app.Application;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;

/**
 * Rings the wake-up alarm the way a clock app does: this service plays the
 * alarm sound itself, on the alarm stream, and vibrates as an alarm, while
 * its notification (silent itself) shows what rings and how to stop it.
 *
 * <p>A notification's own sound follows the ringer: a phone on silent or
 * vibrate mutes it on many devices even when the channel asks for the alarm
 * stream. The ringer leaves the alarm stream alone (it has its own volume),
 * and Do Not Disturb lets alarms through unless the user turned that off.
 *
 * <p>It stops on the notification's Dismiss action or when the
 * notification is swiped away, when the user opens the app (a tap on the
 * notification does), or after {@link AlarmReceiver#RING_MS}. Where
 * Android won't start it (an inexact alarm on Android 12+, see
 * {@link #ring}), {@link AlarmReceiver} rings the plain alarm notification.
 */
public class AlarmRingService extends Service {
    /** Silent: the service plays the sound, a sounding channel would play it twice. */
    static final String CHANNEL_ID = "strakalari_wakeup_ring";
    private static final AudioAttributes ALARM_AUDIO = new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build();
    /** The user's alarm sound, else the ringtone, else the notification sound. */
    private static final int[] SOUNDS = {
            RingtoneManager.TYPE_ALARM, RingtoneManager.TYPE_RINGTONE,
            RingtoneManager.TYPE_NOTIFICATION,
    };

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable timeout = this::stopSelf;
    private final AudioManager.OnAudioFocusChangeListener focusListener = change -> { };
    private MediaPlayer player;
    private Vibrator vibrator;
    /** The AudioFocusRequest (Android 8+) or the listener the focus was taken with. */
    private Object focus;
    private Application.ActivityLifecycleCallbacks appOpened;

    /**
     * Starts the ring. False when Android doesn't let the service start;
     * the caller then rings the plain alarm notification instead.
     */
    static boolean ring(Context ctx, String title, String text) {
        if (!canNotify(ctx)) {
            // Notifications off: a ring without its notification couldn't be
            // stopped, so none (the app says the alarm can't ring).
            return true;
        }
        Intent intent = new Intent(ctx, AlarmRingService.class)
                .putExtra("title", title)
                .putExtra("text", text);
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                ctx.startForegroundService(intent);
            } else {
                ctx.startService(intent);
            }
            return true;
        } catch (RuntimeException e) {
            // ForegroundServiceStartNotAllowedException: Android 12+ starts
            // one from the background only for an exact alarm.
            return false;
        }
    }

    static void stop(Context ctx) {
        ctx.stopService(new Intent(ctx, AlarmRingService.class));
    }

    /** False when the user turned off the app's notifications or this channel. */
    private static boolean canNotify(Context ctx) {
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        if (nm == null || !nm.areNotificationsEnabled()) {
            return false;
        }
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel ch = nm.getNotificationChannel(CHANNEL_ID);
            return ch == null || ch.getImportance() != NotificationManager.IMPORTANCE_NONE;
        }
        return true;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String title = intent != null ? intent.getStringExtra("title") : null;
        String text = intent != null ? intent.getStringExtra("text") : null;
        try {
            Notification n = notification(title, text);
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(AlarmReceiver.NOTIFICATION_ID, n,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
            } else {
                startForeground(AlarmReceiver.NOTIFICATION_ID, n);
            }
        } catch (RuntimeException e) {
            // Refused in the foreground after all: the plain notification rings.
            AlarmReceiver.ringNotification(this, title, text);
            stopSelf();
            return START_NOT_STICKY;
        }
        startRinging();
        watchApp();
        handler.removeCallbacks(timeout);
        handler.postDelayed(timeout, AlarmReceiver.RING_MS);
        // Not sticky: an alarm cut off by the system rings no more.
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacks(timeout);
        stopRinging();
        if (appOpened != null) {
            getApplication().unregisterActivityLifecycleCallbacks(appOpened);
            appOpened = null;
        }
        super.onDestroy();
    }

    @Override
    public void onTimeout(int startId, int fgsType) {
        // Android 15+ time limits (none apply to mediaPlayback): stop cleanly.
        stopSelf();
    }

    private Notification notification(String title, String text) {
        SharedPreferences prefs = getSharedPreferences(AlarmReceiver.PREFS, MODE_PRIVATE);
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (Build.VERSION.SDK_INT >= 26 && nm != null) {
            NotificationChannel ch = new NotificationChannel(CHANNEL_ID,
                    prefs.getString("channel", "Wake-up alarm"),
                    NotificationManager.IMPORTANCE_HIGH);
            ch.setSound(null, null);
            ch.enableVibration(false);
            ch.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
            nm.createNotificationChannel(ch);
            // The sounding channel of earlier versions: only the fallback
            // uses it now (and creates it again), so the settings list one.
            if (nm.getNotificationChannel(AlarmReceiver.CHANNEL_ID) != null) {
                nm.deleteNotificationChannel(AlarmReceiver.CHANNEL_ID);
            }
        }
        PendingIntent dismiss = AlarmReceiver.dismissIntent(this);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        String body = text != null ? text : "";
        b.setSmallIcon(R.drawable.ic_stat_strakalari)
                .setContentTitle(title != null ? title : "Strakaláři")
                .setContentText(body)
                .setStyle(new Notification.BigTextStyle().bigText(body))
                .setCategory(Notification.CATEGORY_ALARM)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setOngoing(true)
                // Swiped away (Android 13+ allows it): the ring stops too.
                .setDeleteIntent(dismiss)
                .addAction(new Notification.Action.Builder(R.drawable.ic_stat_strakalari,
                        prefs.getString("dismiss", "Dismiss"), dismiss).build());
        PendingIntent open = Notifications.openApp(this);
        if (open != null) {
            b.setContentIntent(open);
        }
        if (Build.VERSION.SDK_INT < 26) {
            // Heads-up before Android 8 needs a "noisy" notification; an
            // empty vibration pattern counts without buzzing.
            b.setPriority(Notification.PRIORITY_MAX).setVibrate(new long[] {0});
        }
        return b.build();
    }

    private void startRinging() {
        stopRinging();
        AudioManager audio = getSystemService(AudioManager.class);
        // In a call (or while one rings) it only vibrates: no alarm into the call.
        if (audio == null || audio.getMode() == AudioManager.MODE_NORMAL) {
            play(audio);
        }
        vibrate();
    }

    private void play(AudioManager audio) {
        for (int type : SOUNDS) {
            Uri uri = RingtoneManager.getDefaultUri(type);
            if (uri == null) {
                continue;
            }
            MediaPlayer mp = new MediaPlayer();
            try {
                mp.setAudioAttributes(ALARM_AUDIO);
                mp.setDataSource(this, uri);
                mp.setLooping(true);
                mp.prepare();
                mp.start();
            } catch (Exception e) {
                // No such sound set ("None"), or unreadable: the next one.
                mp.release();
                continue;
            }
            player = mp;
            requestFocus(audio);
            return;
        }
    }

    /** Pauses music for the alarm, as a clock app does. */
    private void requestFocus(AudioManager audio) {
        if (audio == null) {
            return;
        }
        if (Build.VERSION.SDK_INT >= 26) {
            AudioFocusRequest request =
                    new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                            .setAudioAttributes(ALARM_AUDIO)
                            .setOnAudioFocusChangeListener(focusListener)
                            .build();
            audio.requestAudioFocus(request);
            focus = request;
        } else {
            audio.requestAudioFocus(focusListener, AudioManager.STREAM_ALARM,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT);
            focus = focusListener;
        }
    }

    private void vibrate() {
        Vibrator v = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
        if (v == null || !v.hasVibrator()) {
            return;
        }
        // As an alarm: the ringer's silent mode stops other vibrations, not alarms.
        if (Build.VERSION.SDK_INT >= 26) {
            v.vibrate(VibrationEffect.createWaveform(AlarmReceiver.VIBRATION, 0), ALARM_AUDIO);
        } else {
            v.vibrate(AlarmReceiver.VIBRATION, 0, ALARM_AUDIO);
        }
        vibrator = v;
    }

    private void stopRinging() {
        if (player != null) {
            try {
                player.stop();
            } catch (IllegalStateException ignored) {
                // Never started: release() below is all it needs.
            }
            player.release();
            player = null;
        }
        if (vibrator != null) {
            vibrator.cancel();
            vibrator = null;
        }
        AudioManager audio = getSystemService(AudioManager.class);
        if (focus != null && audio != null) {
            if (Build.VERSION.SDK_INT >= 26 && focus != focusListener) {
                audio.abandonAudioFocusRequest((AudioFocusRequest) focus);
            } else {
                audio.abandonAudioFocus(focusListener);
            }
        }
        focus = null;
    }

    /** The app coming to the front (a tap on the notification) means the user is up. */
    private void watchApp() {
        if (appOpened != null) {
            return;
        }
        appOpened = new Application.ActivityLifecycleCallbacks() {
            @Override
            public void onActivityResumed(Activity activity) {
                stopSelf();
            }

            @Override
            public void onActivityCreated(Activity activity, Bundle state) { }

            @Override
            public void onActivityStarted(Activity activity) { }

            @Override
            public void onActivityPaused(Activity activity) { }

            @Override
            public void onActivityStopped(Activity activity) { }

            @Override
            public void onActivitySaveInstanceState(Activity activity, Bundle state) { }

            @Override
            public void onActivityDestroyed(Activity activity) { }
        };
        getApplication().registerActivityLifecycleCallbacks(appOpened);
    }
}
