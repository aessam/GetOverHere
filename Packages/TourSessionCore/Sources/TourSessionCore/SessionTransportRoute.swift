public enum SessionTransportRoute: UInt8, CaseIterable, Sendable {
    case localLAN = 1
    case wifiAware = 2
}

public struct SessionRouteAvailability: Equatable, Sendable {
    public let hasLANHost: Bool
    public let hasWiFiAwareSession: Bool

    public init(hasLANHost: Bool, hasWiFiAwareSession: Bool) {
        self.hasLANHost = hasLANHost
        self.hasWiFiAwareSession = hasWiFiAwareSession
    }

    /// LAN is preferred because it works on the widest device/OS range. Aware is
    /// the direct fallback when LAN association or client isolation prevents an
    /// authenticated session from completing.
    public var orderedRoutes: [SessionTransportRoute] {
        var routes: [SessionTransportRoute] = []
        if hasLANHost { routes.append(.localLAN) }
        if hasWiFiAwareSession { routes.append(.wifiAware) }
        return routes
    }
}

/// Owns the single route selected for a guest session. Every media, control, and
/// asset lane must use this lease so a device is never counted or served twice.
public struct SessionRouteLease: Equatable, Sendable {
    public private(set) var selectedRoute: SessionTransportRoute?

    public init() {}

    @discardableResult
    public mutating func select(_ route: SessionTransportRoute) -> Bool {
        if let selectedRoute { return selectedRoute == route }
        selectedRoute = route
        return true
    }

    public mutating func reset() {
        selectedRoute = nil
    }
}
