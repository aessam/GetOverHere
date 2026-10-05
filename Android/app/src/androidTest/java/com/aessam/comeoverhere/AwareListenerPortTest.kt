package com.aessam.comeoverhere

import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.aessam.comeoverhere.core.WiFiAwareRoomTransport
import com.aessam.toursession.NearbyLaneRequest
import java.net.ServerSocket
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AwareListenerPortTest {
    @Test fun existingConnectionOnOldPortCannotBlockAwareListener() {
        assumeTrue(Build.VERSION.SDK_INT >= 34)
        ServerSocket(NearbyLaneRequest.SERVICE_PORT).use { occupied ->
            WiFiAwareRoomTransport.openListener().use { listener ->
                assertTrue(listener.isBound)
                assertTrue(listener.localPort in 1..65535)
                assertNotEquals(occupied.localPort, listener.localPort)
            }
        }
    }
}
