package com.aessam.comeoverhere.core

/** Wire format tag — first byte of every packet. Must match iOS DataTag exactly. */
enum class DataTag(val value: Byte) {
    MESSAGE(1),
    AUDIO(2);

    companion object {
        fun fromByte(b: Byte): DataTag? = entries.find { it.value == b }
    }
}
