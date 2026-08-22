import Foundation

/// Public metadata sent on the Wi-Fi Aware bootstrap connection before GOH2
/// authentication opens the independent realtime, control, and asset lanes.
public struct AwareSessionAnnouncement: Equatable, Sendable {
    public static let wireVersion: UInt8 = 1
    private static let magic = Data("GOHA".utf8)

    public let sessionID: UUID
    public let guideID: UUID
    public let guidePlatform: ParticipantPlatform
    public let realtimePort: UInt16
    public let controlPort: UInt16
    public let assetPort: UInt16
    public let channelName: String
    public let guideDisplayName: String

    public init(
        sessionID: UUID,
        guideID: UUID,
        guidePlatform: ParticipantPlatform,
        realtimePort: UInt16,
        controlPort: UInt16,
        assetPort: UInt16,
        channelName: String,
        guideDisplayName: String
    ) throws {
        guard realtimePort != 0, controlPort != 0, assetPort != 0 else {
            throw SessionProtocolError.invalidAwarePort
        }
        self.sessionID = sessionID
        self.guideID = guideID
        self.guidePlatform = guidePlatform
        self.realtimePort = realtimePort
        self.controlPort = controlPort
        self.assetPort = assetPort
        self.channelName = channelName
        self.guideDisplayName = guideDisplayName
    }

    public func encode() throws -> Data {
        var writer = BinaryWriter(capacity: 64 + channelName.utf8.count + guideDisplayName.utf8.count)
        writer.append(Self.magic)
        writer.append(Self.wireVersion)
        writer.append(sessionID)
        writer.append(guideID)
        writer.append(guidePlatform.rawValue)
        writer.append(realtimePort)
        writer.append(controlPort)
        writer.append(assetPort)
        try writer.append(channelName)
        try writer.append(guideDisplayName)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> AwareSessionAnnouncement {
        var reader = BinaryReader(data: data)
        guard try reader.readData(count: magic.count) == magic else {
            throw SessionProtocolError.invalidMagic
        }
        let version = try reader.readUInt8()
        guard version == wireVersion else {
            throw SessionProtocolError.unsupportedAwareVersion(version)
        }
        let sessionID = try reader.readUUID()
        let guideID = try reader.readUUID()
        let platformRaw = try reader.readUInt8()
        guard let guidePlatform = ParticipantPlatform(rawValue: platformRaw) else {
            throw SessionProtocolError.invalidPlatform(platformRaw)
        }
        let realtimePort = try reader.readUInt16()
        let controlPort = try reader.readUInt16()
        let assetPort = try reader.readUInt16()
        let channelName = try reader.readString()
        let guideDisplayName = try reader.readString()
        guard reader.remaining == 0 else {
            throw SessionProtocolError.trailingBytes(reader.remaining)
        }
        return try AwareSessionAnnouncement(
            sessionID: sessionID,
            guideID: guideID,
            guidePlatform: guidePlatform,
            realtimePort: realtimePort,
            controlPort: controlPort,
            assetPort: assetPort,
            channelName: channelName,
            guideDisplayName: guideDisplayName
        )
    }
}
