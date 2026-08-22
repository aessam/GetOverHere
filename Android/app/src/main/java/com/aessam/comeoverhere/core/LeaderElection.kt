package com.aessam.comeoverhere.core

import android.util.Log
import kotlinx.coroutines.*

/**
 * Simplified RAFT-inspired leader election over BLE.
 * - Elects one device as leader (WiFi host coordinator)
 * - Android PREFERS to be leader (can create WiFi hotspot programmatically)
 * - Heartbeat-based: leader sends periodic heartbeat, followers re-elect if missed
 * - No log replication — just leader election + heartbeat
 */
class LeaderElection(
    private val controlPlane: ControlPlane,
    private val scope: CoroutineScope
) {
    enum class Role { FOLLOWER, CANDIDATE, LEADER }

    @Volatile var role: Role = Role.FOLLOWER; private set
    @Volatile var currentTerm: Int = 0; private set
    @Volatile var leaderID: String? = null; private set
    @Volatile var votedFor: String? = null; private set

    private val localPeer get() = controlPlane.localPeer

    /** Whether an iOS device is connected (Android is preferred leader) */
    private val hasIosPeer: Boolean
        get() = controlPlane.connectedPeers.value.any { it.platform == PeerInfo.Platform.IOS }

    private var electionJob: Job? = null
    private var heartbeatJob: Job? = null
    private var commandJob: Job? = null

    val isLeader: Boolean get() = role == Role.LEADER

    companion object {
        private const val TAG = "LeaderElection"
    }

    fun start() {
        listenForCommands()
        startElectionTimeout()
        Log.i(TAG, "RAFT: started as follower (term=$currentTerm)")
    }

    fun stop() {
        electionJob?.cancel()
        heartbeatJob?.cancel()
        commandJob?.cancel()
        role = Role.FOLLOWER
        leaderID = null
    }

    // MARK: - Election

    private fun startElectionTimeout() {
        electionJob?.cancel()
        // Random timeout 3–6 seconds. Android gets a shorter timeout to prefer winning.
        val timeout = if (localPeer.platform == PeerInfo.Platform.ANDROID) {
            2000L + (Math.random() * 1000).toLong()
        } else {
            3000L + (Math.random() * 3000).toLong()
        }
        electionJob = scope.launch {
            delay(timeout)
            if (isActive) startElection()
        }
    }

    private fun startElection() {
        // If iOS peer is connected and we already have a leader that's iOS, defer
        // Android does NOT defer — it actively seeks leadership to create the hotspot
        currentTerm++
        role = Role.CANDIDATE
        votedFor = localPeer.id

        Log.i(TAG, "RAFT: starting election (term=$currentTerm)")

        controlPlane.broadcast(BLECommand.VoteRequest(term = currentTerm, candidateID = localPeer.id))

        if (controlPlane.connectedPeers.value.isEmpty()) {
            becomeLeader()
            return
        }

        // Wait for votes — simplified: become leader after 2s if still candidate
        scope.launch {
            delay(2000)
            if (role == Role.CANDIDATE) {
                becomeLeader()
            }
        }
    }

    private fun becomeLeader() {
        role = Role.LEADER
        leaderID = localPeer.id
        Log.i(TAG, "RAFT: became LEADER (term=$currentTerm)")

        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (isActive && role == Role.LEADER) {
                controlPlane.broadcast(BLECommand.Heartbeat(term = currentTerm, leaderID = localPeer.id))
                delay(2000)
            }
        }
    }

    // MARK: - Command Handling

    private fun listenForCommands() {
        commandJob = scope.launch {
            controlPlane.commands.collect { (command, peer) ->
                when (command) {
                    is BLECommand.Heartbeat -> handleHeartbeat(command.term, command.leaderID)
                    is BLECommand.VoteRequest -> handleVoteRequest(command.term, command.candidateID, peer)
                    is BLECommand.VoteResponse -> { /* simplified — not counting individual votes */ }
                    else -> { /* other commands handled by NetworkCoordinator */ }
                }
            }
        }
    }

    private fun handleHeartbeat(term: Int, incomingLeaderID: String) {
        if (term >= currentTerm) {
            currentTerm = term
            leaderID = incomingLeaderID
            role = Role.FOLLOWER
            votedFor = null
            startElectionTimeout()
        }
    }

    private fun handleVoteRequest(term: Int, candidateID: String, from: PeerInfo) {
        if (term > currentTerm) {
            currentTerm = term
            role = Role.FOLLOWER
            votedFor = candidateID
            controlPlane.send(BLECommand.VoteResponse(term = term, granted = true), from)
            startElectionTimeout()
            Log.i(TAG, "RAFT: vote recorded (term=$term)")
        } else {
            controlPlane.send(BLECommand.VoteResponse(term = term, granted = false), from)
        }
    }
}
