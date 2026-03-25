import Foundation

// BLECommand already has Codable conformance via auto-synthesis.
// Since all cases use labeled parameters (no unnamed associated values),
// Swift's auto-synthesized Codable produces clean JSON without _0 wrappers.
//
// Example:
// BLECommand.channelAnnounce(...) → {"channelAnnounce": {"channelID": "...", ...}}
// BLECommand.wifiCredentials(ssid: "X", password: "Y") → {"wifiCredentials": {"ssid": "X", "password": "Y"}}
//
// This matches what Android's manual JSON builder produces. No custom Codable needed.
//
// NOTE: If you add a case with an unnamed parameter (e.g., case foo(Bar)),
// Swift WILL add _0. Always use labeled parameters for cross-platform enums.

// Custom Codable for BLECommand to ensure cross-platform compatibility
extension BLECommand {
    // Auto-synthesized Codable works because all cases use labeled parameters.
    // If this ever breaks, add explicit encode/decode here.
}
