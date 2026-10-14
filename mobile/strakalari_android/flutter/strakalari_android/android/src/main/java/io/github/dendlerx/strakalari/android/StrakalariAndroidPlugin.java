package io.github.dendlerx.strakalari.android;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

/**
 * Registration only: the plugin exists to put the service, the receivers,
 * the permissions and the notification icon into the app. Python reaches
 * them through pyjnius, without any Flutter channel, so they keep working
 * while the app's screen is closed.
 */
public class StrakalariAndroidPlugin implements FlutterPlugin {
    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {}

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {}
}
