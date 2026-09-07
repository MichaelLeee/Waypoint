import Testing
@testable import WaypointCore

struct SpeedUtilsTests {
    @Test func kilobyteRange() {
        #expect(SpeedUtils.getSpeedString(for: 0) == "0KB/s")
        #expect(SpeedUtils.getSpeedString(for: 512 * 1024) == "512KB/s")
    }

    @Test func megabyteRange() {
        #expect(SpeedUtils.getSpeedString(for: 1024 * 1024) == "1.00MB/s")
        #expect(SpeedUtils.getSpeedString(for: 100 * 1024 * 1024) == "100.0MB/s")
    }

    @Test func gigabyteRange() {
        #expect(SpeedUtils.getSpeedString(for: 1500 * 1024 * 1024) == "1.5GB/s")
        // Widest producible string; the status item's fixed-width text
        // slot is sized from it.
        #expect(SpeedUtils.getSpeedString(for: 1_099_372_041_338) == "1023.9GB/s")
    }

    @Test func netStringHasNoRateSuffix() {
        #expect(SpeedUtils.getNetString(for: 512 * 1024) == "512KB")
        #expect(SpeedUtils.getNetString(for: 1024 * 1024) == "1.00MB")
    }
}
