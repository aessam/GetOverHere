package com.aessam.comeoverhere.service

import com.aessam.toursession.TourPackAdvert
import com.aessam.toursession.TourPackManifestPayload
import java.io.File
import java.util.UUID

/**
 * Tour packs this device has imported (ADR-080). Drives the "Tour ready" badge for a room whose record
 * advertises a pack (ADR-082); readiness itself is still decided by the session manifest's hashes.
 * Stored as one `packID<TAB>manifestVersion<TAB>displayName` line per pack.
 */
class TourPackLibrary(private val file: File) {
    data class Entry(val packID: UUID, val manifestVersion: Long, val displayName: String)

    @Volatile var entries: List<Entry> = load()
        private set

    /** True when an imported pack has this ID at this version or newer (versions are unsigned). */
    fun holds(advert: TourPackAdvert): Boolean = entries.any {
        it.packID == advert.packID && java.lang.Long.compareUnsigned(it.manifestVersion, advert.manifestVersion) >= 0
    }

    @Synchronized
    fun record(manifest: TourPackManifestPayload) {
        val name = manifest.displayName.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ')
        val updated = entries.filter { it.packID != manifest.packID } + Entry(manifest.packID, manifest.manifestVersion, name)
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, "${file.name}.tmp")
        temporary.writeText(updated.joinToString("") { "${it.packID}\t${java.lang.Long.toUnsignedString(it.manifestVersion)}\t${it.displayName}\n" })
        check(temporary.renameTo(file)) { "Could not replace $file" }
        entries = updated
    }

    private fun load(): List<Entry> {
        if (!file.exists()) return emptyList()
        return file.readLines().filter { it.isNotEmpty() }.map { line ->
            val fields = line.split('\t', limit = 3)
            require(fields.size == 3) { "Malformed tour pack library line in $file" }
            Entry(UUID.fromString(fields[0]), java.lang.Long.parseUnsignedLong(fields[1]), fields[2])
        }
    }
}
