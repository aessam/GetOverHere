package com.aessam.comeoverhere.ui

import android.content.Intent
import android.util.Log
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.aessam.comeoverhere.service.ChannelServiceProtocol
import com.aessam.comeoverhere.service.PdfSlideRenderer
import com.aessam.comeoverhere.service.PreparedTourStore
import com.aessam.toursession.TourAssetKind
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Tours prepared before going live (ADR-080 DSCN-1): build the deck offline, share it as a `.gohtour`
 * so guests arrive with every file, then go live from it. Mirrors the iOS PreparedToursView.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PreparedToursScreen(store: PreparedTourStore, channelService: ChannelServiceProtocol, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val tours by store.tours.collectAsState()
    val activeChannelID by channelService.activeChannelID.collectAsState()
    var showNewTour by remember { mutableStateOf(false) }
    var newTourName by remember { mutableStateOf("") }
    var pdfTarget by remember { mutableStateOf<UUID?>(null) }
    var busy by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    fun run(work: suspend () -> Unit) {
        scope.launch {
            busy = true
            try {
                work()
                errorMessage = null
            } catch (error: Exception) {
                Log.e("PreparedTours", "Prepared tour action failed (${error.javaClass.simpleName})")
                errorMessage = error.message ?: error.javaClass.simpleName
            } finally {
                busy = false
            }
        }
    }

    val pdfPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val packID = pdfTarget ?: return@rememberLauncherForActivityResult
        if (uri == null) return@rememberLauncherForActivityResult
        run {
            withContext(Dispatchers.IO) {
                val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: error("The PDF could not be read")
                val slides = PdfSlideRenderer.render(bytes, File(context.cacheDir, "pdf-render").apply { mkdirs() })
                store.addSlides(slides, packID)
            }
        }
    }

    BackHandler(onBack = onBack)
    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Prepared Tours") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            actions = { TextButton(onClick = { newTourName = ""; showNewTour = true }) { Text("New Tour") } },
        )
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (tours.isEmpty()) {
                item { Text("Create a tour, add a PDF, and share it with guests before you go live.", Modifier.padding(top = 24.dp)) }
            }
            items(tours, key = { it.packID }) { tour ->
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(tour.displayName, style = MaterialTheme.typography.titleMedium)
                        Text("${tour.assets.count { it.kind == TourAssetKind.SLIDE }} slides · version ${tour.manifestVersion}",
                            style = MaterialTheme.typography.bodySmall)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { pdfTarget = tour.packID; pdfPicker.launch(arrayOf("application/pdf")) }) { Text("Add PDF") }
                            OutlinedButton(enabled = tour.assets.isNotEmpty(), onClick = {
                                run {
                                    val file = withContext(Dispatchers.IO) {
                                        store.export(tour.packID, File(context.cacheDir, "shared-tours/${UUID.randomUUID()}"))
                                    }
                                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.sharedtours", file)
                                    val send = Intent(Intent.ACTION_SEND)
                                        .setType("application/vnd.getoverhere.tour")
                                        .putExtra(Intent.EXTRA_STREAM, uri)
                                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    context.startActivity(Intent.createChooser(send, "Share ${tour.displayName}"))
                                }
                            }) { Text("Share") }
                        }
                        Row {
                            TextButton(onClick = { run { withContext(Dispatchers.IO) { store.remove(tour.packID) } } }) { Text("Delete") }
                            Spacer(Modifier.weight(1f))
                            Button(enabled = tour.assets.isNotEmpty() && activeChannelID == null, onClick = {
                                run {
                                    channelService.createChannel(tour.displayName, prepared = store.launch(tour.packID))
                                    onBack()
                                }
                            }) { Text("Go Live") }
                        }
                    }
                }
            }
            errorMessage?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
            if (busy) item { Text("Working…", style = MaterialTheme.typography.bodySmall) }
        }
    }

    if (showNewTour) {
        AlertDialog(
            onDismissRequest = { showNewTour = false },
            title = { Text("New Tour") },
            text = { OutlinedTextField(newTourName, { newTourName = it }, label = { Text("Tour name") }, singleLine = true) },
            confirmButton = {
                TextButton(enabled = newTourName.isNotBlank(), onClick = {
                    showNewTour = false
                    run { withContext(Dispatchers.IO) { store.create(newTourName.trim()) } }
                }) { Text("Create") }
            },
            dismissButton = { TextButton(onClick = { showNewTour = false }) { Text("Cancel") } },
        )
    }
}
