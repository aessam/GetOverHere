package com.aessam.comeoverhere.ui

import android.Manifest
import android.os.Build
import android.view.WindowManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.LocalActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.aessam.comeoverhere.service.GatewayRole
import com.aessam.comeoverhere.service.GatewaySessionCoordinator
import com.aessam.comeoverhere.service.GatewayState
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions

@Composable
fun GatewayScreen(coordinator: GatewaySessionCoordinator, onBack: () -> Unit) {
    val status by coordinator.status.collectAsState()
    val interfaces by coordinator.addresses.collectAsState()
    val aware by coordinator.awareState.collectAsState()
    var selected by remember { mutableStateOf<String?>(null) }
    var localError by remember { mutableStateOf<String?>(null) }
    var pendingScan by remember { mutableStateOf(false) }
    val address = interfaces.firstOrNull { it.displayName == selected } ?: interfaces.singleOrNull()
    val activity = LocalActivity.current
    LaunchedEffect(Unit) { coordinator.refreshInterfaces() }
    DisposableEffect(status.keepAwake, status.role) {
        val window = activity?.window
        val prior = window?.attributes?.flags?.and(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) != 0
        if (status.role == GatewayRole.COMPANION && status.keepAwake) window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { if (!prior) window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }
    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        if (result.contents != null) coordinator.scanEnrollment(result.contents, address)
    }
    fun scan() = scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE)
        .setPrompt("Scan the other hub's GetOverHere pairing QR").setBeepEnabled(false).setBarcodeImageEnabled(false))
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        if (results.values.all { it }) {
            if (pendingScan) scan() else address?.let(coordinator::beginGuide)
        } else localError = "Nearby Wi-Fi permission is required for the Android branch."
    }
    fun request(scan: Boolean) {
        pendingScan = scan; localError = null
        if (Build.VERSION.SDK_INT >= 33) permissions.launch(arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES))
        else if (scan) scan() else address?.let(coordinator::beginGuide)
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Wired companion", style = MaterialTheme.typography.headlineMedium)
        Text("One tour across an iPhone group and an Android group. Keep Wi-Fi on; Internet is not required. Capacity and locked-phone audio need qualification on your devices.")
        Text("${status.role.name.lowercase()} · ${status.state.name.lowercase()}", Modifier.testTag("gatewayStatus"))
        status.roomName?.let { Text("Tour: $it") }
        status.route?.let { Text("USB route: $it") }
        if (status.role == GatewayRole.NONE) {
            Text("Connect the phones with USB, then enable USB tethering. Select the wired interface.")
            interfaces.forEach { candidate -> Row {
                RadioButton(selected = address == candidate, onClick = { selected = candidate.displayName })
                Text(candidate.displayName)
            } }
            if (interfaces.isEmpty()) Text("No wired interface detected. Check the cable, USB role, and tethering setting.")
            TextButton(onClick = { coordinator.refreshInterfaces() }) { Text("Refresh USB interfaces") }
            Button(onClick = { request(false) }, enabled = address != null, modifier = Modifier.testTag("gatewayCreateOffer")) { Text("Connect companion to my tour") }
            Button(onClick = { request(true) }, enabled = address != null, modifier = Modifier.testTag("gatewayScanOffer")) { Text("Use this phone as companion") }
        }
        status.enrollmentQR?.let { text ->
            val bitmap = remember(text) { runCatching { BarcodeEncoder().encodeBitmap(text, BarcodeFormat.QR_CODE, 640, 640) } }
            bitmap.getOrNull()?.let { Image(it.asImageBitmap(), "Public hub enrollment QR", Modifier.size(300.dp)) }
            bitmap.exceptionOrNull()?.let { Text("QR rendering failed: ${it.message}", color = MaterialTheme.colorScheme.error) }
            Text(if (status.role == GatewayRole.GUIDE) "Scan this on the companion. Then scan its response here." else "Scan this response on the guide and confirm there. Then connect below.")
        }
        if (status.role == GatewayRole.GUIDE && status.state == GatewayState.OFFER) {
            Button(onClick = { request(true) }, modifier = Modifier.testTag("gatewayScanResponse")) { Text("Scan companion response") }
        }
        if (status.role == GatewayRole.GUIDE && status.state == GatewayState.AWAITING_CONFIRMATION) {
            Text("Authorize the phone whose response you just scanned to forward this tour?")
            Button(onClick = { coordinator.confirmCompanion() }, modifier = Modifier.testTag("gatewayConfirm")) { Text("Confirm companion") }
        }
        if (status.role == GatewayRole.COMPANION) {
            Text("USB association: ${if (status.state == GatewayState.CONNECTED) "connected" else "not connected"}. Android branch status is separate below.")
            if (status.state != GatewayState.CONNECTED && status.state != GatewayState.CONNECTING)
                Button(onClick = { coordinator.connectCompanion() }, modifier = Modifier.testTag("gatewayConnect")) { Text("Guide confirmed — connect") }
            Row { Text("Keep screen awake while forwarding"); Switch(status.keepAwake, coordinator::setKeepAwake) }
            if (aware.enabled) {
                Text("Android branch: ${if (aware.hosting) "advertising via Wi-Fi Aware" else "not advertising"}")
                if (aware.pin.isNotEmpty()) Text("Wi-Fi Aware pairing PIN: ${aware.pin}")
                Text("Active native paths: ${aware.diagnostics.networks.size}. This is not an audio-ready listener count.")
            }
            status.branchError?.let {
                Text("Android branch unavailable: $it", color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.testTag("gatewayBranchError"))
                if (status.state == GatewayState.CONNECTED)
                    Button(onClick = coordinator::retryAndroidBranch) { Text("Retry Android Wi-Fi Aware branch") }
            }
        }
        (localError ?: status.error)?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("gatewayError")) }
        if (status.role != GatewayRole.NONE) Button(onClick = { coordinator.stop() }, modifier = Modifier.testTag("gatewayStop")) { Text("Remove companion / stop forwarding") }
        Spacer(Modifier.height(8.dp))
        TextButton(onClick = onBack, enabled = status.role != GatewayRole.COMPANION, modifier = Modifier.fillMaxWidth()) { Text("Back to tour") }
    }
}
