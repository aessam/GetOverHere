package com.aessam.comeoverhere

import com.aessam.comeoverhere.service.TourPackLibrary
import com.aessam.toursession.TourPackAdvert
import com.aessam.toursession.TourPackArchive
import com.aessam.toursession.TourSessionFixtures
import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors TourPackLibraryTests.swift (ADR-080/082). */
class TourPackLibraryTest {
    @Test fun recordsAndReloads() {
        val root = Files.createTempDirectory("GetOverHerePackLibrary").toFile()
        try {
            val file = File(root, "imported-tour-packs.tsv")
            val manifest = TourPackArchive.read(TourSessionFixtures.tourPackFixture()).first.manifest
            val library = TourPackLibrary(file)
            assertFalse(library.holds(TourPackAdvert(manifest.packID, 1)))
            library.record(manifest)
            assertTrue(library.holds(TourPackAdvert(manifest.packID, manifest.manifestVersion)))
            assertTrue(library.holds(TourPackAdvert(manifest.packID, manifest.manifestVersion - 1)))
            assertFalse("a newer advertised version needs the newer pack", library.holds(TourPackAdvert(manifest.packID, manifest.manifestVersion + 1)))
            assertFalse(library.holds(TourPackAdvert(UUID.randomUUID(), 1)))

            val reloaded = TourPackLibrary(file)
            assertEquals(library.entries, reloaded.entries)
            reloaded.record(manifest)
            assertEquals("re-importing replaces, never duplicates", 1, reloaded.entries.size)
        } finally {
            check(root.deleteRecursively()) { "Temporary library cleanup failed: $root" }
        }
    }
}
