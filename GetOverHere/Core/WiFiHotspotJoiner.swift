import Foundation
import NetworkExtension
import os

/// Joins a WiFi hotspot created by an Android device.
/// Uses NEHotspotConfigurationManager (requires HotspotConfiguration entitlement).
@Observable
final class WiFiHotspotJoiner {
    private(set) var isConnected = false
    private(set) var currentSSID: String?
    private(set) var error: String?

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
        Logger.transport.info("WiFi disconnected")
    }
}
