package com.aessam.comeoverhere

import android.app.Application
import com.aessam.toursession.TourPackException
import com.aessam.toursession.TourPackArchive
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.flow.MutableStateFlow
import com.aessam.comeoverhere.service.TourPackLibrary
import com.aessam.comeoverhere.service.TourPackImporter
import android.net.Uri
import android.os.Build
import android.util.Log
import com.aessam.comeoverhere.core.LocalSessionAssetTransport
import com.aessam.comeoverhere.core.NetworkCoordinator
import com.aessam.comeoverhere.service.AudioEngine
import com.aessam.comeoverhere.service.ChannelService
import com.aessam.comeoverhere.service.FileTourAssetCache
import com.aessam.comeoverhere.service.ListenState
import com.aessam.comeoverhere.service.LocalGuidanceService
import com.aessam.comeoverhere.service.TourAssetTransferService
import com.aessam.comeoverhere.service.TourAudioForegroundService
import com.aessam.comeoverhere.service.TourContentStore
import com.aessam.comeoverhere.service.TourControlService
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

class ComeOverHereApp : Application() {
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var coordinator: NetworkCoordinator
    internal lateinit var audioEngine: AudioEngine
        private set
    lateinit var channelService: ChannelService
        private set
    lateinit var gateway: com.aessam.comeoverhere.service.GatewaySessionCoordinator
        private set
    lateinit var packLibrary: TourPackLibrary
        private set
    lateinit var preparedTours: com.aessam.comeoverhere.service.PreparedTourStore
        private set
    private lateinit var packImporter: TourPackImporter
    /** Result of the last `.gohtour` import, shown once to the user (ADR-080). */
    val packImportMessage = MutableStateFlow<String?>(null)
    /** One import at a time: concurrent imports would race on the same cache partials. */
    private val packImportLock = Mutex()

    override fun onCreate() {
        super.onCreate()
        coordinator = NetworkCoordinator(this, Build.MODEL, applicationScope)
        audioEngine = AudioEngine(this)
        val assetCache = FileTourAssetCache(File(filesDir, "asset-cache"))
        packImporter = TourPackImporter(assetCache)
        packLibrary = TourPackLibrary(File(filesDir, "imported-tour-packs.tsv"))
        preparedTours = com.aessam.comeoverhere.service.PreparedTourStore(File(filesDir, "prepared-tours"))
        channelService = ChannelService(
            coordinator,
            audioEngine,
            applicationScope,
            TourControlService(),
            TourAssetTransferService(
                LocalSessionAssetTransport(),
                assetCache,
            ),
            TourContentStore(File(filesDir, "tour-packs")),
            LocalGuidanceService(this),
            islandAdvertiserFactory = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_WIFI_AWARE)) {
                { com.aessam.comeoverhere.core.AwareIslandAdvertiser(this) }
            } else null,
        )
        coordinator.start()
        channelService.start()
        gateway = com.aessam.comeoverhere.service.GatewaySessionCoordinator(this, channelService, applicationScope)
        applicationScope.launch {
            combine(channelService.listenState, gateway.status) { audio, gateway -> audio to gateway }.collectLatest { (state, gatewayState) ->
                when (state) {
                    ListenState.BROADCASTING -> TourAudioForegroundService.startGuide(this@ComeOverHereApp,
                        gatewayState.role == com.aessam.comeoverhere.service.GatewayRole.GUIDE)
                    ListenState.LISTENING -> TourAudioForegroundService.startGuest(this@ComeOverHereApp)
                    ListenState.IDLE -> if (gatewayState.role == com.aessam.comeoverhere.service.GatewayRole.COMPANION)
                        TourAudioForegroundService.startCompanion(this@ComeOverHereApp)
                        else TourAudioForegroundService.stop(this@ComeOverHereApp)
                }
            }
        }
        Log.i(TAG, "Application tour services started")
    }

    companion object {
        private const val TAG = "ComeOverHereApp"
    }

    /**
     * Opens a shared `.gohtour` pack (ADR-080): copies it from the content URI to a private file, verifies
     * it, and stores each file under its hash so a later tour naming those hashes is ready without a transfer.
     */
    fun importTourPack(uri: Uri) {
        // Only shared content (Files, Mail, Nearby Share grant a read on a content URI). A file:// or one of this
        // app's own authorities could make the app read its private files on another app's behalf.
        if (uri.scheme != "content" || uri.authority?.startsWith(packageName) != false) {
            Log.e("ComeOverHereApp", "Rejected tour pack URI with scheme ${uri.scheme}")
            packImportMessage.value = "This tour file could not be opened: unsupported source"
            return
        }
        applicationScope.launch(Dispatchers.IO) {
            packImportLock.withLock { importTourPackLocked(uri) }
        }
    }

    private fun importTourPackLocked(uri: Uri) {
            val copy = File(cacheDir, "import-${java.util.UUID.randomUUID()}.gohtour")
            try {
                val input = contentResolver.openInputStream(uri) ?: error("The shared tour file could not be read")
                input.use { source -> copy.outputStream().use { copyBounded(source, it) } }
                val outcome = packImporter.importPack(copy)
                packLibrary.record(outcome.manifest)
                packImportMessage.value = "Tour ready: ${outcome.manifest.displayName} (${outcome.imported + outcome.alreadyCached} files)"
            } catch (error: Exception) {
                Log.e("ComeOverHereApp", "Tour pack import failed (${error.javaClass.simpleName}: ${error.message})")
                packImportMessage.value = "This tour file could not be opened: ${error.message ?: error.javaClass.simpleName}"
            } finally {
                if (copy.exists() && !copy.delete()) Log.e("ComeOverHereApp", "Could not delete $copy")
            }
    }

    /** Copies at most the format's maximum pack size, so an endless or oversized stream cannot fill storage. */
    private fun copyBounded(source: java.io.InputStream, target: java.io.OutputStream) {
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val count = source.read(buffer)
            if (count < 0) return
            total += count
            if (total > TourPackArchive.MAXIMUM_TOTAL_LENGTH) throw TourPackException("packTooLarge", "$total")
            target.write(buffer, 0, count)
        }
    }
}
