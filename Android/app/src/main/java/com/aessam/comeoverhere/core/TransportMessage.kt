package com.aessam.comeoverhere.core

import kotlinx.serialization.json.*
import java.util.UUID

/**
 * Cross-platform message format matching iOS TransportMessage exactly.
 *
 * Swift Codable encodes enums as: {"caseName": associatedValue}
 * Date is encoded as seconds since Jan 1 2001 (Swift reference date).
 */

// Swift reference date: Jan 1 2001 00:00:00 UTC in Unix epoch
const val SWIFT_REFERENCE_EPOCH = 978307200L

/** Convert Unix millis to Swift reference date Double. */
fun unixMillisToSwiftRef(millis: Long): Double = (millis / 1000.0) - SWIFT_REFERENCE_EPOCH

/** Convert Swift reference date to Unix millis. */
fun swiftRefToUnixMillis(swiftRef: Double): Long = ((swiftRef + SWIFT_REFERENCE_EPOCH) * 1000).toLong()

/** Current time as Swift reference date. */
fun nowAsSwiftRef(): Double = unixMillisToSwiftRef(System.currentTimeMillis())

// --- Message types ---

sealed class TransportMessage {
    data class Text(val payload: TextPayload) : TransportMessage()
    data class WalkieTalkieControl(val control: WalkieTalkieControlType) : TransportMessage()
    data class ChannelAnnounce(val announce: ChannelAnnouncePayload) : TransportMessage()
    data class FileHeader(val header: FileHeaderPayload) : TransportMessage()
    data class FileChunk(val chunk: FileChunkPayload) : TransportMessage()
}

data class TextPayload(
    val id: String = UUID.randomUUID().toString(),
    val channelID: String,
    val senderID: String,
    val senderName: String,
    val content: String,
    val timestamp: Double = nowAsSwiftRef(),
    val replyTo: String? = null
)

data class ChannelAnnouncePayload(
    val channelID: String,
    val channelName: String,
    val createdAt: Double,
    val createdBy: String
)

data class FileHeaderPayload(
    val transferID: String = UUID.randomUUID().toString(),
    val channelID: String,
    val senderID: String,
    val senderName: String,
    val fileName: String,
    val fileSize: Int,
    val mimeType: String,
    val timestamp: Double = nowAsSwiftRef()
)

data class FileChunkPayload(
    val transferID: String,
    val index: Int,
    val totalChunks: Int,
    val data: String  // Base64-encoded chunk
)

sealed class WalkieTalkieControlType {
    data class RequestFloor(val channelID: String, val peerID: String, val peerName: String) : WalkieTalkieControlType()
    data class GrantFloor(val channelID: String, val peerID: String) : WalkieTalkieControlType()
    data class ReleaseFloor(val channelID: String, val peerID: String) : WalkieTalkieControlType()
    data class DenyFloor(val channelID: String, val reason: String) : WalkieTalkieControlType()
}

// --- Serialization ---

/** Serialize to JSON matching Swift's Codable output exactly. */
fun TransportMessage.toJson(): String {
    val json = when (this) {
        is TransportMessage.Text -> buildJsonObject {
            put("text", payload.toJsonObject())
        }
        is TransportMessage.WalkieTalkieControl -> buildJsonObject {
            put("walkieTalkieControl", control.toJsonObject())
        }
        is TransportMessage.ChannelAnnounce -> buildJsonObject {
            put("channelAnnounce", announce.toJsonObject())
        }
        is TransportMessage.FileHeader -> buildJsonObject {
            put("fileHeader", header.toJsonObject())
        }
        is TransportMessage.FileChunk -> buildJsonObject {
            put("fileChunk", chunk.toJsonObject())
        }
    }
    return json.toString()
}

/** Unwrap Swift's _0 key if present. Swift Codable wraps unnamed enum associated values with _0. */
private fun JsonObject.unwrap0(): JsonObject = if ("_0" in this) this["_0"]!!.jsonObject else this

/** Deserialize from Swift-compatible JSON. Handles Swift's _0 wrapper for enum associated values. */
fun parseTransportMessage(jsonString: String): TransportMessage? {
    return try {
        val obj = Json.parseToJsonElement(jsonString).jsonObject
        when {
            "text" in obj -> TransportMessage.Text(obj["text"]!!.jsonObject.unwrap0().toTextPayload())
            "walkieTalkieControl" in obj -> TransportMessage.WalkieTalkieControl(obj["walkieTalkieControl"]!!.jsonObject.unwrap0().toWalkieTalkieControl())
            "channelAnnounce" in obj -> TransportMessage.ChannelAnnounce(obj["channelAnnounce"]!!.jsonObject.unwrap0().toChannelAnnounce())
            "fileHeader" in obj -> TransportMessage.FileHeader(obj["fileHeader"]!!.jsonObject.unwrap0().toFileHeader())
            "fileChunk" in obj -> TransportMessage.FileChunk(obj["fileChunk"]!!.jsonObject.unwrap0().toFileChunk())
            else -> null
        }
    } catch (e: Exception) {
        android.util.Log.e("TransportMessage", "Parse failed: ${e.javaClass.simpleName}")
        null
    }
}

// --- Payload serialization helpers ---

private fun TextPayload.toJsonObject(): JsonObject = buildJsonObject {
    put("id", id)
    put("channelID", channelID)
    put("senderID", senderID)
    put("senderName", senderName)
    put("content", content)
    put("timestamp", timestamp)
    if (replyTo != null) put("replyTo", replyTo) else put("replyTo", JsonNull)
}

private fun JsonObject.toTextPayload(): TextPayload = TextPayload(
    id = this["id"]!!.jsonPrimitive.content,
    channelID = this["channelID"]!!.jsonPrimitive.content,
    senderID = this["senderID"]!!.jsonPrimitive.content,
    senderName = this["senderName"]!!.jsonPrimitive.content,
    content = this["content"]!!.jsonPrimitive.content,
    timestamp = this["timestamp"]!!.jsonPrimitive.double,
    replyTo = this["replyTo"]?.let { if (it is JsonNull) null else it.jsonPrimitive.content }
)

private fun ChannelAnnouncePayload.toJsonObject(): JsonObject = buildJsonObject {
    put("channelID", channelID)
    put("channelName", channelName)
    put("createdAt", createdAt)
    put("createdBy", createdBy)
}

private fun JsonObject.toChannelAnnounce(): ChannelAnnouncePayload = ChannelAnnouncePayload(
    channelID = this["channelID"]!!.jsonPrimitive.content,
    channelName = this["channelName"]!!.jsonPrimitive.content,
    createdAt = this["createdAt"]!!.jsonPrimitive.double,
    createdBy = this["createdBy"]!!.jsonPrimitive.content
)

private fun FileHeaderPayload.toJsonObject(): JsonObject = buildJsonObject {
    put("transferID", transferID)
    put("channelID", channelID)
    put("senderID", senderID)
    put("senderName", senderName)
    put("fileName", fileName)
    put("fileSize", fileSize)
    put("mimeType", mimeType)
    put("timestamp", timestamp)
}

private fun JsonObject.toFileHeader(): FileHeaderPayload = FileHeaderPayload(
    transferID = this["transferID"]!!.jsonPrimitive.content,
    channelID = this["channelID"]!!.jsonPrimitive.content,
    senderID = this["senderID"]!!.jsonPrimitive.content,
    senderName = this["senderName"]!!.jsonPrimitive.content,
    fileName = this["fileName"]!!.jsonPrimitive.content,
    fileSize = this["fileSize"]!!.jsonPrimitive.int,
    mimeType = this["mimeType"]!!.jsonPrimitive.content,
    timestamp = this["timestamp"]!!.jsonPrimitive.double
)

private fun FileChunkPayload.toJsonObject(): JsonObject = buildJsonObject {
    put("transferID", transferID)
    put("index", index)
    put("totalChunks", totalChunks)
    put("data", data)
}

private fun JsonObject.toFileChunk(): FileChunkPayload = FileChunkPayload(
    transferID = this["transferID"]!!.jsonPrimitive.content,
    index = this["index"]!!.jsonPrimitive.int,
    totalChunks = this["totalChunks"]!!.jsonPrimitive.int,
    data = this["data"]!!.jsonPrimitive.content
)

private fun WalkieTalkieControlType.toJsonObject(): JsonObject = when (this) {
    is WalkieTalkieControlType.RequestFloor -> buildJsonObject {
        putJsonObject("requestFloor") {
            put("channelID", channelID); put("peerID", peerID); put("peerName", peerName)
        }
    }
    is WalkieTalkieControlType.GrantFloor -> buildJsonObject {
        putJsonObject("grantFloor") { put("channelID", channelID); put("peerID", peerID) }
    }
    is WalkieTalkieControlType.ReleaseFloor -> buildJsonObject {
        putJsonObject("releaseFloor") { put("channelID", channelID); put("peerID", peerID) }
    }
    is WalkieTalkieControlType.DenyFloor -> buildJsonObject {
        putJsonObject("denyFloor") { put("channelID", channelID); put("reason", reason) }
    }
}

private fun JsonObject.toWalkieTalkieControl(): WalkieTalkieControlType = when {
    "requestFloor" in this -> this["requestFloor"]!!.jsonObject.let {
        WalkieTalkieControlType.RequestFloor(
            it["channelID"]!!.jsonPrimitive.content,
            it["peerID"]!!.jsonPrimitive.content,
            it["peerName"]!!.jsonPrimitive.content
        )
    }
    "grantFloor" in this -> this["grantFloor"]!!.jsonObject.let {
        WalkieTalkieControlType.GrantFloor(it["channelID"]!!.jsonPrimitive.content, it["peerID"]!!.jsonPrimitive.content)
    }
    "releaseFloor" in this -> this["releaseFloor"]!!.jsonObject.let {
        WalkieTalkieControlType.ReleaseFloor(it["channelID"]!!.jsonPrimitive.content, it["peerID"]!!.jsonPrimitive.content)
    }
    "denyFloor" in this -> this["denyFloor"]!!.jsonObject.let {
        WalkieTalkieControlType.DenyFloor(it["channelID"]!!.jsonPrimitive.content, it["reason"]!!.jsonPrimitive.content)
    }
    else -> throw IllegalArgumentException("Unknown control type: ${this.keys}")
}
