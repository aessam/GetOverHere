package com.aessam.comeoverhere

import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfDocument
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aessam.comeoverhere.service.PdfSlideImportException
import com.aessam.comeoverhere.service.PdfSlideRenderer
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Fixtures come from scripts/make_pdf_fixtures.swift and match the iOS test fixtures byte for byte. */
@RunWith(AndroidJUnit4::class)
class PdfSlideRendererTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val scratch get() = instrumentation.targetContext.cacheDir
    private fun fixture(name: String) = instrumentation.context.assets.open(name).use { it.readBytes() }

    private fun pdf(pageCount: Int): ByteArray {
        val document = PdfDocument()
        try {
            repeat(pageCount) { index ->
                document.finishPage(document.startPage(PdfDocument.PageInfo.Builder(200, 100, index + 1).create()))
            }
            return ByteArrayOutputStream().also(document::writeTo).toByteArray()
        } finally { document.close() }
    }

    @Test fun eachPageBecomesAnOrderedBoundedJpegWithItsOwnContent() {
        val slides = PdfSlideRenderer.render(fixture("three-pages.pdf"), scratch)
        assertEquals(3, slides.size)
        assertTrue(slides.all { it.mimeType == "image/jpeg" && it.bytes.size <= 250_000 })
        val images = slides.map { BitmapFactory.decodeByteArray(it.bytes, 0, it.bytes.size) }
        assertEquals(listOf(1236 to 1600, 1600 to 1236, 1236 to 1600), images.map { it.width to it.height })
        val centers = images.map { it.getPixel(it.width / 2, it.height / 2) }
        assertTrue("page 1 red ${Integer.toHexString(centers[0])}", Color.red(centers[0]) > 200 && Color.green(centers[0]) < 60 && Color.blue(centers[0]) < 60)
        assertTrue("page 2 green ${Integer.toHexString(centers[1])}", Color.green(centers[1]) > 200 && Color.red(centers[1]) < 60 && Color.blue(centers[1]) < 60)
        assertTrue("page 3 blue ${Integer.toHexString(centers[2])}", Color.blue(centers[2]) > 200 && Color.red(centers[2]) < 60 && Color.green(centers[2]) < 60)
        assertTrue("staged copies are removed", scratch.listFiles().orEmpty().none { it.name.startsWith("pdf-import-") })
    }

    @Test fun renderingTheSamePdfTwiceProducesIdenticalSlides() {
        val data = fixture("three-pages.pdf")
        val first = PdfSlideRenderer.render(data, scratch)
        val second = PdfSlideRenderer.render(data, scratch)
        first.zip(second).forEach { (a, b) -> assertArrayEquals(a.bytes, b.bytes) }
    }

    @Test fun unsupportedDocumentsAreRejectedWithSpecificErrors() {
        val locked = assertThrows(PdfSlideImportException::class.java) { PdfSlideRenderer.render(fixture("locked.pdf"), scratch) }
        assertTrue(locked.message!!, locked.message!!.startsWith("Password-protected"))
        val garbage = assertThrows(PdfSlideImportException::class.java) { PdfSlideRenderer.render("not a pdf".toByteArray(), scratch) }
        assertTrue(garbage.message!!, garbage.message!!.startsWith("The PDF could not be read"))
        val valid = fixture("three-pages.pdf")
        // pdfium may repair a truncated file; it must still be rejected, never imported partially.
        assertThrows(PdfSlideImportException::class.java) { PdfSlideRenderer.render(valid.copyOf(valid.size / 3), scratch) }
        val limit = PdfSlideRenderer.MAXIMUM_PAGES
        val tooMany = assertThrows(PdfSlideImportException::class.java) { PdfSlideRenderer.render(pdf(limit + 1), scratch) }
        assertEquals("The PDF has ${limit + 1} pages; the limit is $limit.", tooMany.message)
        assertEquals(limit, PdfSlideRenderer.render(pdf(limit), scratch).size)
    }
}
