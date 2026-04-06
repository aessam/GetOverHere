import Foundation
import NetworkExtension
import Darwin
import os

/// Joins a WiFi hotspot created by an Android device.
/// Uses NEHotspotConfigurationManager (requires HotspotConfiguration entitlement).
/// After joining, discovers gateway IP (= Android device) and local IP via getifaddrs.
@Observable
final class WiFiHotspotJoiner {
    private(set) var isConnected = false
    private(set) var currentSSID: String?
    private(set) var error: String?

    /// The hotspot gateway IP — this is the Android device's IP on the hotspot network.
    private(set) var gatewayIP: String?
    /// Our own IP on the hotspot network (for announcing as TCP audio server).
    private(set) var localIP: String?

    func join(ssid: String, password: String) {
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        config.joinOnce = false

        NEHotspotConfigurationManager.shared.apply(config) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.error = error.localizedDescription
                    self?.isConnected = false
                    Logger.transport.error("WiFi join failed: \(error.localizedDescription)")
                } else {
                    self?.isConnected = true
                    self?.currentSSID = ssid
                    self?.error = nil
                    Logger.transport.info("WiFi joined: \(ssid)")
                    // Wait for IP assignment, then discover network addresses
                    await self?.discoverWithRetry()
                }
            }
        }
    }

    func disconnect() {
        if let ssid = currentSSID {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        }
        isConnected = false
        currentSSID = nil
        gatewayIP = nil
        localIP = nil
        Logger.transport.info("WiFi disconnected")
    }

    // MARK: - Network Address Discovery

    private func discoverWithRetry() async {
        for attempt in 1...5 {
            discoverNetworkAddresses()
            if gatewayIP != nil { return }
            Logger.transport.info("Gateway discovery attempt \(attempt) — waiting for IP assignment...")
            try? await Task.sleep(for: .seconds(1))
        }
        Logger.transport.error("Failed to discover gateway IP after 5 attempts")
    }

    /// Discover local IP and gateway IP from the en0 WiFi interface.
    /// Gateway = (IP & netmask) | 1 — standard for Android hotspot subnets.
    private func discoverNetworkAddresses() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            Logger.transport.error("getifaddrs failed: \(String(cString: strerror(errno)))")
            return
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }

            let name = String(cString: ifa.pointee.ifa_name)
            guard name == "en0",
                  let addrPtr = ifa.pointee.ifa_addr,
                  addrPtr.pointee.sa_family == UInt8(AF_INET),
                  let maskPtr = ifa.pointee.ifa_netmask else { continue }

            // Extract local IP
            let sinAddr = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var localAddrCopy = sinAddr.sin_addr
            var localBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &localAddrCopy, &localBuf, socklen_t(INET_ADDRSTRLEN))
            localIP = String(cString: localBuf)

            // Compute gateway: (IP & mask) | 1
            let sinMask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let addrHost = UInt32(bigEndian: sinAddr.sin_addr.s_addr)
            let maskHost = UInt32(bigEndian: sinMask.sin_addr.s_addr)
            let gatewayHost = (addrHost & maskHost) | 1
            var gatewayAddr = in_addr(s_addr: gatewayHost.bigEndian)
            var gatewayBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &gatewayAddr, &gatewayBuf, socklen_t(INET_ADDRSTRLEN))
            gatewayIP = String(cString: gatewayBuf)

            Logger.transport.info("WiFi addresses: local=\(self.localIP ?? "?"), gateway=\(self.gatewayIP ?? "?")")
            return
        }
        Logger.transport.warning("No en0 IPv4 address found")
    }
}
