import Foundation
import Network

/// Keep native error codes diagnosable without inventing meanings for undocumented codes.
enum NearbyAwareFailure {
    enum Operation: String {
        case advertising = "advertising"
        case browsing = "discovery"
        case metadata = "room metadata"
    }

    static func message(for error: any Error, during operation: Operation) -> String {
        let identifier: String
        if #available(iOS 26.0, *), let networkError = error as? NWError, case let .wifiAware(code) = networkError {
            identifier = "Wi-Fi Aware \(code)"
        } else {
            let native = error as NSError
            identifier = "\(native.domain) \(native.code)"
        }
        return "Wi-Fi Aware \(operation.rawValue) failed (\(identifier)). "
            + "Keep Wi-Fi enabled, check paired-device access in Settings, then turn Wi-Fi Aware off and on here to retry. "
            + "For iPhone–Android rooms, use Bluetooth or a shared local network; mixed-platform Aware pairing is not implemented."
    }
}
