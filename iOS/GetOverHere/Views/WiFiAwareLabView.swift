import DeviceDiscoveryUI
import Network
import SwiftUI
import WiFiAware

@available(iOS 26.4, *)
struct WiFiAwareLabView: View {
    @State private var transport = WiFiAwareLabTransport()

    var body: some View {
        @Bindable var transport = transport
        NavigationStack {
            List {
                Section("Capability") {
                    LabeledContent("Supported", value: transport.capabilities.supported ? "Yes" : "No")
                    LabeledContent("Maximum connections", value: "\(transport.capabilities.maximumConnections)")
                    LabeledContent("Publish services", value: "\(transport.capabilities.maximumPublishableServices)")
                    LabeledContent("Subscribe services", value: "\(transport.capabilities.maximumSubscribableServices)")
                    LabeledContent("Paired devices", value: "\(transport.pairedDeviceCount)")
                }

                Section("Pair") {
                    Picker("Role", selection: $transport.role) {
                        ForEach(WiFiAwareLabTransport.Role.allCases) { role in
                            Text(role.rawValue.capitalized).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)

                    if transport.role == .publisher {
                        DevicePairingView(
                            .wifiAware(
                                .connecting(
                                    to: .getOverHereProbe,
                                    from: .userSpecifiedDevices,
                                    datapath: .realtime
                                )
                            )
                        ) {
                            Label("Make discoverable", systemImage: "antenna.radiowaves.left.and.right")
                        } fallback: {
                            Label("Pairing unavailable", systemImage: "xmark.circle")
                        }
                    } else {
                        DevicePicker(
                            .wifiAware(
                                .connecting(to: .userSpecifiedDevices, from: .getOverHereProbe)
                            ),
                            onSelect: { endpoint in
                                transport.events.insert("Paired endpoint: \(endpoint)", at: 0)
                            }
                        ) {
                            Label("Find publisher", systemImage: "magnifyingglass")
                        } fallback: {
                            Label("Pairing unavailable", systemImage: "xmark.circle")
                        } parameters: {
                            NWParameters.applicationService
                                .wifiAware { $0.performanceMode = .realtime }
                        }
                    }
                }

                Section("Transport") {
                    LabeledContent("State", value: transport.state.rawValue)
                    LabeledContent("Connected peers", value: "\(transport.connectedPeerCount)")

                    HStack {
                        Button("Start") { transport.start() }
                            .disabled(transport.state != .idle && transport.state != .failed)
                        Button("Stop", role: .destructive) { transport.stop() }
                            .disabled(transport.state == .idle)
                    }
                }

                Section("20 ms UDP probe") {
                    LabeledContent("Sent", value: "\(transport.sentFrameCount)")
                    LabeledContent("Received", value: "\(transport.receivedFrameCount)")
                    LabeledContent("Missing", value: "\(transport.missingFrameCount)")
                    LabeledContent("Malformed", value: "\(transport.malformedFrameCount)")
                    LabeledContent(
                        "p95 RTT",
                        value: String(format: "%.1f ms", transport.p95RoundTripMilliseconds)
                    )

                    HStack {
                        Button(transport.isProbing ? "Stop probe" : "Start probe") {
                            transport.toggleProbe()
                        }
                        .disabled(transport.connectedPeerCount == 0)
                        Button("Reset") { transport.resetMetrics() }
                    }
                }

                if let error = transport.lastError {
                    Section("Failure") {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section("Events") {
                    ForEach(Array(transport.events.enumerated()), id: \.offset) { _, event in
                        Text(event).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Wi-Fi Aware Lab")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onDisappear { transport.stop() }
    }
}
