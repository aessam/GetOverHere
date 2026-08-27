package com.aessam.comeoverhere.core

import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*
import com.aessam.toursession.ParticipantPlatform
import com.aessam.toursession.ParticipantSession
import com.aessam.toursession.SessionEnvelope
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.SessionMessageKind
import java.util.UUID
import javax.net.SocketFactory

// MARK: - Peer Identity

data class PeerInfo(
    val id: String = UUID.randomUUID().toString(),
    val displayName: String,
    val platform: Platform = Platform.ANDROID
) {
    enum class Platform(val rawValue: String) {
        IOS("ios"),
        ANDROID("android");

        companion object {
            fun fromRaw(raw: String): Platform = entries.find { it.rawValue == raw } ?: ANDROID
        }
    }
}

// MARK: - Audio Quality

enum class AudioQuality(val rawValue: String, val sampleRate: Int, val channels: Int, val label: String) {
    STANDARD("standard", 16_000, 1, "Standard (16kHz mono)"),
    HD("hd", 44_100, 2, "HD (44.1kHz stereo)");

    companion object {
        fun fromRaw(raw: String): AudioQuality = entries.find { it.rawValue == raw } ?: STANDARD
    }
}

// MARK: - BLE Commands (control plane)
// JSON wire format matches iOS Swift Codable output exactly.

sealed class BLECommand {
    data class ChannelAnnounce(
        val channelID: String,
        val channelName: String,
        val createdBy: String,
        val audioQuality: AudioQuality,
        val wifiSSID: String?,
        val audioHostIP: String? = null
    ) : BLECommand()

    data class ChannelEnded(val channelID: String) : BLECommand()
    object BecomeWiFiHost : BLECommand()
    data class WiFiCredentials(val ssid: String, val password: String, val hostIP: String? = null) : BLECommand()
    data class Heartbeat(val term: Int, val leaderID: String) : BLECommand()
    data class VoteRequest(val term: Int, val candidateID: String) : BLECommand()
    data class VoteResponse(val term: Int, val granted: Boolean) : BLECommand()
}

// MARK: - Peer Events

sealed class PeerEvent {
    data class Discovered(val peer: PeerInfo) : PeerEvent()
    data class Lost(val peer: PeerInfo) : PeerEvent()
    data class Connected(val peer: PeerInfo) : PeerEvent()
    data class Disconnected(val peer: PeerInfo) : PeerEvent()
}

// MARK: - Control Plane (BLE)

interface ControlPlane {
    val localPeer: PeerInfo
    val connectedPeers: StateFlow<List<PeerInfo>>
    val commands: SharedFlow<Pair<BLECommand, PeerInfo>>
    val peerEvents: SharedFlow<PeerEvent>

    fun start()
    fun stop()
    fun broadcast(command: BLECommand)
    fun send(command: BLECommand, to: PeerInfo)
}

// MARK: - Audio Plane

interface AudioPlane {
    val isActive: Boolean

    fun startBroadcasting(channelID: String, quality: AudioQuality)
    fun sendAudio(data: ByteArray)
    fun startListening(channelID: String, onAudio: (ByteArray) -> Unit)
    fun stop()
    fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    ) {}
    fun setSessionEventHandler(handler: ((AudioSessionEvent) -> Unit)?) {}
    fun setGuestSocketFactory(factory: SocketFactory?) {}
}

sealed class AudioSessionEvent {
    data class Joined(val participant: ParticipantSession) : AudioSessionEvent()
    data class Disconnected(val connectionID: String) : AudioSessionEvent()
    data class VersionMismatch(val remoteMajor: Int, val localMajor: Int) : AudioSessionEvent()
    data class Failed(val message: String) : AudioSessionEvent()
}

// MARK: - Reliable Session Control Transport

sealed class SessionControlEvent {
    data object Connected : SessionControlEvent()
    data class GuestJoined(val participant: ParticipantSession) : SessionControlEvent()
    data class EnvelopeReceived(val envelope: SessionEnvelope) : SessionControlEvent()
    data class GuestDisconnected(val participantID: UUID) : SessionControlEvent()
    data object Disconnected : SessionControlEvent()
    data class VersionMismatch(val remoteMajor: Int, val localMajor: Int) : SessionControlEvent()
    data class Failed(val message: String) : SessionControlEvent()
}

interface SessionControlTransport {
    val isActive: Boolean
    var hostIP: String?

    fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    )
    fun setEventHandler(handler: ((SessionControlEvent) -> Unit)?)
    fun startGuide()
    fun startGuest()
    fun send(kind: SessionMessageKind, payload: ByteArray)
    fun setGuestSocketFactory(factory: SocketFactory?) {}
    fun stop()
}

sealed class SessionAssetEvent {
    data object Connected : SessionAssetEvent()
    data class GuestJoined(val participant: ParticipantSession) : SessionAssetEvent()
    data class EnvelopeReceived(val envelope: SessionEnvelope) : SessionAssetEvent()
    data class GuestDisconnected(val participantID: UUID) : SessionAssetEvent()
    data object Disconnected : SessionAssetEvent()
    data class VersionMismatch(val remoteMajor: Int, val localMajor: Int) : SessionAssetEvent()
    data class Failed(val message: String) : SessionAssetEvent()
}

interface SessionAssetTransport {
    val isActive: Boolean
    var hostIP: String?

    fun configureSession(
        sessionID: UUID,
        participantID: UUID,
        displayName: String,
        platform: ParticipantPlatform,
        credential: SessionCredential,
    )
    fun setEventHandler(handler: ((SessionAssetEvent) -> Unit)?)
    fun startGuide()
    fun startGuest()
    fun send(kind: SessionMessageKind, payload: ByteArray, participantID: UUID?)
    fun setGuestSocketFactory(factory: SocketFactory?) {}
    fun stop()
}

// MARK: - BLE Command JSON serialization (matching iOS Codable output)

private val bleJson = Json { ignoreUnknownKeys = true }

fun BLECommand.toJson(): ByteArray {
    val obj = when (this) {
        is BLECommand.ChannelAnnounce -> buildJsonObject {
            putJsonObject("channelAnnounce") {
                put("channelID", channelID)
                put("channelName", channelName)
                put("createdBy", createdBy)
                put("audioQuality", audioQuality.rawValue)
                if (wifiSSID != null) put("wifiSSID", wifiSSID) else put("wifiSSID", JsonNull)
                if (audioHostIP != null) put("audioHostIP", audioHostIP) else put("audioHostIP", JsonNull)
            }
        }
        is BLECommand.ChannelEnded -> buildJsonObject {
            putJsonObject("channelEnded") { put("channelID", channelID) }
        }
        is BLECommand.BecomeWiFiHost -> buildJsonObject {
            put("becomeWiFiHost", buildJsonObject {})
        }
        is BLECommand.WiFiCredentials -> buildJsonObject {
            putJsonObject("wifiCredentials") {
                put("ssid", ssid)
                put("password", password)
                if (hostIP != null) put("hostIP", hostIP) else put("hostIP", JsonNull)
            }
        }
        is BLECommand.Heartbeat -> buildJsonObject {
            putJsonObject("heartbeat") {
                put("term", term)
                put("leaderID", leaderID)
            }
        }
        is BLECommand.VoteRequest -> buildJsonObject {
            putJsonObject("voteRequest") {
                put("term", term)
                put("candidateID", candidateID)
            }
        }
        is BLECommand.VoteResponse -> buildJsonObject {
            putJsonObject("voteResponse") {
                put("term", term)
                put("granted", granted)
            }
        }
    }
    return obj.toString().toByteArray(Charsets.UTF_8)
}

fun parseBLECommand(data: ByteArray): BLECommand? {
    return try {
        val str = String(data, Charsets.UTF_8)
        val obj = bleJson.parseToJsonElement(str).jsonObject
        when {
            "channelAnnounce" in obj -> {
                val inner = obj["channelAnnounce"]!!.jsonObject
                BLECommand.ChannelAnnounce(
                    channelID = inner["channelID"]!!.jsonPrimitive.content,
                    channelName = inner["channelName"]!!.jsonPrimitive.content,
                    createdBy = inner["createdBy"]!!.jsonPrimitive.content,
                    audioQuality = AudioQuality.fromRaw(inner["audioQuality"]!!.jsonPrimitive.content),
                    wifiSSID = inner["wifiSSID"]?.let { if (it is JsonNull) null else it.jsonPrimitive.content },
                    audioHostIP = inner["audioHostIP"]?.let { if (it is JsonNull) null else it.jsonPrimitive.content }
                )
            }
            "channelEnded" in obj -> {
                val inner = obj["channelEnded"]!!.jsonObject
                BLECommand.ChannelEnded(channelID = inner["channelID"]!!.jsonPrimitive.content)
            }
            "becomeWiFiHost" in obj -> BLECommand.BecomeWiFiHost
            "wifiCredentials" in obj -> {
                val inner = obj["wifiCredentials"]!!.jsonObject
                BLECommand.WiFiCredentials(
                    ssid = inner["ssid"]!!.jsonPrimitive.content,
                    password = inner["password"]!!.jsonPrimitive.content,
                    hostIP = inner["hostIP"]?.let { if (it is JsonNull) null else it.jsonPrimitive.content }
                )
            }
            "heartbeat" in obj -> {
                val inner = obj["heartbeat"]!!.jsonObject
                BLECommand.Heartbeat(
                    term = inner["term"]!!.jsonPrimitive.int,
                    leaderID = inner["leaderID"]!!.jsonPrimitive.content
                )
            }
            "voteRequest" in obj -> {
                val inner = obj["voteRequest"]!!.jsonObject
                BLECommand.VoteRequest(
                    term = inner["term"]!!.jsonPrimitive.int,
                    candidateID = inner["candidateID"]!!.jsonPrimitive.content
                )
            }
            "voteResponse" in obj -> {
                val inner = obj["voteResponse"]!!.jsonObject
                BLECommand.VoteResponse(
                    term = inner["term"]!!.jsonPrimitive.int,
                    granted = inner["granted"]!!.jsonPrimitive.boolean
                )
            }
            else -> null
        }
    } catch (e: Exception) {
        android.util.Log.e("BLECommand", "Parse failed: ${e.javaClass.simpleName}")
        null
    }
}
