package com.aessam.toursession

import java.nio.ByteBuffer

/** Optional endpoints, never authority. Every connection still runs GOD1 and lane authentication. */
data class BluetoothLanePSMs(val admission: Int, val realtime: Int, val control: Int, val asset: Int, val metadata: Int? = null) {
    init {
        val values = listOfNotNull(admission, realtime, control, asset, metadata)
        require(values.all { it in 1..65535 } && values.toSet().size == values.size) { "Invalid Bluetooth lane endpoints" }
    }

    fun psm(lane: NearbyLaneRequest.Lane): Int = when (lane) {
        NearbyLaneRequest.Lane.METADATA -> metadata ?: admission
        NearbyLaneRequest.Lane.ADMISSION -> admission
        NearbyLaneRequest.Lane.REALTIME -> realtime
        NearbyLaneRequest.Lane.CONTROL -> control
        NearbyLaneRequest.Lane.ASSET -> asset
    }

    fun encode(): ByteArray = ByteBuffer.allocate(if (metadata == null) SIZE else 14).apply {
        putInt(if (metadata == null) MAGIC else 0x474f4c32)
        for (value in listOfNotNull(admission, realtime, control, asset, metadata)) putShort(value.toShort())
    }.array()

    companion object {
        const val SIZE = 12
        private const val MAGIC = 0x474f4c31 // GOL1

        fun decode(bytes: ByteArray): BluetoothLanePSMs {
            require(bytes.size == SIZE || bytes.size == 14) { "Invalid Bluetooth lane endpoint length" }
            val buffer = ByteBuffer.wrap(bytes)
            require(buffer.int == if (bytes.size == SIZE) MAGIC else 0x474f4c32) { "Unsupported Bluetooth lane endpoints" }
            fun value() = buffer.short.toInt() and 65535
            return BluetoothLanePSMs(value(), value(), value(), value(), if (bytes.size == 14) value() else null)
        }
    }
}
