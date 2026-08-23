import AudioToolbox
import Foundation

enum NativeAudioCodecCapabilityError: Error, Equatable, CustomStringConvertible {
    case propertyInfo(property: AudioFormatPropertyID, status: OSStatus)
    case propertyRead(property: AudioFormatPropertyID, status: OSStatus)
    case invalidPropertySize(property: AudioFormatPropertyID, size: UInt32)

    var description: String {
        switch self {
        case let .propertyInfo(property, status):
            "audio format property \(property) size query failed with OSStatus \(status)"
        case let .propertyRead(property, status):
            "audio format property \(property) read failed with OSStatus \(status)"
        case let .invalidPropertySize(property, size):
            "audio format property \(property) returned invalid size \(size)"
        }
    }
}

struct NativeAudioCodecCapabilities: Equatable, Sendable {
    let opusEncoder: Bool
    let opusDecoder: Bool
    let aacLCEncoder: Bool
    let aacLCDecoder: Bool

    static func current() throws -> NativeAudioCodecCapabilities {
        let encodeFormats = try formatIDs(for: kAudioFormatProperty_EncodeFormatIDs)
        let decodeFormats = try formatIDs(for: kAudioFormatProperty_DecodeFormatIDs)
        return NativeAudioCodecCapabilities(
            opusEncoder: encodeFormats.contains(kAudioFormatOpus),
            opusDecoder: decodeFormats.contains(kAudioFormatOpus),
            aacLCEncoder: encodeFormats.contains(kAudioFormatMPEG4AAC),
            aacLCDecoder: decodeFormats.contains(kAudioFormatMPEG4AAC)
        )
    }

    private static func formatIDs(for property: AudioFormatPropertyID) throws -> Set<AudioFormatID> {
        var byteCount: UInt32 = 0
        let infoStatus = AudioFormatGetPropertyInfo(property, 0, nil, &byteCount)
        guard infoStatus == noErr else {
            throw NativeAudioCodecCapabilityError.propertyInfo(property: property, status: infoStatus)
        }
        guard byteCount.isMultiple(of: UInt32(MemoryLayout<AudioFormatID>.size)) else {
            throw NativeAudioCodecCapabilityError.invalidPropertySize(property: property, size: byteCount)
        }

        var formats = [AudioFormatID](
            repeating: 0,
            count: Int(byteCount) / MemoryLayout<AudioFormatID>.size
        )
        let readStatus = formats.withUnsafeMutableBytes { bytes in
            AudioFormatGetProperty(property, 0, nil, &byteCount, bytes.baseAddress)
        }
        guard readStatus == noErr else {
            throw NativeAudioCodecCapabilityError.propertyRead(property: property, status: readStatus)
        }
        return Set(formats)
    }
}
