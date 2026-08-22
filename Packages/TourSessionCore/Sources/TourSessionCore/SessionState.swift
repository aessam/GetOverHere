import Foundation

public struct PresentationSnapshotPayload: Equatable, Sendable {
    public let stateVersion: UInt64
    public let deckID: UUID
    public let currentSlideID: String?
    public let isVisible: Bool
    public let effectiveAtMilliseconds: UInt64

    public init(
        stateVersion: UInt64,
        deckID: UUID,
        currentSlideID: String?,
        isVisible: Bool,
        effectiveAtMilliseconds: UInt64
    ) {
        self.stateVersion = stateVersion
        self.deckID = deckID
        self.currentSlideID = currentSlideID
        self.isVisible = isVisible
        self.effectiveAtMilliseconds = effectiveAtMilliseconds
    }

    public func encode() throws -> Data {
        var writer = BinaryWriter()
        writer.append(stateVersion)
        writer.append(deckID)
        writer.append(UInt8(isVisible ? 1 : 0))
        writer.append(effectiveAtMilliseconds)
        try writer.append(currentSlideID ?? "")
        return writer.data
    }

    public static func decode(_ data: Data) throws -> PresentationSnapshotPayload {
        var reader = BinaryReader(data: data)
        let stateVersion = try reader.readUInt64()
        let deckID = try reader.readUUID()
        let visibleRaw = try reader.readUInt8()
        guard visibleRaw <= 1 else { throw SessionProtocolError.invalidBoolean(visibleRaw) }
        let effectiveAtMilliseconds = try reader.readUInt64()
        let slide = try reader.readString()
        guard reader.remaining == 0 else { throw SessionProtocolError.trailingBytes(reader.remaining) }
        return PresentationSnapshotPayload(
            stateVersion: stateVersion,
            deckID: deckID,
            currentSlideID: slide.isEmpty ? nil : slide,
            isVisible: visibleRaw == 1,
            effectiveAtMilliseconds: effectiveAtMilliseconds
        )
    }
}

public enum TourVisualMode: UInt8, Sendable {
    case slides = 1
    case map = 2
    case pointer = 3
}

public struct VisualFocusSnapshotPayload: Equatable, Sendable {
    public let stateVersion: UInt64
    public let mode: TourVisualMode

    public init(stateVersion: UInt64, mode: TourVisualMode) {
        self.stateVersion = stateVersion
        self.mode = mode
    }

    public func encode() -> Data {
        var writer = BinaryWriter()
        writer.append(stateVersion)
        writer.append(mode.rawValue)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> VisualFocusSnapshotPayload {
        var reader = BinaryReader(data: data)
        let stateVersion = try reader.readUInt64()
        let rawMode = try reader.readUInt8()
        guard let mode = TourVisualMode(rawValue: rawMode) else {
            throw SessionProtocolError.invalidVisualMode(rawMode)
        }
        guard reader.remaining == 0 else { throw SessionProtocolError.trailingBytes(reader.remaining) }
        return VisualFocusSnapshotPayload(stateVersion: stateVersion, mode: mode)
    }
}

public enum BearingReference: UInt8, Sendable {
    case magnetic = 1
    case trueNorth = 2
}

public struct BearingSnapshotPayload: Equatable, Sendable {
    public let stateVersion: UInt64
    public let reference: BearingReference
    public let bearingMilliDegrees: UInt32
    public let isVisible: Bool

    public init(
        stateVersion: UInt64,
        reference: BearingReference,
        bearingMilliDegrees: UInt32,
        isVisible: Bool
    ) throws {
        guard bearingMilliDegrees < 360_000 else {
            throw SessionProtocolError.invalidBearingMilliDegrees(bearingMilliDegrees)
        }
        self.stateVersion = stateVersion
        self.reference = reference
        self.bearingMilliDegrees = bearingMilliDegrees
        self.isVisible = isVisible
    }

    public func encode() -> Data {
        var writer = BinaryWriter()
        writer.append(stateVersion)
        writer.append(reference.rawValue)
        writer.append(bearingMilliDegrees)
        writer.append(UInt8(isVisible ? 1 : 0))
        return writer.data
    }

    public static func decode(_ data: Data) throws -> BearingSnapshotPayload {
        var reader = BinaryReader(data: data)
        let stateVersion = try reader.readUInt64()
        let referenceRaw = try reader.readUInt8()
        guard let reference = BearingReference(rawValue: referenceRaw) else {
            throw SessionProtocolError.invalidBearingReference(referenceRaw)
        }
        let bearing = try reader.readUInt32()
        let visibleRaw = try reader.readUInt8()
        guard visibleRaw <= 1 else { throw SessionProtocolError.invalidBoolean(visibleRaw) }
        guard reader.remaining == 0 else { throw SessionProtocolError.trailingBytes(reader.remaining) }
        return try BearingSnapshotPayload(
            stateVersion: stateVersion,
            reference: reference,
            bearingMilliDegrees: bearing,
            isVisible: visibleRaw == 1
        )
    }
}

public struct TargetSnapshotPayload: Equatable, Sendable {
    public static let latitudeRangeE7: ClosedRange<Int32> = -900_000_000 ... 900_000_000
    public static let longitudeRangeE7: ClosedRange<Int32> = -1_800_000_000 ... 1_800_000_000

    public let stateVersion: UInt64
    public let targetID: UUID
    public let latitudeE7: Int32
    public let longitudeE7: Int32
    public let label: String
    public let isVisible: Bool

    public init(
        stateVersion: UInt64,
        targetID: UUID,
        latitudeE7: Int32,
        longitudeE7: Int32,
        label: String,
        isVisible: Bool
    ) throws {
        guard Self.latitudeRangeE7.contains(latitudeE7) else {
            throw SessionProtocolError.invalidLatitudeE7(latitudeE7)
        }
        guard Self.longitudeRangeE7.contains(longitudeE7) else {
            throw SessionProtocolError.invalidLongitudeE7(longitudeE7)
        }
        self.stateVersion = stateVersion
        self.targetID = targetID
        self.latitudeE7 = latitudeE7
        self.longitudeE7 = longitudeE7
        self.label = label
        self.isVisible = isVisible
    }

    public func encode() throws -> Data {
        var writer = BinaryWriter()
        writer.append(stateVersion)
        writer.append(targetID)
        writer.append(latitudeE7)
        writer.append(longitudeE7)
        writer.append(UInt8(isVisible ? 1 : 0))
        try writer.append(label)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> TargetSnapshotPayload {
        var reader = BinaryReader(data: data)
        let stateVersion = try reader.readUInt64()
        let targetID = try reader.readUUID()
        let latitudeE7 = try reader.readInt32()
        let longitudeE7 = try reader.readInt32()
        let visibleRaw = try reader.readUInt8()
        guard visibleRaw <= 1 else { throw SessionProtocolError.invalidBoolean(visibleRaw) }
        let label = try reader.readString()
        guard reader.remaining == 0 else { throw SessionProtocolError.trailingBytes(reader.remaining) }
        return try TargetSnapshotPayload(
            stateVersion: stateVersion,
            targetID: targetID,
            latitudeE7: latitudeE7,
            longitudeE7: longitudeE7,
            label: label,
            isVisible: visibleRaw == 1
        )
    }
}
