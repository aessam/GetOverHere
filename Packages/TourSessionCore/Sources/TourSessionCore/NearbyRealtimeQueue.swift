import Foundation

/// Holds complete, already-sealed frames. Dropping audio never truncates a frame or
/// changes its ciphertext. Handshake/control frames are reliable and never evicted.
public struct NearbyRealtimeQueue: Sendable {
    private struct Entry: Sendable { let bytes: Data; let audio: Bool; let received: UInt64 }
    private var entries: [Entry] = []
    public static let capacity = 8
    public static let maximumFrameSize = 16_384
    public static let lifetimeMilliseconds: UInt64 = 150
    public private(set) var dropped = 0
    public var count: Int { entries.count }
    public init() {}

    public mutating func offer(_ bytes: Data, audio: Bool, nowMilliseconds: UInt64) throws {
        guard !bytes.isEmpty, bytes.count <= Self.maximumFrameSize else { throw RoomAdmissionError.invalidMessage }
        if entries.count == Self.capacity {
            guard let index = entries.firstIndex(where: \.audio) else { throw RoomAdmissionError.invalidMessage }
            entries.remove(at: index); dropped += 1
        }
        entries.append(Entry(bytes: bytes, audio: audio, received: nowMilliseconds))
    }

    public mutating func next(nowMilliseconds: UInt64) -> Data? {
        while !entries.isEmpty {
            let entry = entries.removeFirst()
            if entry.audio, nowMilliseconds >= entry.received,
               nowMilliseconds - entry.received > Self.lifetimeMilliseconds { dropped += 1; continue }
            return entry.bytes
        }
        return nil
    }
}
