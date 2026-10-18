package com.aessam.comeoverhere

import com.aessam.comeoverhere.service.PreparedTourException
import com.aessam.comeoverhere.service.PreparedTourStore
import com.aessam.comeoverhere.service.SlideImport
import com.aessam.toursession.TourPackArchive
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors PreparedTourStoreTests.swift (ADR-080 DSCN-1). */
class PreparedTourStoreTest {
    @Test fun lifecycle() {
        val root = Files.createTempDirectory("GetOverHerePrepared").toFile()
        try {
            val store = PreparedTourStore(File(root, "tours"))
            val created = store.create("Old Town")
            assertEquals(1L, created.manifestVersion)
            assertThrows(PreparedTourException::class.java) { store.export(created.packID, root) }

            val pages = listOf("page one", "page two", "page one").map { it.toByteArray() }
            val updated = store.addSlides(pages.map { SlideImport(it, "image/jpeg") }, created.packID)
            assertEquals(2L, updated.manifestVersion)
            assertEquals(listOf(0L, 1L, 2L), updated.assets.map { it.order })
            assertEquals("identical pages share one file", 2, updated.assets.map { it.sha256 }.toSet().size)

            val file = store.export(created.packID, root)
            assertEquals("Old Town.gohtour", file.name)
            val (layout, assets) = TourPackArchive.read(file.readBytes())
            assertEquals(updated, layout.manifest)
            assertEquals(pages.map { String(it) }.toSet(), assets.values.map { String(it) }.toSet())

            val launch = store.launch(created.packID)
            assertTrue(launch.sourcesByAssetID.values.all { it.isFile })

            val reloaded = PreparedTourStore(File(root, "tours"))
            assertEquals(listOf(updated), reloaded.tours.value)
            reloaded.remove(created.packID)
            assertTrue(reloaded.tours.value.isEmpty())
            assertTrue(PreparedTourStore(File(root, "tours")).tours.value.isEmpty())
        } finally {
            check(root.deleteRecursively()) { "Temporary prepared-tour cleanup failed: $root" }
        }
    }
}
