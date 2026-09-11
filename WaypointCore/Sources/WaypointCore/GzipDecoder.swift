//
//  GzipDecoder.swift
//  WaypointCore
//  Decodes gzip (RFC 1952) streams with the system zlib, so the app target
//  needs no third-party decompression dependency for its bundled assets.
//

import Foundation
import zlib

public enum GzipDecoder {
    public enum Failure: Error, Equatable, Sendable {
        case emptyInput
        case inflateFailed(status: Int32, message: String?)
    }

    /// Decompresses `data`. Concatenated members are decoded in order, the way
    /// `gunzip` treats a multi-member file.
    public static func gunzip(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw Failure.emptyInput }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)

        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else {
                throw Failure.emptyInput
            }
            var offset = 0
            while offset < data.count {
                var stream = z_stream()
                // 32 + 15 makes zlib accept either a gzip or a zlib header, and
                // the stream's own `total_in` reports how far the member ran.
                let started = inflateInit2_(&stream,
                                            MAX_WBITS + 32,
                                            ZLIB_VERSION,
                                            Int32(MemoryLayout<z_stream>.size))
                guard started == Z_OK else {
                    throw Failure.inflateFailed(status: started, message: nil)
                }

                stream.next_in = UnsafeMutablePointer(mutating: base).advanced(by: offset)
                stream.avail_in = uInt(clamping: data.count - offset)

                var status: Int32 = Z_OK
                repeat {
                    // Read `capacity` before the closure: touching `buffer` inside
                    // `withUnsafeMutableBytes` is an overlapping access.
                    let capacity = buffer.count
                    let produced = buffer.withUnsafeMutableBytes { out -> Int in
                        stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(clamping: capacity)
                        status = inflate(&stream, Z_NO_FLUSH)
                        return capacity - Int(stream.avail_out)
                    }
                    if produced > 0 {
                        output.append(contentsOf: buffer[0 ..< produced])
                    }
                } while status == Z_OK

                // `msg` points into the stream, so read it before tearing down.
                let message = stream.msg.map { String(cString: $0) }
                let consumed = Int(stream.total_in)
                inflateEnd(&stream)

                guard status == Z_STREAM_END else {
                    throw Failure.inflateFailed(status: status, message: message)
                }
                // A member that consumes nothing would spin this loop forever.
                offset += max(consumed, 1)
            }
        }

        return output
    }
}
