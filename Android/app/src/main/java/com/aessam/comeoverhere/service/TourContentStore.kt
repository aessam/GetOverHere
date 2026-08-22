package com.aessam.comeoverhere.service

import com.aessam.toursession.TourAssetDescriptor
import com.aessam.toursession.TourAssetKind
import com.aessam.toursession.TourPackManifestPayload
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID

class TourContentStoreException(message: String) : IllegalStateException(message)

class TourContentStore(
    private val rootDirectory: File,
) {
    var packID: UUID? = null
        private set
    var displayName: String = ""
        private set
    var manifestVersion: Long = 0
        private set
    var assets: List<TourAssetDescriptor> = emptyList()
        private set
    var sourcesByAssetID: Map<String, File> = emptyMap()
        private set

    private var nextSlideOrder = 0L

    init {
        ensureDirectory(rootDirectory)
    }

    @Synchronized
    fun beginPack(packID: UUID, displayName: String) {
        ensureDirectory(sourceDirectory(packID))
        this.packID = packID
        this.displayName = displayName
        manifestVersion = 0
        assets = emptyList()
        sourcesByAssetID = emptyMap()
        nextSlideOrder = 0
    }

    @Synchronized
    fun importSlide(bytes: ByteArray, mimeType: String): TourAssetDescriptor {
        val activePackID = packID ?: throw TourContentStoreException("No tour pack is active")
        val assetID = UUID.randomUUID().toString().lowercase()
        val destination = File(
            sourceDirectory(activePackID),
            "$assetID.${fileExtension(mimeType)}",
        )
        val temporary = File(destination.parentFile, "${destination.name}.tmp")
        temporary.writeBytes(bytes)
        Files.move(
            temporary.toPath(),
            destination.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.ATOMIC_MOVE,
        )
        val descriptor = TourAssetDescriptor(
            assetID = assetID,
            kind = TourAssetKind.SLIDE,
            sha256 = sha256(bytes),
            byteLength = bytes.size.toLong(),
            order = nextSlideOrder++,
            mimeType = mimeType,
        )
        assets = (assets + descriptor).sortedWith(
            compareBy<TourAssetDescriptor> { it.order }.thenBy { it.assetID },
        )
        sourcesByAssetID = sourcesByAssetID + (assetID to destination)
        manifestVersion++
        return descriptor
    }

    @Synchronized
    fun importOfflineMap(styleBytes: ByteArray, archiveFile: File) {
        val activePackID = packID ?: throw TourContentStoreException("No tour pack is active")
        OfflineMapPack.validateArchive(archiveFile)
        OfflineMapPack.configuration(styleBytes, archiveFile)

        val styleAssetID = UUID.randomUUID().toString().lowercase()
        val archiveAssetID = UUID.randomUUID().toString().lowercase()
        val directory = sourceDirectory(activePackID)
        val styleDestination = File(directory, "$styleAssetID.json")
        val archiveDestination = File(directory, "$archiveAssetID.pmtiles")
        persistBytes(styleBytes, styleDestination)
        persistFile(archiveFile, archiveDestination)

        val styleDescriptor = TourAssetDescriptor(
            styleAssetID,
            TourAssetKind.MAP_STYLE,
            sha256(styleDestination),
            styleDestination.length(),
            0,
            "application/vnd.mapbox.style+json",
        )
        val archiveDescriptor = TourAssetDescriptor(
            archiveAssetID,
            TourAssetKind.MAP_ARCHIVE,
            sha256(archiveDestination),
            archiveDestination.length(),
            0,
            "application/vnd.pmtiles",
        )
        val replacedIDs = assets.filter {
            it.kind == TourAssetKind.MAP_STYLE || it.kind == TourAssetKind.MAP_ARCHIVE
        }.mapTo(mutableSetOf()) { it.assetID }
        assets = assets.filterNot { it.assetID in replacedIDs } + listOf(styleDescriptor, archiveDescriptor)
        sourcesByAssetID = sourcesByAssetID.filterKeys { it !in replacedIDs } + mapOf(
            styleAssetID to styleDestination,
            archiveAssetID to archiveDestination,
        )
        manifestVersion++
    }

    @Synchronized
    fun moveSlide(assetID: String, destinationIndex: Int) {
        val slides = orderedSlides().toMutableList()
        val sourceIndex = slides.indexOfFirst { it.assetID == assetID }
        if (sourceIndex < 0) throw TourContentStoreException("Unknown slide asset ID $assetID")
        if (destinationIndex !in slides.indices) {
            throw TourContentStoreException("Slide index $destinationIndex is out of bounds")
        }
        if (sourceIndex == destinationIndex) return
        val moved = slides.removeAt(sourceIndex)
        slides.add(destinationIndex, moved)
        replaceSlideOrder(slides)
        manifestVersion++
    }

    @Synchronized
    fun removeSlide(assetID: String) {
        val slides = orderedSlides().toMutableList()
        val index = slides.indexOfFirst { it.assetID == assetID }
        if (index < 0) throw TourContentStoreException("Unknown slide asset ID $assetID")
        slides.removeAt(index)
        assets = assets.filterNot { it.assetID == assetID }
        sourcesByAssetID = sourcesByAssetID - assetID
        replaceSlideOrder(slides)
        manifestVersion++
    }

    @Synchronized
    fun manifestPayload(): TourPackManifestPayload {
        val activePackID = packID ?: throw TourContentStoreException("No tour pack is active")
        return TourPackManifestPayload(activePackID, manifestVersion, displayName, assets)
    }

    private fun sourceDirectory(packID: UUID): File =
        File(File(rootDirectory, packID.toString().lowercase()), "sources")

    private fun orderedSlides(): List<TourAssetDescriptor> = assets
        .filter { it.kind == TourAssetKind.SLIDE }
        .sortedWith(compareBy<TourAssetDescriptor> { it.order }.thenBy { it.assetID })

    private fun replaceSlideOrder(slides: List<TourAssetDescriptor>) {
        val slideIDs = slides.mapTo(mutableSetOf()) { it.assetID }
        val nonSlides = assets.filterNot { it.kind == TourAssetKind.SLIDE && it.assetID in slideIDs }
        val reordered = slides.mapIndexed { index, slide -> slide.copy(order = index.toLong()) }
        assets = nonSlides + reordered
        nextSlideOrder = reordered.size.toLong()
    }

    private fun ensureDirectory(directory: File) {
        if (!directory.mkdirs() && !directory.isDirectory) {
            throw TourContentStoreException("Could not create ${directory.path}")
        }
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { "%02x".format(it) }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(1_048_576)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun persistBytes(bytes: ByteArray, destination: File) {
        val temporary = File(destination.parentFile, "${destination.name}.tmp")
        temporary.writeBytes(bytes)
        Files.move(
            temporary.toPath(),
            destination.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.ATOMIC_MOVE,
        )
    }

    private fun persistFile(source: File, destination: File) {
        val temporary = File(destination.parentFile, "${destination.name}.tmp")
        source.inputStream().buffered().use { input ->
            temporary.outputStream().buffered().use(input::copyTo)
        }
        Files.move(
            temporary.toPath(),
            destination.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.ATOMIC_MOVE,
        )
    }

    private fun fileExtension(mimeType: String): String = when (mimeType.lowercase()) {
        "image/png" -> "png"
        "image/heic", "image/heif" -> "heic"
        "image/webp" -> "webp"
        else -> "jpg"
    }
}
