package io.github.dendlerx.strakalari

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.github.dendlerx.strakalari.android.StrakalariChannel

class MainActivity : FlutterActivity() {
    private var channel: StrakalariChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val attached = StrakalariChannel()
        attached.attach(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        // The notification permission prompt needs the screen (Python asks
        // through the activity too, core/android.py).
        attached.setActivity(this)
        channel = attached
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setActivity(null)
        channel?.detach()
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    @Suppress("OVERRIDE_DEPRECATION")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (channel?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
