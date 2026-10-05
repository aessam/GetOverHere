package com.aessam.comeoverhere.service

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import kotlin.math.max
import kotlin.math.roundToInt

class PdfSlideImportException(message: String) : Exception(message)

/**
 * Renders a PDF into JPEG slides for the existing slide pipeline (ADR-072). The page number is the
 * slide index. Callers run it off the main thread; it does blocking file and native render work.
 */
object PdfSlideRenderer {
    const val MAXIMUM_PAGES = 60
    const val MAXIMUM_TOTAL_BYTES = 15 * 1_048_576
    const val MAXIMUM_INPUT_BYTES = 100 * 1_048_576
    const val LONG_EDGE_PIXELS = 1600
    const val JPEG_QUALITY = 75

    /** PdfRenderer needs a seekable descriptor, so the document is staged in [scratchDirectory]. */
    fun render(bytes: ByteArray, scratchDirectory: File): List<SlideImport> {
        if (bytes.size > MAXIMUM_INPUT_BYTES) throw tooLarge(bytes.size, MAXIMUM_INPUT_BYTES)
        val staged = File.createTempFile("pdf-import-", ".pdf", scratchDirectory)
        try {
            staged.writeBytes(bytes)
            val descriptor = ParcelFileDescriptor.open(staged, ParcelFileDescriptor.MODE_READ_ONLY)
            val renderer = try {
                PdfRenderer(descriptor)
            } catch (error: SecurityException) {
                descriptor.close()
                throw PdfSlideImportException("Password-protected PDFs are not supported. Export an unlocked copy.")
            } catch (error: IOException) {
                descriptor.close()
                throw PdfSlideImportException("The PDF could not be read. It may be damaged or not a PDF.")
            }
            return renderer.use { document ->
                val count = document.pageCount
                if (count <= 0) throw PdfSlideImportException("The PDF has no pages.")
                if (count > MAXIMUM_PAGES) throw PdfSlideImportException("The PDF has $count pages; the limit is $MAXIMUM_PAGES.")
                var total = 0
                (0 until count).map { index ->
                    val jpeg = document.openPage(index).use { page -> renderPage(page, index + 1) }
                    total += jpeg.size
                    if (total > MAXIMUM_TOTAL_BYTES) throw tooLarge(total, MAXIMUM_TOTAL_BYTES)
                    SlideImport(jpeg, "image/jpeg")
                }
            }
        } finally {
            if (!staged.delete()) android.util.Log.w("PdfSlideRenderer", "Could not delete staged PDF ${staged.name}")
        }
    }

    private fun renderPage(page: PdfRenderer.Page, number: Int): ByteArray {
        if (page.width <= 0 || page.height <= 0) throw PdfSlideImportException("Page $number of the PDF could not be rendered.")
        val scale = LONG_EDGE_PIXELS.toDouble() / max(page.width, page.height)
        val width = max(1, (page.width * scale).roundToInt())
        val height = max(1, (page.height * scale).roundToInt())
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(Color.WHITE)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            val output = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, output)) {
                throw PdfSlideImportException("Page $number of the PDF could not be rendered.")
            }
            return output.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    private fun tooLarge(bytes: Int, maximum: Int) =
        PdfSlideImportException("The PDF needs ${bytes / 1_048_576} MB; the limit is ${maximum / 1_048_576} MB.")
}
