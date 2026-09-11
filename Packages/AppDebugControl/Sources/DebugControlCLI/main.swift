import Foundation
#if DEBUG
import AppDebugControl

@main
struct ControlCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 3 else {
                throw Usage.invalid
            }
            let keyURL = URL(fileURLWithPath: args[1])
            let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
            guard let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0 else { throw Usage.keyPermissions }
            let key = try Data(contentsOf: keyURL)
            let pin = try Data(contentsOf: keyURL.deletingLastPathComponent().appending(path: "certificate.sha256"))
            var values: [String: String] = [:]
            for pair in args.dropFirst(3) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, values[String(parts[0])] == nil else { throw Usage.invalid }
                values[String(parts[0])] = String(parts[1])
            }
            let verbose = ProcessInfo.processInfo.environment["GOH_CONTROL_VERBOSE"] == "1"
            let response = try await DebugControlClient.send(DebugRequest(command: args[2], arguments: values), host: args[0], key: key, certificatePin: pin,
                onState: { state in
                    if verbose { FileHandle.standardError.write(Data("Connection state: \(state)\n".utf8)) }
                })
            print(response.result)
            if !response.success { exit(2) }
        } catch {
            FileHandle.standardError.write(Data("Control failed (\(type(of: error))). Usage: goh-control HOST KEY_FILE COMMAND [key=value ...]; key file must be owner-only.\n".utf8))
            exit(1)
        }
    }
    enum Usage: Error { case invalid, keyPermissions }
}
#else
@main struct DisabledCLI { static func main() { fatalError("Debug control is excluded from release builds") } }
#endif
