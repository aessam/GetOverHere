import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PDFSlideImportError: LocalizedError, Equatable {
    case unreadable
    case passwordProtected
    case empty
    case tooManyPages(count: Int, maximum: Int)
    case tooLarge(bytes: Int, maximum: Int)
    case renderFailed(page: Int)

    var errorDescription: String? {
        switch self {
        case .unreadable: "The PDF could not be read. It may be damaged or not a PDF."
        case .passwordProtected: "Password-protected PDFs are not supported. Export an unlocked copy."
        case .empty: "The PDF has no pages."
        case let .tooManyPages(count, maximum): "The PDF has \(count) pages; the limit is \(maximum)."
        case let .tooLarge(bytes, maximum):
            "The PDF needs \(bytes / 1_048_576) MB; the limit is \(maximum / 1_048_576) MB."
        case let .renderFailed(page): "Page \(page) of the PDF could not be rendered."
        }
    }
}

/// Renders a PDF into JPEG slides for the existing slide pipeline (ADR-072). The page number is the
/// slide index. Rendering runs off the main actor so it cannot stall guide capture (FND-8).
nonisolated enum PDFSlideRenderer {
    static let maximumPages = 60
    static let maximumTotalBytes = 15 * 1_048_576
    static let maximumInputBytes = 100 * 1_048_576
    static let longEdgePixels: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.75

    /// Reads a user-selected document, honoring its security scope and the input size limit.
    @concurrent
    static func readDocument(at url: URL) async throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumInputBytes else { throw PDFSlideImportError.tooLarge(bytes: size, maximum: maximumInputBytes) }
        return try Data(contentsOf: url)
    }

    @concurrent
    static func render(_ data: Data) async throws -> [ChannelService.SlideImport] {
        guard data.count <= maximumInputBytes else {
            throw PDFSlideImportError.tooLarge(bytes: data.count, maximum: maximumInputBytes)
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { throw PDFSlideImportError.unreadable }
        if document.isEncrypted, !document.isUnlocked { throw PDFSlideImportError.passwordProtected }
        let count = document.numberOfPages
        guard count > 0 else { throw PDFSlideImportError.empty }
        guard count <= maximumPages else { throw PDFSlideImportError.tooManyPages(count: count, maximum: maximumPages) }
        var slides: [ChannelService.SlideImport] = []
        var total = 0
        for number in 1...count {
            try Task.checkCancellation()
            guard let page = document.page(at: number) else { throw PDFSlideImportError.renderFailed(page: number) }
            let jpeg = try renderPage(page, number: number)
            total += jpeg.count
            guard total <= maximumTotalBytes else {
                throw PDFSlideImportError.tooLarge(bytes: total, maximum: maximumTotalBytes)
            }
            slides.append(ChannelService.SlideImport(data: jpeg, mimeType: "image/jpeg"))
        }
        return slides
    }

    private static func renderPage(_ page: CGPDFPage, number: Int) throws -> Data {
        let box = page.getBoxRect(.cropBox)
        let quarterTurns = ((page.rotationAngle % 360) + 360) % 360 / 90
        let pageSize = quarterTurns.isMultiple(of: 2) ? box.size : CGSize(width: box.height, height: box.width)
        guard pageSize.width > 0, pageSize.height > 0 else { throw PDFSlideImportError.renderFailed(page: number) }
        let scale = longEdgePixels / max(pageSize.width, pageSize.height)
        let width = max(1, Int((pageSize.width * scale).rounded()))
        let height = max(1, Int((pageSize.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PDFSlideImportError.renderFailed(page: number)
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / pageSize.width, y: CGFloat(height) / pageSize.height)
        // A target equal to the rotated page size applies rotation and origin without scaling.
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pageSize),
                                                     rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw PDFSlideImportError.renderFailed(page: number) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PDFSlideImportError.renderFailed(page: number)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PDFSlideImportError.renderFailed(page: number) }
        return output as Data
    }
}
