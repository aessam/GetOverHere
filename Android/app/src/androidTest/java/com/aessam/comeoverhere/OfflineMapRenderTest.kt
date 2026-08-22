package com.aessam.comeoverhere

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aessam.comeoverhere.service.OfflineMapPack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.snapshotter.MapSnapshotter
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class OfflineMapRenderTest {
    @Test
    fun mapLibreRendersLocalPmTilesArchive() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val directory = File(context.cacheDir, "map-render-${System.nanoTime()}")
        assertTrue(directory.mkdirs())
        try {
            val archive = File(directory, "minimal.pmtiles")
            archive.writeBytes(minimalArchiveBytes())
            val configuration = OfflineMapPack.configuration(styleBytes(), archive)
            val completion = CountDownLatch(1)
            var renderedColor: Int? = null
            var renderError: String? = null
            lateinit var snapshotter: MapSnapshotter

            instrumentation.runOnMainSync {
                MapLibre.getInstance(context)
                val options = MapSnapshotter.Options(128, 128)
                    .withStyleJson(configuration.styleJSON)
                    .withCameraPosition(
                        CameraPosition.Builder()
                            .target(LatLng(0.0, 0.0))
                            .zoom(0.0)
                            .build(),
                    )
                    .withLogo(false)
                    .withAttribution(false)
                snapshotter = MapSnapshotter(context, options)
                snapshotter.start(
                    { snapshot ->
                        renderedColor = snapshot.bitmap.getPixel(64, 64)
                        completion.countDown()
                    },
                    { error ->
                        renderError = error
                        completion.countDown()
                    },
                )
            }

            assertTrue("MapLibre snapshot timed out", completion.await(30, TimeUnit.SECONDS))
            assertEquals(null, renderError)
            val color = checkNotNull(renderedColor)
            assertTrue(abs(TILE_RED - Color.red(color)) <= COLOR_TOLERANCE)
            assertTrue(abs(TILE_GREEN - Color.green(color)) <= COLOR_TOLERANCE)
            assertTrue(abs(TILE_BLUE - Color.blue(color)) <= COLOR_TOLERANCE)
        } finally {
            assertTrue(directory.deleteRecursively())
        }
    }

    private fun styleBytes(): ByteArray = """
        {"version":8,"sources":{"tour":{"type":"raster","url":"getoverhere://map-archive","tileSize":256}},"layers":[{"id":"tour","type":"raster","source":"tour"}]}
    """.trimIndent().encodeToByteArray()

    private fun minimalArchiveBytes(): ByteArray {
        val bitmap = Bitmap.createBitmap(256, 256, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.rgb(TILE_RED, TILE_GREEN, TILE_BLUE))
        val output = ByteArrayOutputStream()
        check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
        bitmap.recycle()
        val png = output.toByteArray()
        val directory = byteArrayOf(1, 0, 1) + encodeVarInt(png.size.toLong()) + byteArrayOf(1)
        val metadata = "{}".encodeToByteArray()
        val rootOffset = 127L
        val metadataOffset = rootOffset + directory.size
        val tileOffset = metadataOffset + metadata.size
        val header = ByteBuffer.allocate(127).order(ByteOrder.LITTLE_ENDIAN)
        header.put("PMTiles".encodeToByteArray())
        header.put(3)
        header.putLong(rootOffset)
        header.putLong(directory.size.toLong())
        header.putLong(metadataOffset)
        header.putLong(metadata.size.toLong())
        header.putLong(tileOffset)
        header.putLong(0)
        header.putLong(tileOffset)
        header.putLong(png.size.toLong())
        header.putLong(1)
        header.putLong(1)
        header.putLong(1)
        header.put(1)
        header.put(1)
        header.put(1)
        header.put(2)
        header.put(0)
        header.put(0)
        return header.array() + directory + metadata + png
    }

    private fun encodeVarInt(value: Long): ByteArray {
        require(value >= 0)
        var remaining = value
        val bytes = ArrayList<Byte>()
        while (remaining >= 0x80) {
            bytes += ((remaining and 0x7F) or 0x80).toByte()
            remaining = remaining shr 7
        }
        bytes += remaining.toByte()
        return bytes.toByteArray()
    }

    private companion object {
        const val TILE_RED = 102
        const val TILE_GREEN = 51
        const val TILE_BLUE = 153
        const val COLOR_TOLERANCE = 5
    }
}
