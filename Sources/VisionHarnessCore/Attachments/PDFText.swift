import Foundation
import CoreGraphics
import ImageIO
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif

// MARK: - Text out of PDFs and pictures
//
// A PDF's own text layer, page by page ("--- Page N of M ---" before each), through PDFKit. A page without one (a
// scan, a photo of a page) is read with OCR — Apple's Vision framework — and, when the whole file is a scan, its
// first pages are also rendered to PNG so a model that takes images can look at them instead.

public enum PDFText {
    /// Pages of a scan rendered for a vision model (Bedrock takes at most 20 images in a message).
    public static let maxPageImages = 20
    /// Pages of a scan read with OCR; the rest are listed as not read.
    public static let maxOCRPages = 100
    /// A page "has text" when its text layer holds at least this many non-blank characters.
    public static let minPageCharacters = 8
    /// The longest side of a rendered page, in pixels.
    public static let renderSide: CGFloat = 1600

    public struct Result: Sendable {
        public var text: String
        public var pages: Int
        public var ocr: Bool
        public var scanned: Bool
        public var pageImages: [Data]
        public var problem: String?
    }

    public static func extract(_ data: Data, ocr allowOCR: Bool = true) -> Result {
        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else {
            return Result(text: "", pages: 0, ocr: false, scanned: false, pageImages: [],
                          problem: "Vision couldn't open this PDF (it may be damaged).")
        }
        if document.isLocked && !document.unlock(withPassword: "") {
            return Result(text: "", pages: document.pageCount, ocr: false, scanned: false, pageImages: [],
                          problem: "This PDF is password-protected, so Vision can't read it.")
        }
        let count = document.pageCount
        var texts: [String?] = []
        texts.reserveCapacity(count)
        for index in 0..<count {
            let raw = AttachmentText.normalizeNewlines(document.page(at: index)?.string ?? "")
            let visible = raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
            texts.append(visible >= minPageCharacters ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        }
        let scanned = count > 0 && texts.allSatisfy { $0 == nil }
        var usedOCR = false
        var ocrBudget = maxOCRPages
        var pages: [String] = []
        for index in 0..<count {
            var body = texts[index]
            var skipped = false
            if body == nil, allowOCR {
                if ocrBudget > 0 {
                    ocrBudget -= 1
                    if let page = document.page(at: index), let image = render(page) {
                        let read = OCR.text(in: image)
                        if !read.isEmpty { body = read; usedOCR = true }
                    }
                } else {
                    skipped = true
                }
            }
            let header = "--- Page \(index + 1) of \(count) ---"
            if let body {
                pages.append(header + "\n" + body)
            } else {
                pages.append(header + "\n" + (skipped ? "(not read: past the first \(maxOCRPages) scanned pages)" : "(no text on this page)"))
            }
        }
        var images: [Data] = []
        if scanned {
            for index in 0..<min(count, maxPageImages) {
                if let page = document.page(at: index), let image = render(page), let png = ImageData.png(image) {
                    images.append(png)
                }
            }
        }
        return Result(text: pages.joined(separator: "\n\n"), pages: count, ocr: usedOCR, scanned: scanned,
                      pageImages: images, problem: nil)
        #else
        return Result(text: "", pages: 0, ocr: false, scanned: false, pageImages: [],
                      problem: "Reading PDFs isn't available on this system.")
        #endif
    }

    #if canImport(PDFKit)
    /// A page drawn on white, its longest side `renderSide` pixels.
    static func render(_ page: PDFPage) -> CGImage? {
        guard let ref = page.pageRef else { return nil }
        let box = ref.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let angle = ((Int(ref.rotationAngle) % 360) + 360) % 360
        let rotated = angle == 90 || angle == 270
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(4, renderSide / max(size.width, size.height))
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The page's own /Rotate (clockwise, as displayed), then its crop box scaled into the bitmap. (Not
        // `getDrawingTransform`: it never scales a page up, and a scan wants more pixels than points for OCR.)
        switch angle {
        case 90:
            context.translateBy(x: 0, y: box.width * scale)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: box.width * scale, y: box.height * scale)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: box.height * scale, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(ref)
        return context.makeImage()
    }
    #endif
}

// MARK: - OCR

public enum OCR {
    /// The text Apple's Vision framework reads in `image`, top to bottom, one line per recognised line.
    public static func text(in image: CGImage) -> String {
        #if canImport(Vision)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        let observations = request.results ?? []
        // Reading order: rows top to bottom (Vision's y grows upward), left to right within a row.
        let lines = observations.compactMap { observation -> (y: CGFloat, x: CGFloat, height: CGFloat, text: String)? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return (box.midY, box.minX, box.height, best.string)
        }
        let sorted = lines.sorted { a, b in
            let tolerance = min(a.height, b.height) / 2
            if abs(a.y - b.y) > tolerance { return a.y > b.y }
            return a.x < b.x
        }
        return sorted.map(\.text).joined(separator: "\n")
        #else
        return ""
        #endif
    }

    /// OCR of an encoded picture (PNG, JPEG, …); "" when it isn't one or holds no text.
    public static func text(inImageData data: Data) -> String {
        guard let image = ImageData.cgImage(data) else { return "" }
        return text(in: image)
    }
}

// MARK: - Images

public enum ImageData {
    /// Decode the first frame of an encoded picture.
    public static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Encode as PNG.
    public static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// Pixel size of an encoded picture, without decoding it.
    public static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The picture as a PNG any model server takes: re-encoded (HEIC, TIFF, BMP … become PNG) and scaled down so its
    /// longest side is at most `maxSide` pixels and it stays under `maxBytes` (Bedrock refuses images over 3.75 MB
    /// or 8000 px). Nil when it isn't a picture.
    public static func normalized(_ data: Data, maxSide: Int = 2048, maxBytes: Int = 3_750_000) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        var side = maxSide
        if let size = pixelSize(data) { side = min(side, Int(max(size.width, size.height))) }
        while side >= 256 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let png = png(image) else { return nil }
            if png.count <= maxBytes { return png }
            side = side * 3 / 4
        }
        return nil
    }
}
