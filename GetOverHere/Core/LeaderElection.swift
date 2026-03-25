import Foundation
import os

/// Simplified RAFT-inspired leader election over BLE.
/// - Elects one device as leader (WiFi host coordinator)
/// - Android preferred as leader (can create WiFi hotspot programmatically)
/// - Heartbeat-based: leader sends periodic heartbeat, followers re-elect if missed
/// - No log replication — just leader election + heartbeat
@Observable
final class LeaderElection {
    enum Role: Equatable { case follower, candidate, leader }

    private(set) var role: Role = .follower
    private(set) var currentTerm = 0
    private(set) var leaderID: String?
    private(set) var votedFor: String?

    private let controlPlane: any ControlPlane
    private let localPeer: PeerInfo
    private var electionTimer: Task<Void, Never>?
    private var heartbeatTimer: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?

    /// Whether an Android device is connected (prefer Android as leader)
    var hasAndroidPeer: Bool {
        controlPlane.connectedPeers.contains { $0.platform == .android }
    }

    init(controlPlane: any ControlPlane) {
        self.controlPlane = controlPlane
        self.localPeer = controlPlane.localPeer
    }

    func start() {
        listenForCommands()
        startElectionTimeout()
        Logger.transport.info("RAFT: started as follower (term=\(self.currentTerm))")
    }

    func stop() {
        electionTimer?.cancel(); heartbeatTimer?.cancel(); commandTask?.cancel()
        role = .follower; leaderID = nil
    }

    // MARK: - Election

    private func startElectionTimeout() {
        electionTimer?.cancel()
        // Random timeout 3-6 seconds. If no heartbeat received, start election.
        let timeout = Double.random(in: 3...6)
        electionTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.startElection()
        }
    }

    private func startElection() {
        // If Android is present and we're iOS, defer to Android
        if localPeer.platform == .ios && hasAndroidPeer {
            Logger.transport.info("RAFT: deferring to Android peer")
            startElectionTimeout() // Wait for Android to claim leadership
            return
        }

        currentTerm += 1
        role = .candidate
        votedFor = localPeer.id
        var votes = 1 // Vote for self

        Logger.transport.info("RAFT: starting election (term=\(self.currentTerm))")

        // Request votes from all peers
        controlPlane.broadcast(.voteRequest(term: currentTerm, candidateID: localPeer.id))

        // If no peers, we win immediately
        if controlPlane.connectedPeers.isEmpty {
            becomeLeader()
            return
        }

        // Wait for votes (simplified: become leader after 2 seconds if still candidate)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.role == .candidate else { return }
            self.becomeLeader()
        }
    }

    private func becomeLeader() {
        role = .leader
        leaderID = localPeer.id
        Logger.transport.info("RAFT: became LEADER (term=\(self.currentTerm))")

        // Start heartbeat
        heartbeatTimer?.cancel()
        heartbeatTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.role == .leader else { break }
                self.controlPlane.broadcast(.heartbeat(term: self.currentTerm, leaderID: self.localPeer.id))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Command Handling

    private func listenForCommands() {
        commandTask = Task { [weak self] in
            guard let self else { return }
            for await (command, peer) in self.controlPlane.commands {
                switch command {
                case .heartbeat(let term, let leaderID):
                    self.handleHeartbeat(term: term, leaderID: leaderID)
                case .voteRequest(let term, let candidateID):
                    self.handleVoteRequest(term: term, candidateID: candidateID, from: peer)
                case .voteResponse(let term, let granted):
                    // Simplified: we don't count individual votes
                    break
                default:
                    break // Other commands handled by NetworkCoordinator
                }
            }
        }
    }

    private func handleHeartbeat(term: Int, leaderID: String) {
        if term >= currentTerm {
            currentTerm = term
            self.leaderID = leaderID
            role = .follower
            votedFor = nil
            startElectionTimeout() // Reset election timer
        }
    }

    private func handleVoteRequest(term: Int, candidateID: String, from peer: PeerInfo) {
        if term > currentTerm {
            currentTerm = term
            role = .follower
            votedFor = candidateID
            controlPlane.send(.voteResponse(term: term, granted: true), to: peer)
            startElectionTimeout()
            Logger.transport.info("RAFT: voted for \(peer.displayName) (term=\(term))")
        } else {
            controlPlane.send(.voteResponse(term: term, granted: false), to: peer)
        }
    }
}
