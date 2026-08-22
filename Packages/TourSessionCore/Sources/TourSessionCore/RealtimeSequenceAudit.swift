public struct RealtimeSequenceAudit: Equatable, Sendable {
    public let uniquePackets: Int
    public let duplicatePackets: Int
    public let reorderedPackets: Int
    public let missingPackets: UInt64

    public init(sequences: [UInt64]) {
        var seen = Set<UInt64>()
        var highestSeen: UInt64?
        var duplicates = 0
        var reordered = 0

        for sequence in sequences {
            guard seen.insert(sequence).inserted else {
                duplicates += 1
                continue
            }
            if let highestSeen, sequence < highestSeen {
                reordered += 1
            }
            if highestSeen == nil || sequence > highestSeen! {
                highestSeen = sequence
            }
        }

        uniquePackets = seen.count
        duplicatePackets = duplicates
        reorderedPackets = reordered
        if let first = seen.min(), let last = seen.max() {
            missingPackets = last - first + 1 - UInt64(seen.count)
        } else {
            missingPackets = 0
        }
    }

    public var report: String {
        "unique=\(uniquePackets)|duplicates=\(duplicatePackets)|reordered=\(reorderedPackets)|missing=\(missingPackets)"
    }
}
