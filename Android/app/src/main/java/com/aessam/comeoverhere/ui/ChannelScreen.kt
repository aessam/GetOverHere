package com.aessam.comeoverhere.ui

import android.Manifest
import android.content.Context
import android.graphics.BitmapFactory
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.items as rowItems
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.aessam.comeoverhere.core.Channel
import com.aessam.comeoverhere.core.ListenerOutput
import com.aessam.comeoverhere.service.ListenState
import com.aessam.comeoverhere.service.LocalDevicePosition
import com.aessam.comeoverhere.service.LocalGuidanceStatus
import com.aessam.comeoverhere.service.LocalTargetGuidance
import com.aessam.comeoverhere.service.OfflineMapConfiguration
import com.aessam.comeoverhere.service.OfflineMapImport
import com.aessam.comeoverhere.service.OfflineMapPack
import com.aessam.comeoverhere.service.OfflineMapStatus
import com.aessam.comeoverhere.service.readUpTo
import com.aessam.comeoverhere.service.SlideImport
import com.aessam.comeoverhere.service.SessionConnectionState
import com.aessam.toursession.BearingSnapshotPayload
import com.aessam.toursession.PresentationSnapshotPayload
import com.aessam.toursession.SessionCredential
import com.aessam.toursession.TargetSnapshotPayload
import com.aessam.toursession.TargetGuidance
import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TourVisualMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChannelScreen(vm: AppViewModel, onOpenWiFiAwareLab: () -> Unit = {}) {
    val channels by vm.channels.collectAsState()
    val activeChannelID by vm.activeChannelID.collectAsState()
    val listenState by vm.listenState.collectAsState()
    val listenerCount by vm.listenerCount.collectAsState()
    val connectedGuestCount by vm.connectedGuestCount.collectAsState()
    val speakerFeedbackWarning by vm.speakerFeedbackWarning.collectAsState()
    val readyParticipantCount by vm.readyParticipantCount.collectAsState()
    val activeChannel by vm.activeChannel.collectAsState(initial = null)
    val listenerOutput by vm.listenerOutput.collectAsState()
    val presentation by vm.presentationSnapshot.collectAsState()
    val slides by vm.slides.collectAsState()
    val readySlideFiles by vm.readySlideFiles.collectAsState()
    val isImportingSlides by vm.isImportingSlides.collectAsState()
    val isImportingMap by vm.isImportingMap.collectAsState()
    val offlineMapConfiguration by vm.offlineMapConfiguration.collectAsState()
    val offlineMapStatus by vm.offlineMapStatus.collectAsState()
    val target by vm.targetSnapshot.collectAsState()
    val bearing by vm.bearingSnapshot.collectAsState()
    val visualFocus by vm.visualFocusSnapshot.collectAsState()
    val localGuidanceStatus by vm.localGuidanceService.status.collectAsState()
    val localPosition by vm.localGuidanceService.position.collectAsState()
    val localHeading by vm.localGuidanceService.headingDegrees.collectAsState()
    val localMagneticHeading by vm.localGuidanceService.magneticHeadingDegrees.collectAsState()
    val headingAccuracy by vm.localGuidanceService.headingAccuracy.collectAsState()
    val tourFeatureError by vm.tourFeatureError.collectAsState()
    val tourCode by vm.tourCode.collectAsState()
    val connectionState by vm.connectionState.collectAsState()
    val reconnectAttempt by vm.reconnectAttempt.collectAsState()

    var showCreateDialog by remember { mutableStateOf(false) }
    var newChannelName by remember { mutableStateOf("") }
    var pickerError by remember { mutableStateOf<String?>(null) }
    var guestMinimizedSlide by remember { mutableStateOf(false) }
    var selectedFeature by remember { mutableStateOf(TourFeature.SLIDES) }
    var pendingJoinChannel by remember { mutableStateOf<Channel?>(null) }
    var joinCode by remember { mutableStateOf("") }
    var pendingCreateName by remember { mutableStateOf<String?>(null) }
    var createError by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val pickerScope = rememberCoroutineScope()
    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(50),
    ) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        pickerScope.launch {
            try {
                val imports = withContext(Dispatchers.IO) {
                    uris.map { uri ->
                        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                            ?: error("A selected photo could not be read")
                        SlideImport(
                            bytes,
                            context.contentResolver.getType(uri) ?: "image/jpeg",
                        )
                    }
                }
                pickerError = null
                vm.importSlides(imports)
            } catch (error: Exception) {
                pickerError = error.message ?: error.javaClass.simpleName
            }
        }
    }
    val locationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { vm.localGuidanceService.start() }
    val microphonePermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val name = pendingCreateName
        pendingCreateName = null
        if (granted && name != null) {
            createError = null
            vm.createChannel(name)
            newChannelName = ""
            showCreateDialog = false
        } else if (!granted) {
            createError = "Microphone permission is required to create a megaphone"
        }
    }
    val wifiAwarePermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            pickerError = null
            onOpenWiFiAwareLab()
        } else {
            pickerError = "Nearby Wi-Fi permission is required for offline device-to-device tours"
        }
    }
    val requestLocalGuidance = {
        if (
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            vm.localGuidanceService.start()
        } else {
            locationPermission.launch(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }
    val requestCreateChannel: (String) -> Unit = { rawName ->
        val name = rawName.trim()
        when {
            name.isEmpty() -> createError = "Enter a channel name"
            name.length > 32 -> createError = "Channel names are limited to 32 characters"
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED -> {
                createError = null
                vm.createChannel(name)
                newChannelName = ""
                showCreateDialog = false
            }
            else -> {
                pendingCreateName = name
                microphonePermission.launch(Manifest.permission.RECORD_AUDIO)
            }
        }
    }
    val requestOpenWiFiAwareLab = {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            pickerError = "The Wi-Fi Aware lab requires Android 14 or later"
        } else if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.NEARBY_WIFI_DEVICES) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            wifiAwarePermission.launch(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            onOpenWiFiAwareLab()
        }
    }
    val mapPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        pickerScope.launch {
            var temporaryArchive: File? = null
            try {
                val import = withContext(Dispatchers.IO) {
                    val named = uris.map { it to context.displayName(it) }
                    val styleURI = named.singleOrNull { it.second.endsWith(".json", true) }?.first
                        ?: error("Select exactly one .json style")
                    val archiveURI = named.singleOrNull { it.second.endsWith(".pmtiles", true) }?.first
                        ?: error("Select exactly one .pmtiles archive")
                    if (uris.size != 2) error("Select exactly one .json style and one .pmtiles archive")
                    val styleBytes = context.contentResolver.openInputStream(styleURI)?.use {
                        it.readUpTo(OfflineMapPack.MAXIMUM_STYLE_BYTES + 1)
                    } ?: error("The selected style could not be read")
                    if (styleBytes.size > OfflineMapPack.MAXIMUM_STYLE_BYTES) {
                        error("Map style exceeds 2 MiB")
                    }
                    temporaryArchive = File(
                        context.cacheDir,
                        "map-import-${UUID.randomUUID()}.pmtiles",
                    )
                    context.contentResolver.openInputStream(archiveURI)?.use { input ->
                        temporaryArchive!!.outputStream().buffered().use(input::copyTo)
                    } ?: error("The selected PMTiles archive could not be read")
                    OfflineMapImport(styleBytes, temporaryArchive!!)
                }
                pickerError = null
                vm.importOfflineMap(import)
            } catch (error: Exception) {
                temporaryArchive?.let { if (it.exists() && !it.delete()) Unit }
                pickerError = error.message ?: error.javaClass.simpleName
            }
        }
    }

    LaunchedEffect(presentation?.stateVersion) {
        guestMinimizedSlide = false
        if (activeChannel?.createdBy != vm.localPeerID) {
            if (presentation?.isVisible == true) {
                selectedFeature = TourFeature.SLIDES
            }
        }
    }
    LaunchedEffect(target?.stateVersion) {
        if (activeChannel?.createdBy != vm.localPeerID && target?.isVisible == true) {
            selectedFeature = TourFeature.MAP
        }
    }
    LaunchedEffect(bearing?.stateVersion) {
        if (activeChannel?.createdBy != vm.localPeerID && bearing?.isVisible == true) {
            selectedFeature = TourFeature.POINTER
        }
    }
    LaunchedEffect(visualFocus?.stateVersion, activeChannelID) {
        if (activeChannel?.createdBy != vm.localPeerID) {
            visualFocus?.mode?.let { selectedFeature = TourFeature.from(it) }
        }
    }
    LaunchedEffect(selectedFeature, activeChannelID) {
        if (activeChannelID == null) return@LaunchedEffect
        when (selectedFeature) {
            TourFeature.MAP -> requestLocalGuidance()
            TourFeature.POINTER -> vm.localGuidanceService.startHeadingOnly()
            TourFeature.SLIDES -> Unit
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Megaphone") },
                actions = {
                    IconButton(onClick = requestOpenWiFiAwareLab) {
                        Icon(Icons.Default.WifiTethering, "Wi-Fi Aware Lab")
                    }
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
                    CreatorView(
                        channel = activeChannel!!,
                        listenerCount = listenerCount,
                        connectedGuestCount = connectedGuestCount,
                        readyParticipantCount = readyParticipantCount,
                        tourCode = tourCode,
                        presentation = presentation,
                        slides = slides,
                        readySlideFiles = readySlideFiles,
                        isImportingSlides = isImportingSlides,
                        isImportingMap = isImportingMap,
                        selectedFeature = selectedFeature,
                        onFeatureChange = {
                            selectedFeature = it
                            vm.setVisualFocus(it.visualMode)
                        },
                        mapConfiguration = offlineMapConfiguration,
                        offlineMapStatus = offlineMapStatus,
                        target = target,
                        bearing = bearing,
                        localGuidanceStatus = localGuidanceStatus,
                        localPosition = localPosition,
                        localMagneticHeading = localMagneticHeading,
                        headingAccuracy = headingAccuracy,
                        guidance = target?.takeIf { it.isVisible }?.let {
                            LocalTargetGuidance.calculate(
                                localPosition?.latitude ?: return@let null,
                                localPosition?.longitude ?: return@let null,
                                localHeading,
                                it,
                            )
                        },
                        error = pickerError ?: tourFeatureError,
                        onPickSlides = {
                            photoPicker.launch(
                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                            )
                        },
                        onPickMap = { mapPicker.launch(arrayOf("application/json", "application/octet-stream")) },
                        onRequestLocation = requestLocalGuidance,
                        vm = vm,
                    )
                } else {
                    ListenerView(
                        channel = activeChannel!!,
                        listenerOutput = listenerOutput,
                        connectionState = connectionState,
                        reconnectAttempt = reconnectAttempt,
                        tourFeatureError = tourFeatureError,
                        speakerFeedbackWarning = speakerFeedbackWarning,
                        presentation = presentation,
                        readySlideFiles = readySlideFiles,
                        minimizedSlide = guestMinimizedSlide,
                        onMinimizedChange = { guestMinimizedSlide = it },
                        selectedFeature = selectedFeature,
                        onFeatureChange = { selectedFeature = it },
                        mapConfiguration = offlineMapConfiguration,
                        offlineMapStatus = offlineMapStatus,
                        target = target,
                        bearing = bearing,
                        localGuidanceStatus = localGuidanceStatus,
                        localPosition = localPosition,
                        localMagneticHeading = localMagneticHeading,
                        headingAccuracy = headingAccuracy,
                        guidance = target?.takeIf { it.isVisible }?.let {
                            LocalTargetGuidance.calculate(
                                localPosition?.latitude ?: return@let null,
                                localPosition?.longitude ?: return@let null,
                                localHeading,
                                it,
                            )
                        },
                        onRequestLocation = requestLocalGuidance,
                        vm = vm,
                    )
                }
            } else {
                if (connectionState == SessionConnectionState.FAILED) {
                    tourFeatureError?.let { error ->
                        Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
                            Text("Could not start tour", style = MaterialTheme.typography.titleSmall)
                            Text(error, color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
                ChannelListView(channels, vm.localPeerID) { channel ->
                    pendingJoinChannel = channel
                    joinCode = ""
                }
                if (channels.isEmpty()) {
                    EmptyState { showCreateDialog = true }
                }
            }
        }
    }

    if (showCreateDialog) {
        AlertDialog(
            onDismissRequest = { showCreateDialog = false; newChannelName = ""; createError = null },
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
                    createError?.let {
                        Spacer(Modifier.height(8.dp))
                        Text(it, color = MaterialTheme.colorScheme.error)
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    requestCreateChannel(newChannelName)
                }) { Text("Create") }
            },
            dismissButton = {
                TextButton(onClick = { showCreateDialog = false; newChannelName = ""; createError = null }) {
                    Text("Cancel")
                }
            }
        )
    }

    pendingJoinChannel?.let { channel ->
        AlertDialog(
            onDismissRequest = { pendingJoinChannel = null; joinCode = "" },
            title = { Text(channel.name) },
            text = {
                Column {
                    Text("Enter the tour code shown on the guide's screen.")
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = joinCode,
                        onValueChange = { joinCode = it.uppercase() },
                        label = { Text("10-character tour code") },
                        singleLine = true,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        vm.joinChannel(channel, joinCode)
                        pendingJoinChannel = null
                        joinCode = ""
                    },
                    enabled = SessionCredential.normalize(joinCode).length == SessionCredential.SHORT_CODE_LENGTH,
                ) { Text("Join") }
            },
            dismissButton = {
                TextButton(onClick = { pendingJoinChannel = null; joinCode = "" }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun ChannelListView(
    channels: List<Channel>,
    localPeerID: String,
    onJoin: (Channel) -> Unit
) {
    LazyColumn(modifier = Modifier.fillMaxWidth()) {
        item {
            Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                Text(
                    "Live Megaphones",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.primary
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
private fun CreatorView(
    channel: Channel,
    listenerCount: Int,
    connectedGuestCount: Int,
    readyParticipantCount: Int,
    tourCode: String?,
    presentation: PresentationSnapshotPayload?,
    slides: List<TourAssetDescriptor>,
    readySlideFiles: Map<String, File>,
    isImportingSlides: Boolean,
    isImportingMap: Boolean,
    selectedFeature: TourFeature,
    onFeatureChange: (TourFeature) -> Unit,
    mapConfiguration: OfflineMapConfiguration?,
    offlineMapStatus: OfflineMapStatus,
    target: TargetSnapshotPayload?,
    bearing: BearingSnapshotPayload?,
    localGuidanceStatus: LocalGuidanceStatus,
    localPosition: LocalDevicePosition?,
    localMagneticHeading: Double?,
    headingAccuracy: Int?,
    guidance: LocalTargetGuidance?,
    error: String?,
    onPickSlides: () -> Unit,
    onPickMap: () -> Unit,
    onRequestLocation: () -> Unit,
    vm: AppViewModel,
) {
    val scale by animateFloatAsState(1.1f, label = "pulse")
    Column(
        Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Default.Campaign, null,
                Modifier.size(36.dp).scale(scale),
                tint = MaterialTheme.colorScheme.error,
            )
            Spacer(Modifier.width(12.dp))
            Column {
                Text(channel.name, style = MaterialTheme.typography.titleLarge)
                Text("LIVE", color = MaterialTheme.colorScheme.error)
            }
            Spacer(Modifier.weight(1f))
            Text(
                "$connectedGuestCount connected · $listenerCount audio",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.outline,
            )
            Spacer(Modifier.width(12.dp))
            Text(
                "$readyParticipantCount content ready",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
            )
        }

        if (tourCode != null) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("TOUR CODE", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.outline)
                Spacer(Modifier.width(12.dp))
                Text(tourCode, style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.weight(1f))
                Text("Share with guests", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline)
            }
        }

        HorizontalDivider()

        TourFeatureSelector(selectedFeature, onFeatureChange)

        if (error != null) {
            Text(
                error,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            )
        }

        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (selectedFeature) {
                TourFeature.SLIDES -> CreatorSlides(
                    presentation,
                    slides,
                    readySlideFiles,
                    isImportingSlides,
                    onPickSlides,
                    vm,
                )
                TourFeature.MAP -> MapFeatureStage(
                    configuration = mapConfiguration,
                    status = offlineMapStatus,
                    target = target,
                    localGuidanceStatus = localGuidanceStatus,
                    localPosition = localPosition,
                    guidance = guidance,
                    isGuide = true,
                    isImporting = isImportingMap,
                    onPickMap = onPickMap,
                    onClearTarget = vm::clearTarget,
                    onTargetPlaced = vm::setTarget,
                    onRequestLocation = onRequestLocation,
                )
                TourFeature.POINTER -> PointerFeatureStage(
                    bearing = bearing,
                    magneticHeading = localMagneticHeading,
                    headingAccuracy = headingAccuracy,
                    isGuide = true,
                    onShare = vm::shareCurrentBearing,
                    onClear = vm::clearBearing,
                )
            }
        }

        HorizontalDivider()
        Row(Modifier.fillMaxWidth().padding(16.dp)) {
            Spacer(Modifier.weight(1f))
            Button(
                onClick = { vm.leaveChannel() },
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
            ) {
                Icon(Icons.Default.Close, null)
                Spacer(Modifier.width(8.dp))
                Text("End Tour")
            }
        }
    }
}

@Composable
private fun CreatorSlides(
    presentation: PresentationSnapshotPayload?,
    slides: List<TourAssetDescriptor>,
    readySlideFiles: Map<String, File>,
    isImportingSlides: Boolean,
    onPickSlides: () -> Unit,
    vm: AppViewModel,
) {
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        if (slides.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Default.PhotoLibrary, null, Modifier.size(64.dp), tint = MaterialTheme.colorScheme.outline)
                    Spacer(Modifier.height(12.dp))
                    Text("No slides", style = MaterialTheme.typography.headlineSmall)
                    Text("Choose photos to prepare and send locally.", color = MaterialTheme.colorScheme.outline)
                    Spacer(Modifier.height(20.dp))
                    Button(onClick = onPickSlides, enabled = !isImportingSlides) {
                        Icon(Icons.Default.AddPhotoAlternate, null)
                        Spacer(Modifier.width(8.dp))
                        Text("Add Slides")
                    }
                }
            }
        } else {
            val currentID = presentation?.currentSlideID ?: slides.first().assetID
            readySlideFiles[currentID]?.let { file ->
                SlideFileImage(file, Modifier.weight(1f).fillMaxWidth().padding(16.dp))
            } ?: Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.SpaceEvenly,
            ) {
                OutlinedButton(vm::previousSlide, enabled = slides.indexOfFirst { it.assetID == currentID } > 0) {
                    Icon(Icons.Default.SkipPrevious, null)
                    Text("Previous")
                }
                Button(onClick = {
                    if (presentation?.isVisible == true) vm.hideSlides() else vm.showSlide()
                }) {
                    Icon(if (presentation?.isVisible == true) Icons.Default.VisibilityOff else Icons.Default.PlayArrow, null)
                    Text(if (presentation?.isVisible == true) "Hide" else "Show")
                }
                OutlinedButton(vm::nextSlide, enabled = slides.indexOfFirst { it.assetID == currentID } < slides.lastIndex) {
                    Text("Next")
                    Icon(Icons.Default.SkipNext, null)
                }
            }
            val currentIndex = slides.indexOfFirst { it.assetID == currentID }
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.Center,
            ) {
                TextButton(
                    onClick = { vm.moveSlide(currentID, currentIndex - 1) },
                    enabled = currentIndex > 0,
                ) {
                    Icon(Icons.Default.ArrowBack, null)
                    Text("Earlier")
                }
                TextButton(
                    onClick = { vm.moveSlide(currentID, currentIndex + 1) },
                    enabled = currentIndex in 0 until slides.lastIndex,
                ) {
                    Text("Later")
                    Icon(Icons.Default.ArrowForward, null)
                }
                TextButton(onClick = { vm.removeSlide(currentID) }) {
                    Icon(Icons.Default.Delete, null)
                    Text("Remove")
                }
            }
            LazyRow(
                Modifier.fillMaxWidth().height(84.dp).padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                rowItems(slides, key = { it.assetID }) { slide ->
                    readySlideFiles[slide.assetID]?.let { file ->
                        Surface(
                            onClick = { vm.showSlide(slide.assetID) },
                            shape = MaterialTheme.shapes.small,
                            border = if (slide.assetID == currentID) {
                                androidx.compose.foundation.BorderStroke(3.dp, MaterialTheme.colorScheme.primary)
                            } else null,
                        ) { SlideFileImage(file, Modifier.size(width = 92.dp, height = 64.dp)) }
                    }
                }
                item {
                    OutlinedButton(onPickSlides, enabled = !isImportingSlides, modifier = Modifier.height(64.dp)) {
                        Icon(Icons.Default.AddPhotoAlternate, "Add slides")
                    }
                }
            }
        }
        if (isImportingSlides) LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

@Composable
private fun ListenerView(
    channel: Channel,
    listenerOutput: ListenerOutput,
    connectionState: SessionConnectionState,
    reconnectAttempt: Int,
    tourFeatureError: String?,
    speakerFeedbackWarning: String?,
    presentation: PresentationSnapshotPayload?,
    readySlideFiles: Map<String, File>,
    minimizedSlide: Boolean,
    onMinimizedChange: (Boolean) -> Unit,
    selectedFeature: TourFeature,
    onFeatureChange: (TourFeature) -> Unit,
    mapConfiguration: OfflineMapConfiguration?,
    offlineMapStatus: OfflineMapStatus,
    target: TargetSnapshotPayload?,
    bearing: BearingSnapshotPayload?,
    localGuidanceStatus: LocalGuidanceStatus,
    localPosition: LocalDevicePosition?,
    localMagneticHeading: Double?,
    headingAccuracy: Int?,
    guidance: LocalTargetGuidance?,
    onRequestLocation: () -> Unit,
    vm: AppViewModel,
) {
    Column(
        Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Default.Headphones, null,
                Modifier.size(36.dp),
                tint = MaterialTheme.colorScheme.primary,
            )
            Spacer(Modifier.width(12.dp))
            Column {
                Text(channel.name, style = MaterialTheme.typography.titleLarge)
                Text(
                    guestConnectionStatusText(connectionState, reconnectAttempt, tourFeatureError),
                    color = if (connectionState == SessionConnectionState.FAILED) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.primary
                    },
                )
            }
        }

        HorizontalDivider()

        TourFeatureSelector(selectedFeature, onFeatureChange)

        when (selectedFeature) {
            TourFeature.SLIDES -> ListenerSlides(
                presentation,
                readySlideFiles,
                minimizedSlide,
                onMinimizedChange,
                Modifier.weight(1f),
            )
            TourFeature.MAP -> MapFeatureStage(
                    configuration = mapConfiguration,
                    status = offlineMapStatus,
                    target = target,
                    localGuidanceStatus = localGuidanceStatus,
                    localPosition = localPosition,
                    guidance = guidance,
                    isGuide = false,
                    isImporting = false,
                    onPickMap = {},
                    onClearTarget = {},
                    onTargetPlaced = { _, _, _ -> },
                    onRequestLocation = onRequestLocation,
                    modifier = Modifier.weight(1f),
                )
            TourFeature.POINTER -> PointerFeatureStage(
                bearing = bearing,
                magneticHeading = localMagneticHeading,
                headingAccuracy = headingAccuracy,
                isGuide = false,
                onShare = {},
                onClear = {},
                modifier = Modifier.weight(1f),
            )
        }

        HorizontalDivider()
        speakerFeedbackWarning?.let {
            Text(
                it,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
        // FAILED already renders the reason in the header status line (ADR-041).
        if (connectionState != SessionConnectionState.FAILED) {
            tourFeatureError?.let {
                Text(
                    it,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FilledTonalButton(onClick = { vm.setListenerOutput(listenerOutput.toggled()) }) {
                Icon(
                    if (listenerOutput == ListenerOutput.PRIVATE_AUDIO) {
                        Icons.Default.Headphones
                    } else {
                        Icons.AutoMirrored.Filled.VolumeUp
                    },
                    contentDescription = null,
                )
                Spacer(Modifier.width(8.dp))
                Text(if (listenerOutput == ListenerOutput.PRIVATE_AUDIO) "Earpiece" else "Speaker")
            }
            Spacer(Modifier.weight(1f))
            OutlinedButton(
                onClick = { vm.leaveChannel() },
            ) {
                Icon(Icons.AutoMirrored.Filled.ExitToApp, null)
                Spacer(Modifier.width(8.dp))
                Text("Leave Channel")
            }
        }
    }
}

@Composable
private fun ListenerSlides(
    presentation: PresentationSnapshotPayload?,
    readySlideFiles: Map<String, File>,
    minimizedSlide: Boolean,
    onMinimizedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val slideID = presentation?.currentSlideID
    Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        when {
            presentation?.isVisible != true || slideID == null -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Default.Headphones, null, Modifier.size(72.dp), tint = MaterialTheme.colorScheme.outline)
                Spacer(Modifier.height(12.dp))
                Text("Listening to the guide", style = MaterialTheme.typography.headlineSmall)
                Text("Slides appear here when presented.", color = MaterialTheme.colorScheme.outline)
            }
            minimizedSlide -> Button(onClick = { onMinimizedChange(false) }) {
                Icon(Icons.Default.Photo, null)
                Spacer(Modifier.width(8.dp))
                Text("Show Slide")
            }
            readySlideFiles[slideID] != null -> Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
                SlideFileImage(readySlideFiles.getValue(slideID), Modifier.weight(1f).fillMaxWidth().padding(16.dp))
                OutlinedButton(onClick = { onMinimizedChange(true) }) {
                    Icon(Icons.Default.ExpandMore, null)
                    Text("Minimize")
                }
            }
            else -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator()
                Spacer(Modifier.height(12.dp))
                Text("Preparing slide…")
            }
        }
    }
}

private enum class TourFeature(val visualMode: TourVisualMode) {
    SLIDES(TourVisualMode.SLIDES),
    MAP(TourVisualMode.MAP),
    POINTER(TourVisualMode.POINTER);

    companion object {
        fun from(mode: TourVisualMode): TourFeature = entries.first { it.visualMode == mode }
    }
}

@Composable
private fun TourFeatureSelector(selected: TourFeature, onSelected: (TourFeature) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FilterChip(
            selected = selected == TourFeature.SLIDES,
            onClick = { onSelected(TourFeature.SLIDES) },
            label = { Text("Slides") },
            leadingIcon = { Icon(Icons.Default.PhotoLibrary, null) },
            modifier = Modifier.weight(1f),
        )
        FilterChip(
            selected = selected == TourFeature.MAP,
            onClick = { onSelected(TourFeature.MAP) },
            label = { Text("Map") },
            leadingIcon = { Icon(Icons.Default.Map, null) },
            modifier = Modifier.weight(1f),
        )
        FilterChip(
            selected = selected == TourFeature.POINTER,
            onClick = { onSelected(TourFeature.POINTER) },
            label = { Text("Pointer") },
            leadingIcon = { Icon(Icons.Default.Navigation, null) },
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun PointerFeatureStage(
    bearing: BearingSnapshotPayload?,
    magneticHeading: Double?,
    headingAccuracy: Int?,
    isGuide: Boolean,
    onShare: () -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val sharedDegrees = bearing?.bearingMilliDegrees?.div(1_000.0)
    val relativeDegrees = if (bearing?.isVisible == true && sharedDegrees != null && magneticHeading != null) {
        TargetGuidance.relativeArrowDegrees(sharedDegrees, magneticHeading)
    } else {
        null
    }
    val arrowRotation by animateFloatAsState((relativeDegrees ?: 0.0).toFloat(), label = "pointer")

    Column(
        modifier.fillMaxSize().padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (isGuide) {
            if (magneticHeading == null) {
                if (headingAccuracy == android.hardware.SensorManager.SENSOR_STATUS_UNRELIABLE) {
                    Icon(
                        Icons.Default.LocationDisabled,
                        contentDescription = null,
                        modifier = Modifier.size(72.dp),
                        tint = MaterialTheme.colorScheme.error,
                    )
                    Spacer(Modifier.height(12.dp))
                    Text("Compass unavailable", style = MaterialTheme.typography.headlineSmall)
                    Text("This device cannot provide a reliable heading.")
                } else {
                    CircularProgressIndicator()
                    Spacer(Modifier.height(12.dp))
                    Text("Reading compass…")
                }
            } else {
                Icon(
                    Icons.Default.Navigation,
                    contentDescription = null,
                    modifier = Modifier.size(120.dp),
                    tint = MaterialTheme.colorScheme.tertiary,
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    "${magneticHeading.toInt()}° magnetic",
                    style = MaterialTheme.typography.headlineMedium,
                )
                headingAccuracy?.let {
                    Text(
                        if (it == android.hardware.SensorManager.SENSOR_STATUS_ACCURACY_HIGH) {
                            "Compass accuracy: high"
                        } else {
                            "Compass accuracy: limited"
                        },
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
                Spacer(Modifier.height(20.dp))
                Button(onClick = onShare) {
                    Icon(Icons.Default.Explore, null)
                    Spacer(Modifier.width(8.dp))
                    Text("Point Guests This Way")
                }
            }
            if (bearing?.isVisible == true) {
                Spacer(Modifier.height(12.dp))
                OutlinedButton(onClick = onClear) {
                    Icon(Icons.Default.StopCircle, null)
                    Spacer(Modifier.width(8.dp))
                    Text("Stop Pointer")
                }
            }
            Spacer(Modifier.height(24.dp))
            Text(
                "Only the selected bearing angle is shared. Device location and guest compass readings stay local.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
            )
        } else if (bearing?.isVisible == true && sharedDegrees != null) {
            Icon(
                Icons.Default.Navigation,
                contentDescription = "Direction selected by guide",
                modifier = Modifier.size(160.dp).rotate(arrowRotation),
                tint = MaterialTheme.colorScheme.tertiary,
            )
            Spacer(Modifier.height(16.dp))
            Text(
                when {
                    headingAccuracy == android.hardware.SensorManager.SENSOR_STATUS_UNRELIABLE -> "Compass unavailable"
                    relativeDegrees == null -> "Reading compass…"
                    else -> "Look this way"
                },
                style = MaterialTheme.typography.headlineMedium,
            )
            Text(
                "Guide bearing ${sharedDegrees.toInt()}° magnetic",
                color = MaterialTheme.colorScheme.outline,
            )
            Text(
                when (headingAccuracy) {
                    null -> "Compass accuracy unavailable"
                    android.hardware.SensorManager.SENSOR_STATUS_ACCURACY_HIGH -> "Compass accuracy: high"
                    android.hardware.SensorManager.SENSOR_STATUS_UNRELIABLE -> "Compass accuracy: unreliable"
                    else -> "Compass accuracy: limited"
                },
                color = if (
                    headingAccuracy == android.hardware.SensorManager.SENSOR_STATUS_ACCURACY_HIGH
                ) {
                    MaterialTheme.colorScheme.outline
                } else {
                    MaterialTheme.colorScheme.tertiary
                },
            )
            Spacer(Modifier.height(24.dp))
            Text(
                "Your compass reading stays on this device.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
            )
        } else {
            Icon(
                Icons.Default.Explore,
                contentDescription = null,
                modifier = Modifier.size(72.dp),
                tint = MaterialTheme.colorScheme.outline,
            )
            Spacer(Modifier.height(12.dp))
            Text("No active pointer", style = MaterialTheme.typography.headlineSmall)
            Text("The guide can point everyone toward the same sightline.")
        }
    }
}

@Composable
private fun MapFeatureStage(
    configuration: OfflineMapConfiguration?,
    status: OfflineMapStatus,
    target: TargetSnapshotPayload?,
    localGuidanceStatus: LocalGuidanceStatus,
    localPosition: LocalDevicePosition?,
    guidance: LocalTargetGuidance?,
    isGuide: Boolean,
    isImporting: Boolean,
    onPickMap: () -> Unit,
    onClearTarget: () -> Unit,
    onTargetPlaced: (Double, Double, String) -> Unit,
    onRequestLocation: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var pendingTarget by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    var targetLabelDraft by remember { mutableStateOf("") }
    if (configuration == null) {
        Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                if (isImporting) {
                    CircularProgressIndicator()
                    Spacer(Modifier.height(12.dp))
                    Text("Preparing offline map…")
                } else if (!isGuide) {
                    val title: String
                    val detail: String?
                    when (status) {
                        OfflineMapStatus.Unavailable -> {
                            title = "No offline map"
                            detail = "The guide has not added an offline map to this tour."
                        }
                        OfflineMapStatus.Transferring -> {
                            title = "Preparing offline map"
                            detail = "The verified map appears when its local transfer completes."
                        }
                        OfflineMapStatus.Ready -> {
                            title = "Opening offline map"
                            detail = null
                        }
                        is OfflineMapStatus.Failed -> {
                            title = "Offline map unavailable"
                            detail = status.message
                        }
                    }
                    if (status == OfflineMapStatus.Transferring || status == OfflineMapStatus.Ready) {
                        CircularProgressIndicator()
                    } else {
                        Icon(Icons.Default.Map, null, Modifier.size(64.dp), tint = MaterialTheme.colorScheme.outline)
                    }
                    Spacer(Modifier.height(12.dp))
                    Text(title, style = MaterialTheme.typography.headlineSmall)
                    if (detail != null) {
                        Text(detail, color = MaterialTheme.colorScheme.outline)
                    }
                } else {
                    Icon(Icons.Default.Map, null, Modifier.size(64.dp), tint = MaterialTheme.colorScheme.outline)
                    Spacer(Modifier.height(12.dp))
                    Text("No offline map", style = MaterialTheme.typography.headlineSmall)
                    Text(
                        "Select one style JSON and one PMTiles v3 archive.",
                        color = MaterialTheme.colorScheme.outline,
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Style source: ${OfflineMapPack.ARCHIVE_PLACEHOLDER}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.outline,
                    )
                    Spacer(Modifier.height(20.dp))
                    Button(onClick = onPickMap) {
                        Icon(Icons.Default.FileOpen, null)
                        Spacer(Modifier.width(8.dp))
                        Text("Import Offline Map")
                    }
                }
            }
        }
        return
    }

    Column(modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        if (target?.isVisible == true) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    if (guidance?.relativeArrowDegrees != null) Icons.Default.Navigation else Icons.Default.LocationOn,
                    null,
                    Modifier.size(28.dp).rotate(guidance?.relativeArrowDegrees?.toFloat() ?: 0f),
                    tint = MaterialTheme.colorScheme.error,
                )
                Spacer(Modifier.width(10.dp))
                Column {
                    Text(target.label.ifBlank { "Guide target" }, style = MaterialTheme.typography.titleSmall)
                    Text(
                        guidance?.let { distanceText(it.distanceMeters) }
                            ?: when (localGuidanceStatus) {
                                LocalGuidanceStatus.IDLE -> "Enable location for local distance and direction"
                                LocalGuidanceStatus.NEEDS_PERMISSION ->
                                    "Location permission is required for local distance and direction"
                                LocalGuidanceStatus.LOCATING -> "Finding your location…"
                                LocalGuidanceStatus.READY -> "Location is temporarily unavailable"
                                LocalGuidanceStatus.UNAVAILABLE -> "Location is unavailable; check device location settings"
                            },
                        color = MaterialTheme.colorScheme.outline,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                Spacer(Modifier.weight(1f))
                if (localPosition == null) TextButton(onClick = onRequestLocation) { Text("Enable") }
            }
        } else {
            Text(
                if (isGuide) "Long-press to share a target" else "Waiting for the guide to place a target",
                color = MaterialTheme.colorScheme.outline,
                modifier = Modifier.padding(vertical = 8.dp),
            )
        }
        OfflineTourMap(
            configuration,
            target,
            localPosition,
            isGuide,
            onTargetPlaced = { latitude, longitude ->
                targetLabelDraft = target?.label.orEmpty()
                pendingTarget = latitude to longitude
            },
            modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 12.dp),
        )
        Text(
            if (isGuide) {
                "Long-press the map to place or move the guest target."
            } else {
                "Your location stays on this device. Only the target pin is shared."
            },
            color = MaterialTheme.colorScheme.outline,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(8.dp),
        )
        if (isGuide) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onPickMap) {
                    Icon(Icons.Default.FileOpen, null)
                    Text("Replace Map")
                }
                if (target?.isVisible == true) {
                    OutlinedButton(onClick = {
                        targetLabelDraft = target.label
                        pendingTarget = target.latitudeE7 / 10_000_000.0 to
                            target.longitudeE7 / 10_000_000.0
                    }) {
                        Icon(Icons.Default.Edit, null)
                        Text("Edit Label")
                    }
                    OutlinedButton(onClick = onClearTarget) {
                        Icon(Icons.Default.LocationOff, null)
                        Text("Clear Target")
                    }
                }
            }
        }
    }

    pendingTarget?.let { coordinate ->
        AlertDialog(
            onDismissRequest = { pendingTarget = null },
            title = { Text("Share Target Pin") },
            text = {
                Column {
                    Text("Only this selected pin and its label will be sent to guests.")
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = targetLabelDraft,
                        onValueChange = { targetLabelDraft = it.take(256) },
                        label = { Text("Optional label") },
                        singleLine = true,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    onTargetPlaced(coordinate.first, coordinate.second, targetLabelDraft)
                    pendingTarget = null
                }) { Text("Share") }
            },
            dismissButton = {
                TextButton(onClick = { pendingTarget = null }) { Text("Cancel") }
            },
        )
    }
}

private fun distanceText(meters: Double): String =
    if (meters < 1_000) "${meters.toInt()} m away" else "%.1f km away".format(meters / 1_000)

private fun Context.displayName(uri: Uri): String {
    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) return cursor.getString(0)
    }
    return uri.lastPathSegment ?: ""
}

@Composable
private fun SlideFileImage(file: File, modifier: Modifier = Modifier) {
    val bitmap by produceState<androidx.compose.ui.graphics.ImageBitmap?>(null, file.path) {
        value = withContext(Dispatchers.IO) {
            BitmapFactory.decodeFile(file.path)?.asImageBitmap()
        }
    }
    Surface(modifier, shape = MaterialTheme.shapes.large, tonalElevation = 1.dp) {
        if (bitmap != null) {
            Image(
                bitmap = bitmap!!,
                contentDescription = "Tour slide",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Fit,
            )
        } else {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        }
    }
}
