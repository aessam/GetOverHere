package com.aessam.comeoverhere.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.aessam.comeoverhere.core.WiFiAwareLabTransport

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WiFiAwareLabScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val transport = remember { WiFiAwareLabTransport(context) }
    val state by transport.snapshot.collectAsState()

    DisposableEffect(transport) {
        onDispose { transport.close() }
    }
    BackHandler(onBack = onBack)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Wi-Fi Aware Lab") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item {
                SectionTitle("Capability")
                Metric("Feature", if (state.capabilities.featureDeclared) "Yes" else "No")
                Metric("Available", if (state.capabilities.currentlyAvailable) "Yes" else "No")
                Metric("Pairing", if (state.capabilities.pairingSupported) "Yes" else "No")
                Metric("Data paths", "${state.capabilities.availableDataPaths}/${state.capabilities.maximumDataPaths}")
                Metric("Publish sessions", "${state.capabilities.maximumPublishSessions}")
                Metric("Subscribe sessions", "${state.capabilities.maximumSubscribeSessions}")
            }

            item {
                SectionTitle("Pair")
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    WiFiAwareLabTransport.Role.entries.forEachIndexed { index, role ->
                        SegmentedButton(
                            selected = state.role == role,
                            onClick = { transport.setRole(role) },
                            shape = SegmentedButtonDefaults.itemShape(
                                index = index,
                                count = WiFiAwareLabTransport.Role.entries.size,
                            ),
                            enabled = state.status == WiFiAwareLabTransport.Status.IDLE ||
                                state.status == WiFiAwareLabTransport.Status.FAILED,
                        ) {
                            Text(role.name.lowercase().replaceFirstChar(Char::uppercase))
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = state.pin,
                    onValueChange = transport::setPin,
                    label = { Text(if (state.role == WiFiAwareLabTransport.Role.PUBLISHER) "PIN to display" else "Publisher PIN") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Metric("Peer discovered", if (state.peerDiscovered) "Yes" else "No")
                Metric("Discovered peers", state.discoveredPeerCount.toString())
                Metric("Connected peers", state.connectedPeerCount.toString())
                Metric("Paired alias", state.pairedAlias ?: "None")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = transport::start,
                        enabled = state.status == WiFiAwareLabTransport.Status.IDLE ||
                            state.status == WiFiAwareLabTransport.Status.FAILED,
                    ) { Text("Start") }
                    Button(onClick = transport::pair, enabled = state.peerDiscovered) { Text("Pair") }
                    TextButton(onClick = transport::stop) { Text("Stop") }
                }
            }

            item {
                SectionTitle("NAN data path")
                Metric("State", state.status.name.lowercase())
                Metric("Peer IPv6", state.peerAddress ?: "None")
                Metric("Peer UDP port", state.peerPort?.toString() ?: "None")
            }

            item {
                SectionTitle("20 ms UDP probe")
                Metric("Sent", state.sentFrames.toString())
                Metric("Received", state.receivedFrames.toString())
                Metric("Missing", state.missingFrames.toString())
                Metric("Malformed", state.malformedFrames.toString())
                Metric("p95 RTT", "%.1f ms".format(state.p95RoundTripMilliseconds))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = transport::toggleProbe,
                        enabled = state.status == WiFiAwareLabTransport.Status.CONNECTED,
                    ) { Text(if (state.probing) "Stop probe" else "Start probe") }
                    TextButton(onClick = transport::resetMetrics) { Text("Reset") }
                }
            }

            state.lastError?.let { error ->
                item {
                    SectionTitle("Failure")
                    Text(error, color = MaterialTheme.colorScheme.error)
                }
            }

            item { SectionTitle("Events") }
            itemsIndexed(state.events) { index, event ->
                Text(event, style = MaterialTheme.typography.bodySmall)
                if (index != state.events.lastIndex) HorizontalDivider()
            }
        }
    }
}

@Composable
private fun SectionTitle(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 12.dp),
    )
}

@Composable
private fun Metric(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label)
        Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
