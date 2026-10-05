package com.aessam.comeoverhere

import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.WifiAwareManager
import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import com.aessam.comeoverhere.core.AwareProfilePolicy
import com.aessam.comeoverhere.core.NearbyAwareProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Public SDK/configuration gates only. These tests never attach, pair or claim radio interoperability. */
class AwareProfileCapabilityTest {
    @SuppressLint("NewApi", "MissingPermission")
    @Test fun actualRuntimeCannotClaimUnsupportedSystemPairing() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val full = if (Build.VERSION.SDK_INT >= 36) Build.VERSION.SDK_INT_FULL else null
        val manager = context.getSystemService(WifiAwareManager::class.java)
        val characteristics = if (Build.VERSION.SDK_INT >= 34 && context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)) {
            manager?.characteristics
        } else null
        val methods = if ((full ?: 0) >= Build.VERSION_CODES_FULL.CINNAMON_BUN_2) {
            characteristics?.supportedOffloadBootstrappingMethods ?: 0
        } else 0
        val plan = AwareProfilePolicy.plan(false, Build.VERSION.SDK_INT, full,
            characteristics?.isAwarePairingSupported == true, methods, 2)
        if ((full ?: 0) < Build.VERSION_CODES_FULL.CINNAMON_BUN_2 || characteristics == null) {
            assertEquals(setOf(NearbyAwareProfile.ANDROID_PSK), plan.profiles)
        }
    }

    @SuppressLint("NewApi")
    @Test fun supportedRuntimeBuildsFrameworkManagedSubscribeConfiguration() {
        val full = if (Build.VERSION.SDK_INT >= 36) Build.VERSION.SDK_INT_FULL else 0
        assumeTrue("Requires actual 37.2 framework; emulator capability checks are not pairing proof",
            full >= Build.VERSION_CODES_FULL.CINNAMON_BUN_2)
        val config = SubscribeConfig.Builder().setServiceName(NearbyAwareProfile.SYSTEM_PAIRED.serviceName)
            .setSubscribeType(SubscribeConfig.SUBSCRIBE_TYPE_PASSIVE).setFrameworkOffloadedPairingEnabled(true).build()
        assertTrue(config.isFrameworkOffloadedPairingEnabled)
        assertEquals(null, config.pairingConfig)
        assertFalse(NearbyAwareProfile.SYSTEM_PAIRED.requiresPIN)
    }
}
