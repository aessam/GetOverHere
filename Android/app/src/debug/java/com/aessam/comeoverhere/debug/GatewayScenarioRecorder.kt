package com.aessam.comeoverhere.debug

import android.app.KeyguardManager
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import com.aessam.comeoverhere.ComeOverHereApp
import com.aessam.comeoverhere.service.AudioRuntimeState
import com.aessam.comeoverhere.service.GatewayRole
import com.aessam.comeoverhere.service.GatewayState
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Bounded real-service observations. Never labels sampled app state an acoustic/field PASS. */
internal object GatewayScenarioRecorder {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var job: Job? = null
    private var currentID: String? = null
    private var samples = 0
    private var state = "idle"
    private var directory: File? = null
    private var started = 0L
    private var failedChecks = 0

    fun start(app: ComeOverHereApp, seconds: Int, requestedRunID: String = UUID.randomUUID().toString()): JSONObject {
        require(seconds in 10..7200) { "Recording duration must be 10..7200 seconds" }
        UUID.fromString(requestedRunID)
        check(job == null) { "A local scenario is already recording" }
        check(isActive(app)) { "Start an actual tour or connected companion before recording" }
        val roomID = requireNotNull(app.gateway.activeRoomID())
        val root = File(app.filesDir, "debug-control/scenarios")
        check(root.isDirectory || root.mkdirs())
        check((root.listFiles()?.size ?: 0) < 20) { "Export and remove earlier recordings before starting more" }
        check(root.usableSpace > 32 * 1024 * 1024) { "Insufficient space for a bounded recording" }
        val id = UUID.randomUUID().toString()
        val output = File(root, id)
        check(output.mkdir())
        directory = output; currentID = id; samples = 0; failedChecks = 0; state = "recording"; started = SystemClock.elapsedRealtime()
        val deadline = started + seconds * 1000L
        val trace = File(output, "observations.jsonl")
        val build = app.packageManager.getPackageInfo(app.packageName, 0).versionCode
        trace.writeText(JSONObject().put("kind", "header").put("id", id).put("requested_run_id", requestedRunID)
            .put("room_id", roomID).put("device_id", app.channelService.localPeerID).put("bundle_build", build)
            .put("model", Build.MODEL).put("os", Build.VERSION.RELEASE).put("duration_seconds", seconds)
            .put("classification", "on-device-continuity-observation").toString() + "\n")
        job = scope.launch {
            var completion = "RECORDED_NOT_QUALIFIED"
            var errorType: String? = null
            try {
                while (true) {
                    val sample = observe(app)
                    val sameRoom = app.gateway.activeRoomID() == roomID
                    val active = isActive(app)
                    if (!sameRoom) failedChecks++
                    if (!active) failedChecks++
                    sample.put("same_room", sameRoom).put("active", active)
                    withContext(Dispatchers.IO) {
                        check(trace.length() < 16 * 1024 * 1024) { "Observation limit exceeded" }
                        trace.appendText(sample.toString() + "\n")
                    }
                    samples++
                    if (SystemClock.elapsedRealtime() >= deadline) break
                    delay(minOf(1000L, deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1))
                }
            } catch (error: kotlinx.coroutines.CancellationException) {
                completion = "CANCELLED"
            } catch (error: Exception) {
                completion = "FAILED"
                errorType = error.javaClass.simpleName
                Log.w("GatewayScenario", "Recording failed: $errorType")
            } finally {
                state = completion
                val summary = JSONObject().put("schema", 1).put("id", id).put("scenario", "gateway-observe")
                    .put("requested_run_id", requestedRunID).put("room_id", roomID).put("device_id", app.channelService.localPeerID)
                    .put("status", completion).put("requested_seconds", seconds).put("observed_samples", samples)
                    .put("tests", JSONObject().put("executed", samples * 2).put("passed", samples * 2 - failedChecks)
                        .put("failed", failedChecks).put("skipped", 0))
                    .put("elapsed_ms", SystemClock.elapsedRealtime() - started).put("error_type", errorType ?: "")
                    .put("scope", "actual_application_state_samples_not_acoustic_or_radio_qualification")
                // Tiny final summary must survive cancellation; no microphone or credential data.
                try { File(output, "summary.json").writeText(summary.toString()) }
                catch (error: Exception) { Log.w("GatewayScenario", "Summary write failed: ${error.javaClass.simpleName}"); state = "FAILED" }
                job = null
            }
        }
        return status()
    }

    fun cancel() { job?.cancel() }

    fun status(): JSONObject = JSONObject().put("id", currentID ?: "").put("state", state)
        .put("samples", samples).put("active", job != null)

    private fun observe(app: ComeOverHereApp): JSONObject {
        val channels = app.channelService
        val gateway = app.gateway.status.value
        val battery = app.getSystemService(BatteryManager::class.java)
        val power = app.getSystemService(PowerManager::class.java)
        val keyguard = app.getSystemService(KeyguardManager::class.java)
        val wired = app.gateway.wiredRouteSnapshot()
        return JSONObject().put("kind", "sample").put("uptime_ms", SystemClock.elapsedRealtime()).put("sequence", samples)
            .put("room_id", app.gateway.activeRoomID() ?: "").put("route_generation", app.gateway.wiredRouteSnapshot()?.generation ?: JSONObject.NULL)
            .put("locked", keyguard.isKeyguardLocked).put("screen_on", power.isInteractive)
            .put("debugger_attached", Debug.isDebuggerConnected()).put("debug_keep_awake", false)
            .put("battery_percent", battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
            .put("charging", battery.isCharging)
            .put("thermal_status", if (Build.VERSION.SDK_INT >= 29) power.currentThermalStatus else JSONObject.NULL)
            .put("listen_state", channels.listenState.value.name).put("connection", channels.connectionState.value.name)
            .put("audio", channels.audioRuntimeState.value.name).put("audio_ready_guests", channels.audioReadyGuestCount.value)
            .put("connected_guests", channels.connectedGuestCount.value).put("accepted_playback_bytes", app.audioEngine.acceptedPlaybackByteCount)
            .put("capture_dropped_buffers", app.audioEngine.captureDroppedBufferCount)
            .put("audio_capture", JSONObject(channels.captureDiagnostics()))
            .put("gateway_role", gateway.role.name).put("gateway_state", gateway.state.name)
            .put("gateway_interface", gateway.route ?: "").put("companion_keep_awake", gateway.keepAwake)
            .put("wired_source_matches", wired?.selectedSourceMatches ?: JSONObject.NULL)
            .put("wired_remote_address", wired?.remoteAddress ?: JSONObject.NULL)
            .put("aware_networks", org.json.JSONArray(app.gateway.awareRouteSnapshot().networks.map { network ->
                JSONObject().put("network_id", network.networkHandle).put("interface", network.interfaceName ?: JSONObject.NULL)
            }))
            .put("has_audio_error", channels.audioRuntimeError.value != null).put("has_gateway_error", gateway.error != null)
    }

    private fun isActive(app: ComeOverHereApp): Boolean {
        if (app.gateway.activeRoomID().isNullOrEmpty()) return false
        return if (app.gateway.status.value.role == GatewayRole.COMPANION)
            app.gateway.status.value.state == GatewayState.CONNECTED
        else app.channelService.audioRuntimeState.value == AudioRuntimeState.RUNNING
    }
}
