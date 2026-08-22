package com.aessam.comeoverhere.core

enum class ListenerOutput {
    PRIVATE_AUDIO,
    SPEAKER;

    fun toggled(): ListenerOutput = when (this) {
        PRIVATE_AUDIO -> SPEAKER
        SPEAKER -> PRIVATE_AUDIO
    }
}
