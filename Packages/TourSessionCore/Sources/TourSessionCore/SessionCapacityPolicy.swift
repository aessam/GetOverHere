public enum SessionCapacityError: Error {
    case invalidResourceSnapshot
}

/// Software admission/bridge bounds, never a claim that a radio supports thirty peers.
public enum SessionCapacityPolicy {
    public static let listenerLimit = 30
    public static let persistentLanesPerListener = 3
    public static let transientAdmissionLimit = 8
    public static let maximumBridgeConnections = listenerLimit * persistentLanesPerListener + transientAdmissionLimit

    /// `currentlyOwnedPaths` includes upstream and downstream allocations. `availablePaths`
    /// excludes all current allocations, including ours. `upstreamReservation` is the total
    /// desired upstream allocation, not an additional reservation on top of an owned upstream.
    /// Nil means no hardware evidence; callers must not invent a universal NDP capacity.
    public static func usableDirectPeerLimit(hardwareMaximumPaths: Int?, availablePaths: Int?,
        currentlyOwnedPaths: Int, upstreamReservation: Int, recoveryReservation: Int = 0) throws -> Int? {
        guard currentlyOwnedPaths >= 0, upstreamReservation >= 0, recoveryReservation >= 0,
              hardwareMaximumPaths.map({ $0 >= 0 }) ?? true,
              availablePaths.map({ $0 >= 0 }) ?? true else { throw SessionCapacityError.invalidResourceSnapshot }
        let (reserved, reservationOverflow) = upstreamReservation.addingReportingOverflow(recoveryReservation)
        guard !reservationOverflow else { throw SessionCapacityError.invalidResourceSnapshot }
        var limit = hardwareMaximumPaths
        if let maximum = hardwareMaximumPaths, currentlyOwnedPaths > maximum {
            throw SessionCapacityError.invalidResourceSnapshot
        }
        if let available = availablePaths {
            let (total, overflow) = available.addingReportingOverflow(currentlyOwnedPaths)
            guard !overflow, hardwareMaximumPaths.map({ total <= $0 }) ?? true else {
                throw SessionCapacityError.invalidResourceSnapshot
            }
            limit = limit.map { min($0, total) } ?? total
        }
        guard let limit else { return nil }
        return min(listenerLimit, reserved >= limit ? 0 : limit - reserved)
    }
}
