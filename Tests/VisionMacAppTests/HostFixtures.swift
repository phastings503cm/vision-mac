import Foundation
import CoreGraphics
import CoreText
@testable import VisionHarnessCore

/// The few real files the host tests attach (the engine tests have the full set in `AttachmentFixtures`).
enum HostFixtures {
    /// `count` numbered lines of `width` characters ("line 1: xxxx…").
    static func lines(_ count: Int, width: Int = 40) -> String {
        (1...count).map { n in
            let head = "line \(n): "
            return head + String(repeating: "x", count: max(0, width - head.count))
        }.joined(separator: "\n")
    }

    /// A PDF whose pages carry `pages` as real text.
    static func textPDF(_ pages: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            draw(text, in: context, rect: box.insetBy(dx: 54, dy: 54), size: 13)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A PNG of `text` in large black letters on white.
    static func png(of text: String) -> Data {
        let context = CGContext(data: nil, width: 1200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
        draw(text, in: context, rect: CGRect(x: 60, y: 60, width: 1080, height: 280), size: 64)
        return ImageData.png(context.makeImage()!)!
    }

    static func draw(_ text: String, in context: CGContext, rect: CGRect, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let setter = CTFramesetterCreateWithAttributedString(string)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), context)
    }

    /// A request's body as text (URLSession hands it to a URLProtocol as a stream).
    static func bodyText(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
