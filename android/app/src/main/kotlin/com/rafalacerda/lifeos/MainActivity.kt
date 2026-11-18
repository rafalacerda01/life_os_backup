package com.rafalacerda.lifeos

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        if (applicationContext.packageName == LocalLabHost.PACKAGE) {
            // Do not call super: its generated registrant instantiates Firebase.
            LocalLabHost.configure(this, flutterEngine) {
                intent.getStringExtra("local_lab_scenario") ?: "seed"
            }
        } else {
            super.configureFlutterEngine(flutterEngine)
        }
    }
}
