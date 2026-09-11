import Foundation
import Testing
@testable import WaypointCore

/// Fixtures were produced with `gzip -c -n` on Linux, so they are byte-stable
/// (no name, no timestamp) and exercise a stream made elsewhere than Apple's.
private func gzipFixture(_ hex: String) -> Data {
    var bytes = [UInt8]()
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let end = hex.index(index, offsetBy: 2)
        bytes.append(UInt8(hex[index ..< end], radix: 16)!)
        index = end
    }
    return Data(bytes)
}

struct GzipDecoderTests {
    @Test func decodesASingleMember() throws {
        let gz = gzipFixture("1f8b0800000000000003cb48cdc9c95728cf2fca49010085114a0d0b000000")
        #expect(try GzipDecoder.gunzip(gz) == Data("hello world".utf8))
    }

    @Test func decodesAnEmptyMemberToEmptyData() throws {
        let gz = gzipFixture("1f8b080000000000000303000000000000000000")
        #expect(try GzipDecoder.gunzip(gz).isEmpty)
    }

    // 70000 bytes is past one 64 KiB output chunk, so the decode loop has to
    // grow the buffer and run inflate a second time.
    @Test func growsTheOutputPastOneChunk() throws {
        let gz = gzipFixture(
            "1f8b0800000000000003edc13101000000c2a0aceb5fc2129e40" +
            "0100000000000000000000000000000000000000000000000000" +
            "0000000000000000000000000000000000000000000000000000" +
            "000000000000000000000000000000006f0304e2291270110100")
        let expected = Data(String(repeating: "a", count: 70_000).utf8)
        #expect(try GzipDecoder.gunzip(gz) == expected)
    }

    @Test func decodesConcatenatedMembers() throws {
        let gz = gzipFixture("1f8b08000000000000034bcb2c2a2e010057ee719205000000" +
                             "1f8b08000000000000032b4e4dcecf4b010069111fb606000000")
        #expect(try GzipDecoder.gunzip(gz) == Data("firstsecond".utf8))
    }

    @Test func rejectsEmptyInput() {
        #expect(throws: GzipDecoder.Failure.emptyInput) {
            _ = try GzipDecoder.gunzip(Data())
        }
    }

    @Test func rejectsATruncatedStream() {
        #expect(throws: GzipDecoder.Failure.self) {
            _ = try GzipDecoder.gunzip(gzipFixture("1f8b0800000000000003cb48cdc9c95728cf2fca49"))
        }
    }
}
