import Compression
import Foundation
import PDFKit

/// Extracts the plain text of a user-supplied book file for P4 reference alignment
/// (docs/plans/BT-reading-companion.md): PDF (PDFKit), EPUB (spine-ordered XHTML), UTF-8 text.
///
/// EPUB support is deliberately dependency-free: an EPUB is a ZIP of XHTML files plus a manifest,
/// and read-only ZIP + tag stripping is little enough code to own outright — `ZipArchiveReader`
/// below is the whole archive story, with inflation done by the system Compression framework.
/// Everything here is deterministic and fixture-testable; nothing touches the network.
enum BookFileExtractor {

    /// Extract `(name, text)` from a book file, or `nil` when the file yields no text
    /// (unknown format, scanned PDF, corrupt archive). Alignment quality degrades gracefully
    /// upstream, so partial extractions are returned rather than rejected.
    static func extract(from url: URL) -> (name: String, text: String)? {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url),
                  let text = document.string, !text.isEmpty else { return nil }
            return (name, text)
        case "epub":
            guard let data = try? Data(contentsOf: url),
                  let text = EPUBExtractor.text(from: data), !text.isEmpty else { return nil }
            return (name, text)
        default:
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
            return (name, text)
        }
    }
}

/// EPUB → plain text in spine (reading) order.
enum EPUBExtractor {

    /// The whole pipeline: ZIP → `META-INF/container.xml` → OPF manifest+spine → XHTML → text.
    /// Falls back to concatenating every (X)HTML entry in archive order when the manifest is
    /// missing or malformed — a readable-but-unordered book still beats no book.
    static func text(from data: Data) -> String? {
        guard let archive = ZipArchiveReader(data: data) else { return nil }

        let documents = spineDocumentPaths(in: archive)
            ?? archive.entryNames
                .filter { name in
                    let ext = (name as NSString).pathExtension.lowercased()
                    return ext == "xhtml" || ext == "html" || ext == "htm"
                }
                .sorted()

        let chapters = documents.compactMap { path -> String? in
            guard let bytes = archive.entryData(named: path),
                  let html = String(data: bytes, encoding: .utf8) else { return nil }
            let text = HTMLTextStripper.text(from: html)
            return text.isEmpty ? nil : text
        }
        let joined = chapters.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    /// Resolve the spine's content documents, in order. `nil` when container/OPF parsing fails.
    private static func spineDocumentPaths(in archive: ZipArchiveReader) -> [String]? {
        guard let containerData = archive.entryData(named: "META-INF/container.xml"),
              let container = String(data: containerData, encoding: .utf8),
              let opfPath = firstMatch(in: container, pattern: "full-path=\"([^\"]+)\""),
              let opfData = archive.entryData(named: opfPath),
              let opf = String(data: opfData, encoding: .utf8) else { return nil }

        let opfDirectory = (opfPath as NSString).deletingLastPathComponent

        // Manifest: id → href, XHTML items only. Attribute order varies between producers, so
        // pull each attribute independently off the item tag.
        var hrefByID: [String: String] = [:]
        for tag in allMatches(in: opf, pattern: "<item\\b[^>]*>") {
            guard let id = firstMatch(in: tag, pattern: "\\bid=\"([^\"]+)\""),
                  let href = firstMatch(in: tag, pattern: "\\bhref=\"([^\"]+)\"") else { continue }
            if let media = firstMatch(in: tag, pattern: "media-type=\"([^\"]+)\""),
               !media.contains("html") { continue }
            hrefByID[id] = href.removingPercentEncoding ?? href
        }

        let spineIDs = allMatches(in: opf, pattern: "<itemref\\b[^>]*>")
            .compactMap { firstMatch(in: $0, pattern: "\\bidref=\"([^\"]+)\"") }
        guard !spineIDs.isEmpty else { return nil }

        let paths = spineIDs.compactMap { id -> String? in
            guard let href = hrefByID[id] else { return nil }
            let joined = opfDirectory.isEmpty ? href : opfDirectory + "/" + href
            return (joined as NSString).standardizingPath
        }
        return paths.isEmpty ? nil : paths
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

/// XHTML → readable text: scripts/styles/head dropped, block boundaries become newlines, tags
/// stripped, common entities decoded. Whitespace precision doesn't matter downstream — alignment
/// tokenizes on whitespace runs — so this favors simplicity over DOM fidelity.
enum HTMLTextStripper {

    static func text(from html: String) -> String {
        var s = html
        for block in ["script", "style", "head"] {
            s = replace(in: s, pattern: "<\(block)\\b[\\s\\S]*?</\(block)>", with: " ")
        }
        s = replace(in: s, pattern: "<!--[\\s\\S]*?-->", with: " ")
        s = replace(in: s, pattern: "<(?:br|/p|/div|/h[1-6]|/li|/tr|/blockquote|/section)\\b[^>]*>", with: "\n")
        s = replace(in: s, pattern: "<[^>]+>", with: " ")
        s = decodeEntities(s)
        // Collapse intra-line whitespace but keep line structure.
        let lines = s.split(separator: "\n")
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
        "&lsquo;": "'", "&rsquo;": "'", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
    ]

    private static func decodeEntities(_ text: String) -> String {
        var s = text
        for (entity, character) in namedEntities {
            s = s.replacingOccurrences(of: entity, with: character)
        }
        // Numeric entities, decimal and hex.
        for match in EPUBTextRegex.numericEntity.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(match.range, in: s), let inner = Range(match.range(at: 1), in: s) else { continue }
            let body = s[inner]
            let scalarValue: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                scalarValue = UInt32(body.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(body)
            }
            if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                s.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return s
    }

    private static func replace(in text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: replacement)
    }
}

private enum EPUBTextRegex {
    static let numericEntity = try! NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);")
}

/// Minimal read-only ZIP: central directory walk + stored/deflate entries. No ZIP64, no
/// encryption, no CRC verification — book files, not adversarial input; a malformed archive
/// simply yields nil entries and the extractor falls through.
struct ZipArchiveReader {

    private struct Entry {
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private var entries: [String: Entry] = [:]

    var entryNames: [String] { Array(entries.keys) }

    init?(data: Data) {
        self.data = data
        // End-of-central-directory record: scan back from the end (trailing archive comment
        // allowed), signature 0x06054b50.
        let minEOCD = 22
        guard data.count >= minEOCD else { return nil }
        var eocdOffset = -1
        let scanFloor = max(0, data.count - minEOCD - 65_535)
        var cursor = data.count - minEOCD
        while cursor >= scanFloor {
            if readUInt32(at: cursor) == 0x0605_4B50 { eocdOffset = cursor; break }
            cursor -= 1
        }
        guard eocdOffset >= 0 else { return nil }

        let entryCount = Int(readUInt16(at: eocdOffset + 10))
        var offset = Int(readUInt32(at: eocdOffset + 16))

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, readUInt32(at: offset) == 0x0201_4B50 else { return nil }
            let nameLength = Int(readUInt16(at: offset + 28))
            let extraLength = Int(readUInt16(at: offset + 30))
            let commentLength = Int(readUInt16(at: offset + 32))
            guard offset + 46 + nameLength <= data.count else { return nil }
            let nameStart = data.startIndex + offset + 46
            let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)),
                              encoding: .utf8) ?? ""
            entries[name] = Entry(
                compressionMethod: readUInt16(at: offset + 10),
                compressedSize: Int(readUInt32(at: offset + 20)),
                uncompressedSize: Int(readUInt32(at: offset + 24)),
                localHeaderOffset: Int(readUInt32(at: offset + 42)))
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    /// Entry bytes by exact name (leading "./" tolerated), inflated if deflate-compressed.
    func entryData(named name: String) -> Data? {
        let key = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
        guard let entry = entries[key] ?? entries["./" + key] else { return nil }
        let headerOffset = entry.localHeaderOffset
        guard headerOffset + 30 <= data.count, readUInt32(at: headerOffset) == 0x0403_4B50 else { return nil }
        // The local header's own name/extra lengths can differ from the central directory's.
        let nameLength = Int(readUInt16(at: headerOffset + 26))
        let extraLength = Int(readUInt16(at: headerOffset + 28))
        let start = headerOffset + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { return nil }
        let dataStart = data.startIndex + start
        let raw = data.subdata(in: dataStart..<(dataStart + entry.compressedSize))

        switch entry.compressionMethod {
        case 0:
            return raw
        case 8:
            return inflate(raw, expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    /// Raw-deflate inflation via the system Compression framework (its ZLIB variant is exactly
    /// ZIP's headerless deflate).
    private func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            input.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, expectedSize,
                                                 sourceBase, input.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { return nil }
        return output
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        UInt32(readUInt16(at: offset)) | (UInt32(readUInt16(at: offset + 2)) << 16)
    }
}
