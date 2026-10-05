import DeviceDiscoveryUI
import Network
import SwiftUI
import WiFiAware

@available(iOS 26.4, *)
struct NearbyAwarePairingView: View {
    let isGuide: Bool
    var body: some View {
        VStack(alignment: .leading) {
            Text("Apple-device pairing only. For iPhone–Android rooms, use Bluetooth or a shared local network.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Keep Wi-Fi enabled. No router or Internet is needed. Pair devices once, then select the room. Device pairing is separate from the optional room code.")
                .font(.caption).foregroundStyle(.secondary)
            if isGuide {
                DevicePairingView(.wifiAware(.connecting(to: .getOverHereRoom,
                    from: .userSpecifiedDevices, datapath: .realtime))) {
                    Label("Pair nearby guests", systemImage: "antenna.radiowaves.left.and.right")
                } fallback: { Text("Wi-Fi Aware pairing unavailable on this device") }
            } else {
                DevicePicker(.wifiAware(.connecting(to: .userSpecifiedDevices, from: .getOverHereRoom)),
                    onSelect: { _ in /* The production browser resolves the paired guide and its room. */ }) {
                    Label("Pair nearby guide", systemImage: "antenna.radiowaves.left.and.right")
                } fallback: { Text("Wi-Fi Aware pairing unavailable on this device") }
                parameters: { NWParameters.applicationService.wifiAware { $0.performanceMode = .realtime } }
            }
        }
    }
}
