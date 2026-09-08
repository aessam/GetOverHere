import Foundation
import Testing
@testable import TourSessionCore

struct SessionCapacityTopologyTests {
    private func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index))!
    }

    @Test func explicitBluetoothRoutePreservesExistingOrderingAndRawValues() {
        #expect(SessionTransportRoute.localLAN.rawValue == 1)
        #expect(SessionTransportRoute.wifiAware.rawValue == 2)
        #expect(SessionTransportRoute.bluetooth.rawValue == 3)
        #expect(SessionRouteAvailability(hasLANHost: true, hasWiFiAwareSession: true).orderedRoutes == [.localLAN, .wifiAware])
        #expect(SessionRouteAvailability(hasLANHost: true, hasWiFiAwareSession: true, hasBluetooth: true).orderedRoutes ==
            [.localLAN, .wifiAware, .bluetooth])
        #expect(SessionRouteAvailability(hasLANHost: false, hasWiFiAwareSession: false, hasBluetooth: true).orderedRoutes == [.bluetooth])
        var lease = SessionRouteLease()
        let selected = lease.select(.bluetooth)
        let replaced = lease.select(.wifiAware)
        #expect(selected)
        #expect(!replaced)
    }

    @Test func softwareBudgetIsNotRadioCapacityAndUpstreamIsSubtractedOnce() throws {
        #expect(SessionCapacityPolicy.listenerLimit == 30)
        #expect(SessionCapacityPolicy.maximumBridgeConnections == 98)
        #expect(try SessionCapacityPolicy.usableDirectPeerLimit(hardwareMaximumPaths: nil, availablePaths: nil,
            currentlyOwnedPaths: 0, upstreamReservation: 0) == nil)
        #expect(try SessionCapacityPolicy.usableDirectPeerLimit(hardwareMaximumPaths: 1, availablePaths: 1,
            currentlyOwnedPaths: 0, upstreamReservation: 0) == 1)
        #expect(try SessionCapacityPolicy.usableDirectPeerLimit(hardwareMaximumPaths: 8, availablePaths: 2,
            currentlyOwnedPaths: 5, upstreamReservation: 1, recoveryReservation: 1) == 5)
        #expect(try SessionCapacityPolicy.usableDirectPeerLimit(hardwareMaximumPaths: nil, availablePaths: 2,
            currentlyOwnedPaths: 5, upstreamReservation: 1) == 6)
        #expect(try SessionCapacityPolicy.usableDirectPeerLimit(hardwareMaximumPaths: 8, availablePaths: nil,
            currentlyOwnedPaths: 5, upstreamReservation: 1, recoveryReservation: 1) == 6)
        #expect(try SessionCapacityPolicy.usableDirectPeerLimit(hardwareMaximumPaths: 100, availablePaths: 100,
            currentlyOwnedPaths: 0, upstreamReservation: 0) == 30)
        #expect(try SessionCapacityPolicy.usableDirectPeerLimit(hardwareMaximumPaths: 1, availablePaths: 0,
            currentlyOwnedPaths: 1, upstreamReservation: 1, recoveryReservation: 1) == 0)
        for (maximum, available, owned, upstream, recovery) in [(-1, 0, 0, 0, 0), (8, -1, 0, 0, 0),
            (8, 0, -1, 0, 0), (8, 0, 0, -1, 0), (8, 0, 0, 0, -1), (8, 1, 8, 0, 0),
            (8, 0, 9, 0, 0), (Int.max, Int.max, 1, 0, 0), (8, 0, 0, Int.max, 1)] {
            #expect(throws: (any Error).self) {
                try SessionCapacityPolicy.usableDirectPeerLimit(hardwareMaximumPaths: maximum, availablePaths: available,
                    currentlyOwnedPaths: owned, upstreamReservation: upstream, recoveryReservation: recovery)
            }
        }
    }

    @Test func thirtyListenersIncludeFiveRelaysAndTwentyFiveLeaves() throws {
        var tree = try BoundedSessionTopology(rootID: id(0), rootChildLimit: 5)
        // Reverse arrival order makes UUID-ordered parent selection observable.
        for index in (1...5).reversed() {
            _ = try tree.attach(participantID: id(index), relayChildLimit: 5, nowMilliseconds: 0, leaseDurationMilliseconds: 1000)
        }
        for index in 6...30 {
            let lease = try tree.attach(participantID: id(index), nowMilliseconds: 0, leaseDurationMilliseconds: 1000)
            #expect(lease.depth == 2)
            #expect(lease.parentID == id((index - 6) / 5 + 1))
        }
        #expect(tree.listenerCount == 30)
        #expect(tree.generation == 30)
        #expect(tree.leases.filter { $0.depth == 1 }.count == 5)
        #expect(!tree.leases.contains { $0.participantID == id(0) })
        #expect(throws: SessionTopologyError.capacityFull) {
            try tree.attach(participantID: id(31), nowMilliseconds: 0, leaseDurationMilliseconds: 1000)
        }
        for relay in 1...5 { #expect(tree.leases.filter { $0.parentID == id(relay) }.count == 5) }
    }

    @Test func explicitDirectStarAndUnknownCapacityNeverInventRelays() throws {
        var star = try BoundedSessionTopology(rootID: id(0), rootChildLimit: 30)
        for index in 1...30 {
            let lease = try star.attach(participantID: id(index), nowMilliseconds: 0, leaseDurationMilliseconds: 1000)
            #expect(lease.depth == 1 && lease.parentID == id(0))
        }
        var unknown = try BoundedSessionTopology(rootID: id(0), rootChildLimit: nil)
        #expect(throws: SessionTopologyError.parentNotQualified) {
            try unknown.attach(participantID: id(1), nowMilliseconds: 0, leaseDurationMilliseconds: 1000)
        }
        var exhausted = try BoundedSessionTopology(rootID: id(0), rootChildLimit: 0)
        #expect(throws: SessionTopologyError.capacityFull) {
            try exhausted.attach(participantID: id(1), nowMilliseconds: 0, leaseDurationMilliseconds: 1000)
        }
    }

    @Test func promotionDuplicateParentsDepthAndStaleRouteCallbacksAreBounded() throws {
        var tree = try BoundedSessionTopology(rootID: id(0), rootChildLimit: 1)
        let original = try tree.attach(participantID: id(1), nowMilliseconds: 0, leaseDurationMilliseconds: 1000)
        #expect(throws: SessionTopologyError.parentNotQualified) {
            try tree.attach(participantID: id(2), preferredParentID: id(1), nowMilliseconds: 0, leaseDurationMilliseconds: 1000)
        }
        let relay = try tree.updateRelayCapacity(participantID: id(1), expectedGeneration: original.generation,
            childLimit: 5, nowMilliseconds: 1)
        let child = try tree.attach(participantID: id(2), preferredParentID: id(1), nowMilliseconds: 1, leaseDurationMilliseconds: 1000)
        let snapshot = tree.leases
        #expect(throws: SessionTopologyError.alreadyAttached) {
            try tree.attach(participantID: id(2), preferredParentID: id(0), nowMilliseconds: 1, leaseDurationMilliseconds: 1000)
        }
        #expect(throws: SessionTopologyError.parentNotQualified) {
            try tree.attach(participantID: id(3), preferredParentID: id(2), nowMilliseconds: 1, leaseDurationMilliseconds: 1000)
        }
        #expect(throws: SessionTopologyError.parentNotQualified) {
            try tree.updateRelayCapacity(participantID: id(2), expectedGeneration: child.generation, childLimit: 1, nowMilliseconds: 1)
        }
        #expect(throws: SessionTopologyError.capacityFull) {
            try tree.updateRelayCapacity(participantID: id(1), expectedGeneration: relay.generation, childLimit: nil, nowMilliseconds: 1)
        }
        #expect(throws: SessionTopologyError.staleLease) { try tree.detach(participantID: id(1), expectedGeneration: original.generation) }
        #expect(tree.leases == snapshot)
        #expect(try tree.detach(participantID: id(1), expectedGeneration: relay.generation) == [id(1), id(2)])
        let replacement = try tree.attach(participantID: id(1), nowMilliseconds: 2, leaseDurationMilliseconds: 1000)
        #expect(replacement.generation > relay.generation)
        #expect(throws: SessionTopologyError.staleLease) { try tree.detach(participantID: id(1), expectedGeneration: relay.generation) }
        #expect(tree.listenerCount == 1)
    }

    @Test func leaseRenewalExpiryAndSubtreeRemovalRejectResurrection() throws {
        var tree = try BoundedSessionTopology(rootID: id(0), rootChildLimit: 2)
        let relay = try tree.attach(participantID: id(1), relayChildLimit: 5, nowMilliseconds: 0, leaseDurationMilliseconds: 100)
        let other = try tree.attach(participantID: id(2), nowMilliseconds: 0, leaseDurationMilliseconds: 500)
        let child = try tree.attach(participantID: id(3), preferredParentID: id(1), nowMilliseconds: 0, leaseDurationMilliseconds: 500)
        #expect(try tree.expire(nowMilliseconds: 99).isEmpty)
        #expect(throws: SessionTopologyError.leaseExpired) {
            try tree.renew(participantID: id(3), expectedGeneration: child.generation, nowMilliseconds: 100, leaseDurationMilliseconds: 500)
        }
        #expect(throws: SessionTopologyError.leaseExpired) {
            try tree.attach(participantID: id(4), preferredParentID: id(1), nowMilliseconds: 100, leaseDurationMilliseconds: 500)
        }
        #expect(try tree.expire(nowMilliseconds: 100) == [relay.participantID, child.participantID])
        #expect(tree.listenerCount == 1)
        let renewed = try tree.renew(participantID: other.participantID, expectedGeneration: other.generation,
            nowMilliseconds: 100, leaseDurationMilliseconds: 600)
        #expect(renewed.expiresAtMilliseconds == 700)
        #expect(throws: SessionTopologyError.staleLease) {
            try tree.renew(participantID: other.participantID, expectedGeneration: other.generation,
                nowMilliseconds: 100, leaseDurationMilliseconds: 600)
        }
        #expect(try tree.expire(nowMilliseconds: 700) == [other.participantID])
    }

    @Test func invalidCapacitySelfAttachmentAndUnboundedLeasesReject() throws {
        for limit in [-1, 31] { #expect(throws: (any Error).self) { try BoundedSessionTopology(rootID: id(0), rootChildLimit: limit) } }
        var tree = try BoundedSessionTopology(rootID: id(0), rootChildLimit: 5)
        #expect(throws: SessionTopologyError.rootCannotBeListener) {
            try tree.attach(participantID: id(0), nowMilliseconds: 0, leaseDurationMilliseconds: 100)
        }
        #expect(throws: SessionTopologyError.parentNotQualified) {
            try tree.attach(participantID: id(1), preferredParentID: id(1), nowMilliseconds: 0, leaseDurationMilliseconds: 100)
        }
        #expect(throws: SessionTopologyError.unknownParticipant) {
            try tree.attach(participantID: id(1), preferredParentID: id(2), nowMilliseconds: 0, leaseDurationMilliseconds: 100)
        }
        for duration in [UInt64(0), 300_001, .max] {
            #expect(throws: SessionTopologyError.invalidLease) {
                try tree.attach(participantID: id(1), nowMilliseconds: 0, leaseDurationMilliseconds: duration)
            }
        }
        #expect(throws: SessionTopologyError.invalidLease) {
            try tree.attach(participantID: id(1), nowMilliseconds: UInt64(Int64.max), leaseDurationMilliseconds: 1)
        }
        #expect(throws: SessionTopologyError.invalidCapacity) {
            try tree.attach(participantID: id(1), relayChildLimit: 6, nowMilliseconds: 0, leaseDurationMilliseconds: 100)
        }
        #expect(tree.listenerCount == 0 && tree.generation == 0)
    }
}
