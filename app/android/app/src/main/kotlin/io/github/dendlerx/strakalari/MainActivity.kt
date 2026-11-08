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
        channel = attached
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.detach()
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
