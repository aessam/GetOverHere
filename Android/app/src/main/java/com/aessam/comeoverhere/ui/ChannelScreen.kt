package com.aessam.comeoverhere.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.unit.dp
import com.aessam.comeoverhere.core.AudioQuality
import com.aessam.comeoverhere.core.Channel
import com.aessam.comeoverhere.service.ListenState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChannelScreen(vm: AppViewModel) {
    val channels by vm.channels.collectAsState()
    val activeChannelID by vm.activeChannelID.collectAsState()
    val listenState by vm.listenState.collectAsState()
    val listenerCount by vm.listenerCount.collectAsState()
    val connectedPeers by vm.connectedPeers.collectAsState()
    val activeChannel by vm.activeChannel.collectAsState(initial = null)

    var showCreateDialog by remember { mutableStateOf(false) }
    var newChannelName by remember { mutableStateOf("") }
    var selectedQuality by remember { mutableStateOf(AudioQuality.STANDARD) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Megaphone") },
                actions = {
                    IconButton(onClick = { showCreateDialog = true }) {
                        Icon(Icons.Default.Add, "Create Channel")
                    }
                }
            )
        }
    ) { padding ->
        Column(modifier = Modifier.padding(padding).fillMaxSize()) {
            if (activeChannel != null) {
                if (activeChannel!!.createdBy == vm.localPeerID) {
                    CreatorView(activeChannel!!, listenerCount, connectedPeers.size, vm)
                } else {
                    ListenerView(activeChannel!!, connectedPeers.size, vm)
                }
            } else {
                ChannelListView(channels, vm.localPeerID, connectedPeers.size) { channel ->
                    vm.joinChannel(channel)
                }
                if (channels.isEmpty()) {
                    EmptyState { showCreateDialog = true }
                }
            }
        }
    }

    if (showCreateDialog) {
        AlertDialog(
            onDismissRequest = { showCreateDialog = false; newChannelName = "" },
            title = { Text("New Megaphone") },
            text = {
                Column {
                    Text(
                        "Create a channel. You'll be the only speaker.",
                        style = MaterialTheme.typography.bodySmall
                    )
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = newChannelName,
                        onValueChange = { newChannelName = it },
                        label = { Text("Channel name") },
                        modifier = Modifier.fillMaxWidth()
                    )
                    Spacer(Modifier.height(12.dp))
                    Text("Audio Quality", style = MaterialTheme.typography.labelMedium)
                    Spacer(Modifier.height(4.dp))
                    AudioQuality.entries.forEach { quality ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { selectedQuality = quality }
                                .padding(vertical = 4.dp)
                        ) {
                            RadioButton(
                                selected = selectedQuality == quality,
                                onClick = { selectedQuality = quality }
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(quality.label, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    vm.createChannel(newChannelName, selectedQuality)
                    newChannelName = ""
                    selectedQuality = AudioQuality.STANDARD
                    showCreateDialog = false
                }) { Text("Create") }
            },
            dismissButton = {
                TextButton(onClick = { showCreateDialog = false; newChannelName = "" }) {
                    Text("Cancel")
                }
            }
        )
    }
}

@Composable
private fun ChannelListView(
    channels: List<Channel>,
    localPeerID: String,
    peerCount: Int,
    onJoin: (Channel) -> Unit
) {
    LazyColumn(modifier = Modifier.fillMaxWidth()) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    "Live Megaphones",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.primary
                )
                Text(
                    "$peerCount peers",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.outline
                )
            }
        }
        items(channels) { channel ->
            ListItem(
                headlineContent = { Text(channel.name) },
                supportingContent = {
                    Text(if (channel.createdBy == localPeerID) "Your megaphone" else "Live")
                },
                leadingContent = {
                    Icon(
                        if (channel.createdBy == localPeerID) Icons.Default.Campaign else Icons.Default.Headphones,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary
                    )
                },
                trailingContent = {
                    Icon(
                        Icons.Default.Circle,
                        contentDescription = "Live",
                        tint = MaterialTheme.colorScheme.error,
                        modifier = Modifier.size(8.dp)
                    )
                },
                modifier = Modifier.clickable { onJoin(channel) }
            )
        }
    }
}

@Composable
private fun EmptyState(onCreate: () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                Icons.Default.Campaign,
                contentDescription = null,
                modifier = Modifier.size(64.dp),
                tint = MaterialTheme.colorScheme.outline
            )
            Spacer(Modifier.height(16.dp))
            Text("No megaphones nearby", style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(8.dp))
            Text("Create one to start broadcasting", color = MaterialTheme.colorScheme.outline)
            Spacer(Modifier.height(24.dp))
            Button(onClick = onCreate) { Text("Create Megaphone") }
        }
    }
}

@Composable
private fun CreatorView(channel: Channel, listenerCount: Int, peerCount: Int, vm: AppViewModel) {
    val scale by animateFloatAsState(1.1f, label = "pulse")
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.SpaceBetween
    ) {
        Spacer(Modifier.height(32.dp))
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                Icons.Default.Campaign, null,
                Modifier.size(80.dp).scale(scale),
                tint = MaterialTheme.colorScheme.error
            )
            Spacer(Modifier.height(16.dp))
            Text(channel.name, style = MaterialTheme.typography.headlineLarge)
            Spacer(Modifier.height(8.dp))
            Surface(
                color = MaterialTheme.colorScheme.error.copy(alpha = 0.15f),
                shape = MaterialTheme.shapes.large
            ) {
                Text(
                    "YOU ARE LIVE",
                    Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                    color = MaterialTheme.colorScheme.error
                )
            }
            Spacer(Modifier.height(16.dp))
            Text(
                "$listenerCount listeners",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.outline
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                "$peerCount peers connected",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.outline
            )
            Spacer(Modifier.height(16.dp))
            Button(
                onClick = { vm.leaveChannel() },
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Default.Close, null)
                Spacer(Modifier.width(8.dp))
                Text("End Broadcast")
            }
        }
    }
}

@Composable
private fun ListenerView(channel: Channel, peerCount: Int, vm: AppViewModel) {
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.SpaceBetween
    ) {
        Spacer(Modifier.height(32.dp))
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                Icons.Default.Headphones, null,
                Modifier.size(80.dp),
                tint = MaterialTheme.colorScheme.primary
            )
            Spacer(Modifier.height(16.dp))
            Text(channel.name, style = MaterialTheme.typography.headlineLarge)
            Spacer(Modifier.height(8.dp))
            Text(
                "Listening...",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.primary
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                "$peerCount peers connected",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.outline
            )
            Spacer(Modifier.height(16.dp))
            OutlinedButton(
                onClick = { vm.leaveChannel() },
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Default.ExitToApp, null)
                Spacer(Modifier.width(8.dp))
                Text("Leave Channel")
            }
        }
    }
}
