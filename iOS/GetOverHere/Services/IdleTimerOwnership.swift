import Foundation
import UIKit

/// Debugging and production companion mode have independent ownership. Releasing
/// one must not disable the other's explicit keep-awake request.
@MainActor
enum IdleTimerOwnership {
    private static var owners = Set<UUID>()
    private static var original: Bool?
    static func acquire(_ owner: UUID) {
        if owners.isEmpty { original = UIApplication.shared.isIdleTimerDisabled }
        owners.insert(owner)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    static func release(_ owner: UUID) {
        guard owners.remove(owner) != nil, owners.isEmpty else { return }
        if let original { UIApplication.shared.isIdleTimerDisabled = original }
        original = nil
    }
}
