// SPDX-License-Identifier: AGPL-3.0-only

import CZlib
import Foundation

public enum BookFormat: String, Sendable, CaseIterable {
    /// GnuCash's SQLite backend (`.gnucash` holding `SQLite format 3`).
    case sqlite
    /// GnuCash's XML backend (`.gnucash`, gzip-compressed by default).
    case xml
}

public enum BookFormatError: Error, Equatable, Sendable {
    case unknown
    case unreadable
    case malformedXML
}

public enum BookFile {
    /// Detects the on-disk backend the same way GnuCash 5.x does: never trust
    /// the extension, look at the bytes. XML may be plain or gzip-compressed.
    public static func detect(at url: URL) throws -> BookFormat {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw BookFormatError.unreadable
        }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 4096), !prefix.isEmpty else {
            throw BookFormatError.unreadable
        }
        return try detect(prefix: prefix)
    }

    public static func detect(prefix: Data) throws -> BookFormat {
        if prefix.starts(with: Data("SQLite format 3\u{0}".utf8)) {
            return .sqlite
        }
        if prefix.starts(with: Data([0x1f, 0x8b])) {
            let inflated = try Gzip.inflatePrefix(prefix, limit: 8)
            guard inflated.starts(with: Data("<?xml".utf8)) || inflated.starts(with: Data("<".utf8)) else {
                throw BookFormatError.unknown
            }
            return .xml
        }
        let text = String(decoding: prefix, as: UTF8.self)
        if text.hasPrefix("<?xml") || text.hasPrefix("<gnc-v2") {
            return .xml
        }
        throw BookFormatError.unknown
    }
}

enum Gzip {
    static func inflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(
            &stream,
            15 + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw BookFormatError.unreadable
        }
        defer { inflateEnd(&stream) }

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var output = Data()
        var status: Int32 = Z_OK

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else {
                throw BookFormatError.unreadable
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(min(raw.count, Int(UInt32.max)))

            repeat {
                let capacity = bufferSize
                let written: Int = buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    status = CZlib.inflate(&stream, Z_NO_FLUSH)
                    return capacity - Int(stream.avail_out)
                }
                if written > 0 {
                    output.append(contentsOf: buffer[0..<written])
                }
                if status == Z_STREAM_END { break }
                guard status == Z_OK else { throw BookFormatError.unreadable }
            } while true
        }
        return output
    }

    /// Writes a gzip stream, as GnuCash expects for `.gnucash` XML files.
    static func deflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            15 + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw BookFormatError.unreadable
        }
        defer { deflateEnd(&stream) }

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var output = Data()
        var status: Int32 = Z_OK
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else {
                throw BookFormatError.unreadable
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(min(raw.count, Int(UInt32.max)))
            repeat {
                let capacity = bufferSize
                let written: Int = buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    status = CZlib.deflate(&stream, Z_FINISH)
                    return capacity - Int(stream.avail_out)
                }
                if written > 0 {
                    output.append(contentsOf: buffer[0..<written])
                }
                if status == Z_STREAM_END { break }
                guard status == Z_OK else { throw BookFormatError.unreadable }
            } while true
        }
        return output
    }

    /// Inflates just enough to sniff the payload.
    static func inflatePrefix(_ data: Data, limit: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(
            &stream,
            15 + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw BookFormatError.unreadable
        }
        defer { inflateEnd(&stream) }

        var buffer = [UInt8](repeating: 0, count: max(limit, 1))
        var output = Data()
        var status: Int32 = Z_OK
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else {
                throw BookFormatError.unreadable
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(min(raw.count, Int(UInt32.max)))
            while output.count < limit {
                let capacity = buffer.count
                let written: Int = buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    status = CZlib.inflate(&stream, Z_NO_FLUSH)
                    return capacity - Int(stream.avail_out)
                }
                if written > 0 {
                    output.append(contentsOf: buffer[0..<written])
                }
                if status == Z_STREAM_END { break }
                if written == 0 { break }
                guard status == Z_OK else {
                    throw BookFormatError.unreadable
                }
            }
        }
        guard !output.isEmpty else {
            throw BookFormatError.unreadable
        }
        return output
    }
}
