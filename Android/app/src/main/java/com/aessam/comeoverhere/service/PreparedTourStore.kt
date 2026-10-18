package com.aessam.comeoverhere.service

import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TourAssetKind
import com.aessam.toursession.TourPackArchive
import com.aessam.toursession.TourPackManifestPayload
import com.aessam.toursession.lowercaseHex
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class PreparedTourException(message: String) : IllegalStateException(message)

/** Everything `ChannelService.createChannel(..., prepared)` needs to present a prepared tour. */
data class PreparedTourLaunch(val manifest: TourPackManifestPayload, val sourcesByAssetID: Map<String, File>)

/**
 * Tours a guide prepares before going live (ADR-080 DSCN-1); mirrors the iOS `PreparedTourStore`.
 * Each tour lives in `<root>/<packID>/`: `manifest.goh` holds the `TourPackManifestPayload` bytes and
 * `assets/<sha256>` holds each file once. Going live publishes the same descriptors, so guests that
 * imported the shared `.gohtour` already hold every hash.
 */
class PreparedTourStore(private val root: File) {
    private val mutableTours = MutableStateFlow(load())
    val tours: StateFlow<List<TourPackManifestPayload>> = mutableTours.asStateFlow()

    @Synchronized
    fun create(name: String): TourPackManifestPayload =
        TourPackManifestPayload(UUID.randomUUID(), 1, name, emptyList()).also(::save)

    /** Appends slides in order. Each call bumps the manifest version, which the room record advertises. */
    @Synchronized
    fun addSlides(slides: List<SlideImport>, packID: UUID): TourPackManifestPayload {
        val current = tour(packID)
        val assets = current.assets.toMutableList()
        var order = if (assets.isEmpty()) 0L else assets.maxOf { it.order } + 1
        val directory = assetDirectory(packID).apply { mkdirs() }
        for (slide in slides) {
            val hash = MessageDigest.getInstance("SHA-256").digest(slide.bytes).lowercaseHex()
            val destination = File(directory, hash)
            if (!destination.exists()) {
                val temporary = File(directory, "$hash.tmp")
                temporary.writeBytes(slide.bytes)
                if (!temporary.renameTo(destination)) throw PreparedTourException("Could not store a slide of ${current.displayName}")
            }
            assets += TourAssetDescriptor(UUID.randomUUID().toString(), TourAssetKind.SLIDE, hash,
                slide.bytes.size.toLong(), order++, slide.mimeType)
        }
        return TourPackManifestPayload(packID, current.manifestVersion + 1, current.displayName, assets).also(::save)
    }

    @Synchronized
    fun remove(packID: UUID) {
        check(tourDirectory(packID).deleteRecursively()) { "Could not delete prepared tour $packID" }
        mutableTours.value = mutableTours.value.filter { it.packID != packID }
    }

    fun tour(packID: UUID): TourPackManifestPayload =
        tours.value.firstOrNull { it.packID == packID } ?: throw PreparedTourException("This prepared tour no longer exists")

    fun launch(packID: UUID): PreparedTourLaunch {
        val manifest = tour(packID)
        if (manifest.assets.isEmpty()) throw PreparedTourException("Add slides before sharing or going live")
        return PreparedTourLaunch(manifest, manifest.assets.associate { it.assetID to File(assetDirectory(packID), it.sha256) })
    }

    /** Writes `<name>.gohtour` into [directory], streaming each file once and re-checking its hash. */
    fun export(packID: UUID, directory: File): File {
        val manifest = tour(packID)
        if (manifest.assets.isEmpty()) throw PreparedTourException("Add slides before sharing or going live")
        val (prefix, layout) = TourPackArchive.prefix(manifest)
        val safeName = manifest.displayName.replace(Regex("[/:\\\\\u0000]"), "-").ifBlank { "Tour" }
        directory.mkdirs()
        val output = File(directory, "$safeName.gohtour")
        val whole = MessageDigest.getInstance("SHA-256")
        output.outputStream().buffered().use { sink ->
            sink.write(prefix)
            whole.update(prefix)
            val buffer = ByteArray(1 shl 20)
            for (entry in layout.entries) {
                val source = File(assetDirectory(packID), entry.sha256Hex)
                if (!source.isFile) throw PreparedTourException("A file of this tour is missing (${entry.sha256Hex.take(12)})")
                val fileDigest = MessageDigest.getInstance("SHA-256")
                var copied = 0L
                source.inputStream().use { input ->
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        sink.write(buffer, 0, count)
                        whole.update(buffer, 0, count)
                        fileDigest.update(buffer, 0, count)
                        copied += count
                    }
                }
                if (copied != entry.byteLength || !fileDigest.digest().contentEquals(entry.sha256)) {
                    throw PreparedTourException("A file of this tour changed on disk (${entry.sha256Hex.take(12)})")
                }
            }
            sink.write(whole.digest())
        }
        return output
    }

    private fun save(manifest: TourPackManifestPayload) {
        val directory = tourDirectory(manifest.packID).apply { mkdirs() }
        val temporary = File(directory, "manifest.goh.tmp")
        temporary.writeBytes(manifest.encode())
        if (!temporary.renameTo(File(directory, "manifest.goh"))) throw PreparedTourException("Could not save ${manifest.displayName}")
        mutableTours.value = (mutableTours.value.filter { it.packID != manifest.packID } + manifest)
            .sortedBy { it.displayName.lowercase() }
    }

    private fun tourDirectory(packID: UUID) = File(root, packID.toString())
    private fun assetDirectory(packID: UUID) = File(tourDirectory(packID), "assets")

    private fun load(): List<TourPackManifestPayload> {
        root.mkdirs()
        return (root.listFiles() ?: emptyArray())
            .filter { runCatching { UUID.fromString(it.name) }.isSuccess }
            .map { TourPackManifestPayload.decode(File(it, "manifest.goh").readBytes()) }
            .sortedBy { it.displayName.lowercase() }
    }
}
