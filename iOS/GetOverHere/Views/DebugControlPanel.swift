#if DEBUG
import SwiftUI

struct DebugControlPanel: View {
    @Environment(AppCoordinator.self) private var app
    var body: some View {
        NavigationStack {
            Form {
                Section("Debug control") {
                    Text(app.debugControl?.state ?? "disabled").accessibilityIdentifier("debugControlState")
                    ForEach(app.debugControl?.addresses ?? [], id: \.self) { Text($0).textSelection(.enabled) }
                    if let port = app.debugControl?.port { Text("Port \(Int(port))") }
                    Text("Explicit launch opt-in. TLS 1.3, pinned certificate, authenticated commands. Keeps the screen awake for this 15-minute session; Stop restores normal behavior. Locking the phone or leaving the app may suspend control. No room codes or control keys are displayed.")
                        .font(.caption)
                    Button("Stop Debug Control", role: .destructive) { app.debugControl?.stop() }
                }
            }
            .navigationTitle("Debug Control")
            .toolbar { Button("Done") { app.showDebugControl = false } }
        }
    }
}
#endif
