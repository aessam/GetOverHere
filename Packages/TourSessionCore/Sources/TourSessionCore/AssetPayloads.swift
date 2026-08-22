import Foundation

public struct SlideAssetDescriptor: Equatable, Sendable {
    public let slideID: String
    public let sha256: String
    public let byteLength: UInt64
    public let order: UInt32
    public let mimeType: String

    public init(
        slideID: String,
        sha256: String,
        byteLength: UInt64,
        order: UInt32,
        mimeType: String
    ) throws {
        try Self.validateSHA256(sha256)
        self.slideID = slideID
        self.sha256 = sha256
        self.byteLength = byteLength
        self.order = order
        self.mimeType = mimeType
    }

    fileprivate func encode(to writer: inout BinaryWriter) throws {
        try writer.append(slideID)
        writer.append(try Data(hex: sha256))
        writer.append(byteLength)
        writer.append(order)
        try writer.append(mimeType)
    }

    fileprivate static func decode(from reader: inout BinaryReader) throws -> SlideAssetDescriptor {
        let slideID = try reader.readString()
        let hash = try reader.readData(count: 32).lowercaseHex
        let byteLength = try reader.readUInt64()
        let order = try reader.readUInt32()
        let mimeType = try reader.readString()
        return try SlideAssetDescriptor(
            slideID: slideID,
            sha256: hash,
            byteLength: byteLength,
            order: order,
            mimeType: mimeType
        )
    }

    fileprivate static func validateSHA256(_ value: String) throws {
        guard value.count == 64,
              value == value.lowercased(),
              value.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw SessionProtocolError.invalidSHA256(value)
        }
    }
}

public enum TourAssetKind: UInt8, Sendable {
    case slide = 1
    case mapArchive = 2
    case mapStyle = 3
    case mapSprites = 4
    case mapGlyphs = 5
}

public struct TourAssetDescriptor: Equatable, Sendable {
    public let assetID: String
    public let kind: TourAssetKind
    public let sha256: String
    public let byteLength: UInt64
    public let order: UInt32
    public let mimeType: String

    public init(
        assetID: String,
        kind: TourAssetKind,
        sha256: String,
        byteLength: UInt64,
        order: UInt32,
        mimeType: String
    ) throws {
        try SlideAssetDescriptor.validateSHA256(sha256)
        self.assetID = assetID
        self.kind = kind
        self.sha256 = sha256
        self.byteLength = byteLength
        self.order = order
        self.mimeType = mimeType
    }

    fileprivate func encode(to writer: inout BinaryWriter) throws {
        try writer.append(assetID)
        writer.append(kind.rawValue)
        writer.append(try Data(hex: sha256))
        writer.append(byteLength)
        writer.append(order)
        try writer.append(mimeType)
    }

    fileprivate static func decode(from reader: inout BinaryReader) throws -> TourAssetDescriptor {
        let assetID = try reader.readString()
        let kindRaw = try reader.readUInt8()
        guard let kind = TourAssetKind(rawValue: kindRaw) else {
            throw SessionProtocolError.invalidAssetKind(kindRaw)
        }
        return try TourAssetDescriptor(
            assetID: assetID,
            kind: kind,
            sha256: try reader.readData(count: 32).lowercaseHex,
            byteLength: try reader.readUInt64(),
            order: try reader.readUInt32(),
            mimeType: try reader.readString()
        )
    }
}

public struct TourPackManifestPayload: Equatable, Sendable {
    public let packID: UUID
    public let manifestVersion: UInt64
    public let displayName: String
    public let assets: [TourAssetDescriptor]

    public init(
        packID: UUID,
        manifestVersion: UInt64,
        displayName: String,
        assets: [TourAssetDescriptor]
    ) throws {
        guard assets.count <= Int(UInt16.max) else {
            throw SessionProtocolError.tooManyAssets(assets.count)
        }
        var assetIDs = Set<String>()
        for asset in assets where !assetIDs.insert(asset.assetID).inserted {
            throw SessionProtocolError.duplicateAssetID(asset.assetID)
        }
        self.packID = packID
        self.manifestVersion = manifestVersion
        self.displayName = displayName
        self.assets = assets.sorted {
            ($0.order, $0.assetID) < ($1.order, $1.assetID)
        }
    }

    public func encode() throws -> Data {
        var writer = BinaryWriter()
        writer.append(packID)
        writer.append(manifestVersion)
        try writer.append(displayName)
        writer.append(UInt16(assets.count))
        for asset in assets { try asset.encode(to: &writer) }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> TourPackManifestPayload {
        var reader = BinaryReader(data: data)
        let packID = try reader.readUUID()
        let version = try reader.readUInt64()
        let displayName = try reader.readString()
        let count = Int(try reader.readUInt16())
        var assets = [TourAssetDescriptor]()
        assets.reserveCapacity(count)
        for _ in 0 ..< count { assets.append(try TourAssetDescriptor.decode(from: &reader)) }
        guard reader.remaining == 0 else { throw SessionProtocolError.trailingBytes(reader.remaining) }
        return try TourPackManifestPayload(
            packID: packID,
            manifestVersion: version,
            displayName: displayName,
            assets: assets
        )
    }
}

public struct AssetManifestPayload: Equatable, Sendable {
    public let deckID: UUID
    public let manifestVersion: UInt64
    public let assets: [SlideAssetDescriptor]

    public init(deckID: UUID, manifestVersion: UInt64, assets: [SlideAssetDescriptor]) throws {
        guard assets.count <= Int(UInt16.max) else {
            throw SessionProtocolError.tooManyAssets(assets.count)
        }
        self.deckID = deckID
        self.manifestVersion = manifestVersion
        self.assets = assets.sorted { $0.order < $1.order }
    }

    public func encode() throws -> Data {
        var writer = BinaryWriter()
        writer.append(deckID)
        writer.append(manifestVersion)
        writer.append(UInt16(assets.count))
        for asset in assets { try asset.encode(to: &writer) }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> AssetManifestPayload {
        var reader = BinaryReader(data: data)
        let deckID = try reader.readUUID()
        let version = try reader.readUInt64()
        let count = Int(try reader.readUInt16())
        var assets = [SlideAssetDescriptor]()
        assets.reserveCapacity(count)
        for _ in 0 ..< count { assets.append(try SlideAssetDescriptor.decode(from: &reader)) }
        guard reader.remaining == 0 else { throw SessionProtocolError.trailingBytes(reader.remaining) }
        return try AssetManifestPayload(deckID: deckID, manifestVersion: version, assets: assets)
    }
}

public struct AssetChunkPayload: Equatable, Sendable {
    public let sha256: String
    public let offset: UInt64
    public let totalLength: UInt64
    public let bytes: Data

    public init(sha256: String, offset: UInt64, totalLength: UInt64, bytes: Data) throws {
        try SlideAssetDescriptor.validateSHA256(sha256)
        guard offset <= totalLength, UInt64(bytes.count) <= totalLength - offset else {
            throw SessionProtocolError.invalidAssetChunk
        }
        self.sha256 = sha256
        self.offset = offset
        self.totalLength = totalLength
        self.bytes = bytes
    }

    public func encode() throws -> Data {
        var writer = BinaryWriter()
        writer.append(try Data(hex: sha256))
        writer.append(offset)
        writer.append(totalLength)
        writer.append(bytes)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> AssetChunkPayload {
        var reader = BinaryReader(data: data)
        let hash = try reader.readData(count: 32).lowercaseHex
        let offset = try reader.readUInt64()
        let totalLength = try reader.readUInt64()
        let bytes = try reader.readData(count: reader.remaining)
        return try AssetChunkPayload(sha256: hash, offset: offset, totalLength: totalLength, bytes: bytes)
    }
}

public struct AssetRequestPayload: Equatable, Sendable {
    public let sha256: String
    public let offset: UInt64

    public init(sha256: String, offset: UInt64) throws {
        try SlideAssetDescriptor.validateSHA256(sha256)
        self.sha256 = sha256
        self.offset = offset
    }

    public func encode() throws -> Data {
        var writer = BinaryWriter()
        writer.append(try Data(hex: sha256))
        writer.append(offset)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> AssetRequestPayload {
        var reader = BinaryReader(data: data)
        let hash = try reader.readData(count: 32).lowercaseHex
        let offset = try reader.readUInt64()
        guard reader.remaining == 0 else { throw SessionProtocolError.trailingBytes(reader.remaining) }
        return try AssetRequestPayload(sha256: hash, offset: offset)
    }
}

public enum AssetTransferStatus: UInt8, Sendable {
    case ready = 1
    case failed = 2
}

public struct AssetStatusPayload: Equatable, Sendable {
    public let sha256: String
    public let status: AssetTransferStatus
    public let byteLength: UInt64
    public let detail: String

    public init(
        sha256: String,
        status: AssetTransferStatus,
        byteLength: UInt64,
        detail: String
    ) throws {
        try SlideAssetDescriptor.validateSHA256(sha256)
        self.sha256 = sha256
        self.status = status
        self.byteLength = byteLength
        self.detail = detail
    }

    public func encode() throws -> Data {
        var writer = BinaryWriter()
        writer.append(try Data(hex: sha256))
        writer.append(status.rawValue)
        writer.append(byteLength)
        try writer.append(detail)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> AssetStatusPayload {
        var reader = BinaryReader(data: data)
        let hash = try reader.readData(count: 32).lowercaseHex
        let statusRaw = try reader.readUInt8()
        guard let status = AssetTransferStatus(rawValue: statusRaw) else {
            throw SessionProtocolError.invalidAssetStatus(statusRaw)
        }
        let byteLength = try reader.readUInt64()
        let detail = try reader.readString()
        guard reader.remaining == 0 else { throw SessionProtocolError.trailingBytes(reader.remaining) }
        return try AssetStatusPayload(
            sha256: hash,
            status: status,
            byteLength: byteLength,
            detail: detail
        )
    }
}
