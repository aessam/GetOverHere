package com.aessam.comeoverhere.core

data class ChannelMessage(
    val id: String,
    val channelID: String,
    val senderID: String,
    val senderName: String,
    val content: String,
    val timestamp: Double,     // Swift reference date (seconds since 2001-01-01)
    val isFromMe: Boolean,
    val fileName: String? = null,
    val fileSize: Int? = null,
    val mimeType: String? = null,
    val localFilePath: String? = null,
    val replyToID: String? = null
)
