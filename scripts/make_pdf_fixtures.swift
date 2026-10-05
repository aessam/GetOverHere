// Generates the PDF import fixtures shared by iOS unit tests and Android instrumented tests.
// Run from the repository root: swift scripts/make_pdf_fixtures.swift
// three-pages.pdf: page 1 portrait red, page 2 landscape green, page 3 portrait blue (solid fills).
// locked.pdf: one page, user password "secret".
import CoreGraphics
import Foundation

let destinations = ["iOS/GetOverHereTests/Fixtures", "Android/app/src/androidTest/assets"]
let pages: [(CGSize, CGColor)] = [
    (CGSize(width: 612, height: 792), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
    (CGSize(width: 792, height: 612), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
    (CGSize(width: 612, height: 792), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
]

func makePDF(_ pages: [(CGSize, CGColor)], options: [CFString: Any] = [:]) -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { fatalError("PDF consumer unavailable") }
    var first = CGRect(origin: .zero, size: pages[0].0)
    var info = options
    info[kCGPDFContextCreator] = "GetOverHere fixtures"
    guard let context = CGContext(consumer: consumer, mediaBox: &first, info as CFDictionary) else { fatalError("PDF context unavailable") }
    for (size, color) in pages {
        var box = CGRect(origin: .zero, size: size)
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        context.setFillColor(color)
        context.fill(box)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

let plain = makePDF(pages)
let locked = makePDF([pages[0]], options: [kCGPDFContextUserPassword: "secret", kCGPDFContextOwnerPassword: "owner"])
for directory in destinations {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try plain.write(to: URL(fileURLWithPath: "\(directory)/three-pages.pdf"))
    try locked.write(to: URL(fileURLWithPath: "\(directory)/locked.pdf"))
    print("wrote \(directory)/three-pages.pdf (\(plain.count) bytes), locked.pdf (\(locked.count) bytes)")
}
