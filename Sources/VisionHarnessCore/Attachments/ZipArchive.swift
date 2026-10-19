import Foundation
import Compression

// MARK: - Reading a zip archive in memory
//
// Office Open XML files (.docx, .pptx, .xlsx) are zip archives of XML parts. This reads one from memory: the
// central directory at the end, then each wanted entry, stored or deflated (Apple's `COMPRESSION_ZLIB` is raw
// DEFLATE, which is what zip uses). No Zip64, no encryption — neither turns up in an Office file anyone attaches.

public struct ZipArchive: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        let method: UInt16
        let compressedSize: Int
        public let size: Int
        let localHeaderOffset: Int
    }

    public enum ZipError: Error, Equatable {
        case notAZip
        case damaged(String)
        case unsupported(String)
        case tooLarge(String)
    }

    /// The largest entry this will inflate (a guard against zip bombs).
    public static let maxEntrySize = 256 * 1024 * 1024

    private let data: Data
    public let entries: [Entry]

    public init(_ data: Data) throws {
        self.data = data
        self.entries = try Self.readDirectory(data)
    }

    /// Whether `data` starts like a zip archive ("PK\u{3}\u{4}").
    public static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
    }

    public func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    /// The bytes of the entry called `name`, or nil when there is none.
    public func read(_ name: String) throws -> Data? {
        guard let entry = entry(name) else { return nil }
        return try read(entry)
    }

    public func read(_ entry: Entry) throws -> Data {
        guard entry.size <= Self.maxEntrySize else { throw ZipError.tooLarge(entry.name) }
        let local = entry.localHeaderOffset
        guard local >= 0, local + 30 <= data.count, u32(local) == 0x04034B50 else {
            throw ZipError.damaged("no local header for \(entry.name)")
        }
        let nameLength = Int(u16(local + 26)), extraLength = Int(u16(local + 28))
        let start = local + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { throw ZipError.damaged("\(entry.name) is cut short") }
        let body = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0:
            return body
        case 8:
            return try Self.inflate(body, size: entry.size, name: entry.name)
        default:
            throw ZipError.unsupported("compression method \(entry.method) in \(entry.name)")
        }
    }

    // MARK: Structure

    private static func readDirectory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ZipError.notAZip }
        // The end-of-central-directory record is in the last 64 KB + 22 bytes (it may carry a comment).
        let floor = max(0, data.count - 22 - 65_535)
        var end = -1
        var at = data.count - 22
        while at >= floor {
            if le32(data, at) == 0x06054B50 { end = at; break }
            at -= 1
        }
        guard end >= 0 else { throw ZipError.notAZip }
        let count = Int(le16(data, end + 10))
        let directoryOffset = Int(le32(data, end + 16))
        if directoryOffset == 0xFFFF_FFFF || count == 0xFFFF { throw ZipError.unsupported("Zip64") }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var offset = directoryOffset
        for _ in 0..<count {
            guard offset + 46 <= data.count, le32(data, offset) == 0x02014B50 else {
                throw ZipError.damaged("central directory")
            }
            let flags = le16(data, offset + 8)
            if flags & 0x1 != 0 { throw ZipError.unsupported("encrypted entries") }
            let method = le16(data, offset + 10)
            let compressed = Int(le32(data, offset + 20))
            let size = Int(le32(data, offset + 24))
            let nameLength = Int(le16(data, offset + 28))
            let extraLength = Int(le16(data, offset + 30))
            let commentLength = Int(le16(data, offset + 32))
            let local = Int(le32(data, offset + 42))
            guard offset + 46 + nameLength <= data.count else { throw ZipError.damaged("entry name") }
            let nameData = data.subdata(in: (data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength))
            let name = String(decoding: nameData, as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: compressed, size: size,
                                 localHeaderOffset: local))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func inflate(_ body: Data, size: Int, name: String) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            body.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(d, size, s, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.damaged("\(name) did not inflate") }
        return out
    }

    private func u16(_ at: Int) -> UInt16 { Self.le16(data, at) }
    private func u32(_ at: Int) -> UInt32 { Self.le32(data, at) }

    private static func le16(_ data: Data, _ at: Int) -> UInt16 {
        let i = data.startIndex + at
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private static func le32(_ data: Data, _ at: Int) -> UInt32 {
        let i = data.startIndex + at
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }
}
