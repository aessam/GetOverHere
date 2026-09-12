#if DEBUG
import Foundation
import os
import UIKit

/// Bounded observation of the actual running tour. Does not keep the process
/// alive, synthesize media, or turn connection assertions into acoustic proof.
@MainActor @Observable
final class GatewayScenarioRecorder {
    private(set) var state = "idle"
    private(set) var evidenceURL: URL?
    private(set) var sampleCount = 0
    private(set) var failedChecks = 0
    private var task: Task<Void, Never>?
    private var handle: FileHandle?
    private var bytesWritten = 0
    private var runID = UUID()
    private var originalBatteryMonitoring: Bool?
    private let maximumBytes = 16 * 1_024 * 1_024

    func start(seconds: Int, runID: UUID = UUID(), snapshot: @escaping () throws -> String) throws {
        guard task == nil, (1...5_400).contains(seconds) else { throw GatewayRecorderError.invalidState }
        let initial = try object(snapshot())
        guard Self.isActive(initial) else { throw GatewayRecorderError.noActiveTour }
        let room = Self.room(initial)
        self.runID = runID; sampleCount = 0; failedChecks = 0; bytesWritten = 0
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "GatewayRuns", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "\(runID.uuidString).jsonl")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw GatewayRecorderError.cannotCreateEvidence }
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw GatewayRecorderError.cannotCreateEvidence
        }
        handle = try FileHandle(forWritingTo: url); evidenceURL = url; state = "recording"
        originalBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        do {
            try append(["kind": "header", "runID": runID.uuidString, "durationSeconds": seconds,
                "roomID": room, "classification": "on-device-continuity-observation",
                "deviceID": initial["deviceID"] ?? "", "model": initial["model"] ?? "",
                "os": initial["os"] ?? "", "bundleBuild": initial["bundleBuild"] ?? "",
                "acousticQualification": "NOT RUN", "scaleQualification": "NOT RUN"])
        } catch { closeAfterFailure(error); throw error }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for _ in 0..<seconds {
                    try Task.checkCancellation()
                    var sample = try object(snapshot())
                    // Enrollment QR data is public but not needed in retained observations.
                    if var gateway = sample["gateway"] as? [String: Any] {
                        gateway.removeValue(forKey: "pairingQR"); sample["gateway"] = gateway
                    }
                    let sameRoom = Self.room(sample) == room
                    let active = Self.isActive(sample)
                    sampleCount += 1
                    if !sameRoom { failedChecks += 1 }
                    if !active { failedChecks += 1 }
                    try append(["kind": "sample", "monotonicNanoseconds": DispatchTime.now().uptimeNanoseconds,
                        "sameRoom": sameRoom, "active": active, "snapshot": sample])
                    try await Task.sleep(for: .seconds(1))
                }
                try finish(cancelled: false)
            } catch is CancellationError {
                do { try finish(cancelled: true) } catch { closeAfterFailure(error) }
            } catch { closeAfterFailure(error) }
        }
    }

    func cancel() { task?.cancel() }
    private func finish(cancelled: Bool) throws {
        let checks = sampleCount * 2
        state = cancelled ? "cancelled" : failedChecks == 0 ? "continuity-checks-passed" : "continuity-checks-failed"
        try append(["kind": "result", "runID": runID.uuidString, "status": state,
            "tests": ["executed": checks, "passed": checks - failedChecks, "failed": failedChecks, "skipped": 0],
            "meaning": "Per-sample same-room and actual active-state checks only; not acoustic or group qualification"])
        try handle?.synchronize(); try handle?.close(); handle = nil; task = nil
        restoreBatteryMonitoring()
    }
    private func append(_ object: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); bytes.append(10)
        guard bytesWritten <= maximumBytes - bytes.count else { throw GatewayRecorderError.evidenceLimit }
        try handle?.write(contentsOf: bytes); bytesWritten += bytes.count
    }
    private func closeAfterFailure(_ error: any Error) {
        state = "failed: \(error.localizedDescription)"
        Logger.transport.error("Gateway recorder failed (\(String(describing: type(of: error))), code=\((error as NSError).code))")
        do { try handle?.close() }
        catch { Logger.transport.error("Gateway evidence close failed (\(String(describing: type(of: error))), code=\((error as NSError).code))") }
        handle = nil; task = nil
        restoreBatteryMonitoring()
    }
    private func restoreBatteryMonitoring() {
        if let originalBatteryMonitoring { UIDevice.current.isBatteryMonitoringEnabled = originalBatteryMonitoring; self.originalBatteryMonitoring = nil }
    }
    private func object(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw GatewayRecorderError.invalidSnapshot
        }
        return object
    }
    private static func room(_ snapshot: [String: Any]) -> String {
        let gateway = snapshot["gateway"] as? [String: Any]
        return gateway?["role"] as? String == "companion" ? gateway?["roomID"] as? String ?? "" : snapshot["activeRoom"] as? String ?? ""
    }
    private static func isActive(_ snapshot: [String: Any]) -> Bool {
        let gateway = snapshot["gateway"] as? [String: Any]
        if gateway?["role"] as? String == "companion" {
            return gateway?["state"] as? String == "forwarding" && gateway?["nativeBranchState"] as? String == "advertising" && !room(snapshot).isEmpty
        }
        return snapshot["audio"] as? String == "running" && !room(snapshot).isEmpty
    }
}

private enum GatewayRecorderError: Error { case invalidState, noActiveTour, cannotCreateEvidence, evidenceLimit, invalidSnapshot }
#endif
