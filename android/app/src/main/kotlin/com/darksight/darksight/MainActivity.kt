package com.darksight.darksight

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the `darksight/wifi` channel used by Tier 2.
 *
 * getRssi       -> Int dBm of the associated access point, or null when
 *                  Wi-Fi is off / not associated.
 * multicastLock -> keeps broadcast UDP from the ESP32 sensor arriving
 *                  while the app is open.
 * csiSupported  -> false. Stock Android has no CSI API; detailed Wi-Fi
 *                  sensing uses the ESP32 sensor (firmware/esp32_csi).
 */
class MainActivity : FlutterActivity() {
    private var lock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "darksight/wifi")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getRssi" -> {
                        try {
                            val wm = applicationContext
                                .getSystemService(Context.WIFI_SERVICE) as WifiManager
                            @Suppress("DEPRECATION")
                            val rssi = wm.connectionInfo?.rssi ?: -127
                            if (!wm.isWifiEnabled || rssi <= -127) {
                                result.success(null)
                            } else {
                                result.success(rssi)
                            }
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    "multicastLock" -> {
                        try {
                            if (lock == null) {
                                val wm = applicationContext
                                    .getSystemService(Context.WIFI_SERVICE) as WifiManager
                                lock = wm.createMulticastLock("darksight").apply {
                                    setReferenceCounted(false)
                                    acquire()
                                }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "csiSupported" -> result.success(false)
                    else -> result.notImplemented()
                }
            }
    }
}
