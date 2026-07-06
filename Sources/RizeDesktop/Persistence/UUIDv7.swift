import Foundation

/// Generates RFC 9562 UUID version 7 identifiers.
///
/// Foundation ships no UUIDv7 generator, but the sync protocol requires every
/// client-created record (`activity_events.event_id`, and the `id` of every
/// other client-owned entity) to carry one: the 48-bit millisecond timestamp
/// prefix makes the identifier time-ordered, which is what lets the server
/// deduplicate retried uploads without a round trip to allocate an ID first
/// (see `documentation/sync-protocol.md` §Principles).
///
/// Layout (128 bits, big-endian byte order):
/// ```
/// 48 bits  unix_ts_ms
///  4 bits  version (0b0111)
/// 12 bits  rand_a
///  2 bits  variant (0b10)
/// 62 bits  rand_b
/// ```
enum UUIDv7 {
    /// Generates a new UUIDv7 using the system clock and a cryptographically
    /// seeded random source.
    static func generate() -> UUID {
        var rng = SystemRandomNumberGenerator()
        return generate(date: Date(), using: &rng)
    }

    /// Generates a new UUIDv7 from an explicit timestamp and random source,
    /// so callers can inject a deterministic clock/RNG in tests.
    static func generate(date: Date, using rng: inout some RandomNumberGenerator) -> UUID {
        let millis = UInt64(max(0, date.timeIntervalSince1970 * 1000).rounded(.down))

        var bytes = [UInt8](repeating: 0, count: 16)

        // 48-bit big-endian millisecond timestamp.
        bytes[0] = UInt8((millis >> 40) & 0xFF)
        bytes[1] = UInt8((millis >> 32) & 0xFF)
        bytes[2] = UInt8((millis >> 24) & 0xFF)
        bytes[3] = UInt8((millis >> 16) & 0xFF)
        bytes[4] = UInt8((millis >> 8) & 0xFF)
        bytes[5] = UInt8(millis & 0xFF)

        // rand_a (12 bits) packed into the low nibble of byte 6 and all of byte 7,
        // with the version (0111) in the high nibble of byte 6.
        let randA = UInt16.random(in: 0 ... 0xFFF, using: &rng)
        bytes[6] = 0x70 | UInt8((randA >> 8) & 0x0F)
        bytes[7] = UInt8(randA & 0xFF)

        // rand_b (62 bits) packed into bytes 8...15, with the variant (10) in
        // the top two bits of byte 8.
        let randB = UInt64.random(in: 0 ... UInt64.max, using: &rng)
        bytes[8] = 0x80 | UInt8((randB >> 56) & 0x3F)
        bytes[9] = UInt8((randB >> 48) & 0xFF)
        bytes[10] = UInt8((randB >> 40) & 0xFF)
        bytes[11] = UInt8((randB >> 32) & 0xFF)
        bytes[12] = UInt8((randB >> 24) & 0xFF)
        bytes[13] = UInt8((randB >> 16) & 0xFF)
        bytes[14] = UInt8((randB >> 8) & 0xFF)
        bytes[15] = UInt8(randB & 0xFF)

        let uuid = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }
}
