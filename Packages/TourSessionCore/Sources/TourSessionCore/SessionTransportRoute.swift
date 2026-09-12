public enum SessionTransportRoute: UInt8, CaseIterable, Sendable {
    case localLAN = 1
    case wifiAware = 2
    case bluetooth = 3
    case applePeer = 4
}

public struct SessionRouteAvailability: Equatable, Sendable {
    public let hasLANHost: Bool
    public let hasWiFiAwareSession: Bool
    public let hasBluetooth: Bool
    public let hasApplePeerSession: Bool

    public init(hasLANHost: Bool, hasWiFiAwareSession: Bool, hasBluetooth: Bool = false, hasApplePeerSession: Bool = false) {
        self.hasLANHost = hasLANHost
        self.hasWiFiAwareSession = hasWiFiAwareSession
        self.hasBluetooth = hasBluetooth
        self.hasApplePeerSession = hasApplePeerSession
    }

    /// LAN is preferred because it works on the widest device/OS range. Aware is
    /// the direct fallback when LAN association or client isolation prevents an
    /// authenticated session from completing.
    public var orderedRoutes: [SessionTransportRoute] {
        var routes: [SessionTransportRoute] = []
        if hasLANHost { routes.append(.localLAN) }
        if hasWiFiAwareSession { routes.append(.wifiAware) }
        if hasApplePeerSession { routes.append(.applePeer) }
        if hasBluetooth { routes.append(.bluetooth) }
        return routes
    }
}

/// Strict gateway qualification never succeeds by silently substituting another
/// radio. This controls permitted providers, not proof of the OS-selected path.
public struct AllowedTransportPolicy: Equatable, Sendable {
    public let routes: Set<SessionTransportRoute>
    public init(routes: Set<SessionTransportRoute>) { self.routes = routes }
    public static let standard = Self(routes: Set(SessionTransportRoute.allCases))
    public static let gatewayIOS = Self(routes: [.applePeer])
    public static let gatewayAndroid = Self(routes: [.wifiAware])
    public func allows(_ route: SessionTransportRoute) -> Bool { routes.contains(route) }
    public func filtered(_ candidates: [SessionTransportRoute]) -> [SessionTransportRoute] {
        candidates.filter(allows)
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
