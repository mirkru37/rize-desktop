@testable import RizeDesktop
import XCTest

final class UUIDv7Tests: XCTestCase {
    /// A deterministic RNG so byte layout assertions don't depend on the
    /// system random source.
    private struct FixedRNG: RandomNumberGenerator {
        var values: [UInt64]
        var index = 0

        mutating func next() -> UInt64 {
            defer { index += 1 }
            return values[index % values.count]
        }
    }

    func testVersionNibbleIsSeven() {
        var rng = FixedRNG(values: [0x0000_0000_0000_0FFF, 0x1234_5678_9ABC_DEF0])
        let uuid = UUIDv7.generate(date: Date(), using: &rng)

        let versionNibble = (uuid.uuid.6 & 0xF0) >> 4
        XCTAssertEqual(versionNibble, 0x7)
    }

    func testVariantBitsAreRFC9562() {
        var rng = FixedRNG(values: [0x0000_0000_0000_0FFF, 0x1234_5678_9ABC_DEF0])
        let uuid = UUIDv7.generate(date: Date(), using: &rng)

        let variantBits = (uuid.uuid.8 & 0xC0) >> 6
        XCTAssertEqual(variantBits, 0b10)
    }

    func testEncodesMillisecondTimestampInLeadingBytes() {
        var rng = FixedRNG(values: [0, 0])
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let expectedMillis = UInt64((date.timeIntervalSince1970 * 1000).rounded(.down))

        let uuid = UUIDv7.generate(date: date, using: &rng)
        let bytes = uuid.uuid

        let decodedMillis =
            (UInt64(bytes.0) << 40) | (UInt64(bytes.1) << 32) | (UInt64(bytes.2) << 24) |
            (UInt64(bytes.3) << 16) | (UInt64(bytes.4) << 8) | UInt64(bytes.5)

        XCTAssertEqual(decodedMillis, expectedMillis)
    }

    func testIsMonotonicallyOrderedByTimestamp() {
        var rng = FixedRNG(values: [0x0AAA, 0x1111_1111_1111_1111])

        let earlier = UUIDv7.generate(date: Date(timeIntervalSince1970: 1000), using: &rng)
        let later = UUIDv7.generate(date: Date(timeIntervalSince1970: 2000), using: &rng)

        XCTAssertTrue(earlier.uuidString < later.uuidString)
    }

    func testGeneratesUniqueIdentifiersForTheSameTimestamp() {
        var rng = SystemRandomNumberGenerator()
        let date = Date()

        let first = UUIDv7.generate(date: date, using: &rng)
        let second = UUIDv7.generate(date: date, using: &rng)

        XCTAssertNotEqual(first, second)
    }
}
