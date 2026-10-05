import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GetOverHere

private final class PDFFixtureBundle {}

@Suite("PDF slide rendering")
struct PDFSlideRendererTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: PDFFixtureBundle.self).url(forResource: name, withExtension: "pdf"),
                               "Missing fixture \(name).pdf; run swift scripts/make_pdf_fixtures.swift")
        return try Data(contentsOf: url)
    }

    private func image(_ jpeg: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Center pixel as (r, g, b) after drawing into a known sRGB RGBA buffer.
    private func centerColor(_ image: CGImage) throws -> (Int, Int, Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private func pdf(pageCount: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for _ in 0..<pageCount { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return data as Data
    }

    @Test("Each page becomes an ordered, bounded JPEG slide with its own content")
    func rendersPagesInOrder() async throws {
        let slides = try await PDFSlideRenderer.render(try fixture("three-pages"))
        #expect(slides.count == 3)
        #expect(slides.allSatisfy { $0.mimeType == "image/jpeg" && $0.data.count <= 250_000 })
        let images = try slides.map { try image($0.data) }
        #expect(images.map { [$0.width, $0.height] } == [[1236, 1600], [1600, 1236], [1236, 1600]])
        let colors = try images.map(centerColor)
        #expect(colors[0].0 > 200 && colors[0].1 < 60 && colors[0].2 < 60, "page 1 red, got \(colors[0])")
        #expect(colors[1].1 > 200 && colors[1].0 < 60 && colors[1].2 < 60, "page 2 green, got \(colors[1])")
        #expect(colors[2].2 > 200 && colors[2].0 < 60 && colors[2].1 < 60, "page 3 blue, got \(colors[2])")
    }

    @Test("Rendering the same PDF twice produces identical slide bytes")
    func renderingIsDeterministic() async throws {
        let data = try fixture("three-pages")
        let first = try await PDFSlideRenderer.render(data).map(\.data)
        let second = try await PDFSlideRenderer.render(data).map(\.data)
        #expect(first == second)
    }

    @Test("Password-protected, corrupt, empty-input and oversized PDFs are rejected with specific errors")
    func rejectsUnsupportedDocuments() async throws {
        await #expect(throws: PDFSlideImportError.passwordProtected) {
            try await PDFSlideRenderer.render(try fixture("locked"))
        }
        let valid = try fixture("three-pages")
        await #expect(throws: PDFSlideImportError.unreadable) {
            try await PDFSlideRenderer.render(valid.prefix(valid.count / 3))
        }
        await #expect(throws: PDFSlideImportError.unreadable) {
            try await PDFSlideRenderer.render(Data("not a pdf".utf8))
        }
        let limit = PDFSlideRenderer.maximumPages
        await #expect(throws: PDFSlideImportError.tooManyPages(count: limit + 1, maximum: limit)) {
            try await PDFSlideRenderer.render(pdf(pageCount: limit + 1))
        }
        #expect(try await PDFSlideRenderer.render(pdf(pageCount: limit)).count == limit)
    }
}
