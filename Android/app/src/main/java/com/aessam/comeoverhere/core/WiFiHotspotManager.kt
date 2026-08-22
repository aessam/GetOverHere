package com.aessam.comeoverhere.core

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Creates a local-only WiFi hotspot for cross-platform audio.
 * Uses WifiManager.startLocalOnlyHotspot() — no internet sharing, purely local.
 *
 * Android is the WiFi HOST. iOS joins via NEHotspotConfigurationManager.
 * Credentials (SSID + password) are shared to iOS peers via BLE.
 *
 * API 33+ note: LocalOnlyHotspotCallback provides credentials via WifiConfiguration (deprecated)
 * or SoftApConfiguration. We handle both.
 */
class WiFiHotspotManager(private val context: Context) {

    data class HotspotCredentials(val ssid: String, val password: String)

    @Volatile var credentials: HotspotCredentials? = null; private set
    @Volatile var isActive: Boolean = false; private set

    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private val starting = AtomicBoolean(false)

    var onCredentialsReady: ((HotspotCredentials) -> Unit)? = null
    var onStopped: (() -> Unit)? = null

    companion object {
        private const val TAG = "WiFiHotspotManager"
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    fun start() {
        if (isActive || starting.getAndSet(true)) return

        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

        wifiManager.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
            override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                this@WiFiHotspotManager.reservation = reservation
                isActive = true
                starting.set(false)

                val creds = extractCredentials(reservation)
                if (creds != null) {
                    credentials = creds
                    Log.i(TAG, "Local-only hotspot started")
                    onCredentialsReady?.invoke(creds)
                } else {
                    Log.e(TAG, "Hotspot started but credentials unavailable")
                }
            }

            override fun onStopped() {
                isActive = false
                credentials = null
                starting.set(false)
                Log.i(TAG, "Hotspot stopped")
                onStopped?.invoke()
            }

            override fun onFailed(reason: Int) {
                isActive = false
                starting.set(false)
                Log.e(TAG, "Hotspot failed: reason=$reason")
            }
        }, null)
    }

    fun stop() {
        reservation?.close()
        reservation = null
        isActive = false
        credentials = null
    }

    @Suppress("DEPRECATION")
    private fun extractCredentials(reservation: WifiManager.LocalOnlyHotspotReservation): HotspotCredentials? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // API 30+: SoftApConfiguration
            val softApConfig = reservation.softApConfiguration
            if (softApConfig != null) {
                val ssid = softApConfig.ssid ?: "GetOverHere-${UUID.randomUUID().toString().take(8)}"
                val password = softApConfig.passphrase ?: generatePassword()
                HotspotCredentials(ssid = ssid, password = password)
            } else {
                // Fallback for devices that don't populate SoftApConfiguration
                val wifiConfig = reservation.wifiConfiguration
                if (wifiConfig != null) {
                    HotspotCredentials(
                        ssid = wifiConfig.SSID?.trim('"') ?: "GetOverHere",
                        password = wifiConfig.preSharedKey?.trim('"') ?: generatePassword()
                    )
                } else null
            }
        } else {
            // API 26–29: WifiConfiguration
            val wifiConfig = reservation.wifiConfiguration
            if (wifiConfig != null) {
                HotspotCredentials(
                    ssid = wifiConfig.SSID?.trim('"') ?: "GetOverHere",
                    password = wifiConfig.preSharedKey?.trim('"') ?: generatePassword()
                )
            } else null
        }
    }

    private fun generatePassword(): String {
        val chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
        return (1..12).map { chars.random() }.joinToString("")
    }
}
