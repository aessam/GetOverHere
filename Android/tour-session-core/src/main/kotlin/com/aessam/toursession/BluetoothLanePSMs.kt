package com.aessam.toursession

import java.nio.ByteBuffer

/** Optional endpoints, never authority. Every connection still runs GOD1 and lane authentication. */
data class BluetoothLanePSMs(val admission: Int, val realtime: Int, val control: Int, val asset: Int) {
    init {
        val values = listOf(admission, realtime, control, asset)
        require(values.all { it in 1..65535 } && values.toSet().size == 4) { "Invalid Bluetooth lane endpoints" }
    }

    fun psm(lane: NearbyLaneRequest.Lane): Int = when (lane) {
        NearbyLaneRequest.Lane.METADATA, NearbyLaneRequest.Lane.ADMISSION -> admission
        NearbyLaneRequest.Lane.REALTIME -> realtime
        NearbyLaneRequest.Lane.CONTROL -> control
        NearbyLaneRequest.Lane.ASSET -> asset
    }

    fun encode(): ByteArray = ByteBuffer.allocate(SIZE).apply {
        putInt(MAGIC)
        for (value in listOf(admission, realtime, control, asset)) putShort(value.toShort())
    }.array()

    companion object {
        const val SIZE = 12
        private const val MAGIC = 0x474f4c31 // GOL1

        fun decode(bytes: ByteArray): BluetoothLanePSMs {
            require(bytes.size == SIZE) { "Invalid Bluetooth lane endpoint length" }
            val buffer = ByteBuffer.wrap(bytes)
            require(buffer.int == MAGIC) { "Unsupported Bluetooth lane endpoints" }
            fun value() = buffer.short.toInt() and 65535
            return BluetoothLanePSMs(value(), value(), value(), value())
        }
    }
}
