import CoreLocation
import Foundation
import Observation
import TourSessionCore

enum LocalGuidanceStatus: Equatable {
    case idle
    case needsPermission
    case locating
    case ready
    case unavailable(String)
}

struct LocalTargetGuidance: Equatable {
    let distanceMeters: Double
    let targetBearingDegrees: Double
    let relativeArrowDegrees: Double?

    static func calculate(
        latitude: Double,
        longitude: Double,
        headingDegrees: Double?,
        target: TargetSnapshotPayload
    ) -> LocalTargetGuidance {
        let latitudeE7 = Int32((latitude * 10_000_000).rounded())
        let longitudeE7 = Int32((longitude * 10_000_000).rounded())
        let bearing = TargetGuidance.initialBearingDegrees(
            fromLatitudeE7: latitudeE7,
            fromLongitudeE7: longitudeE7,
            toLatitudeE7: target.latitudeE7,
            toLongitudeE7: target.longitudeE7
        )
        return LocalTargetGuidance(
            distanceMeters: TargetGuidance.distanceMeters(
                fromLatitudeE7: latitudeE7,
                fromLongitudeE7: longitudeE7,
                toLatitudeE7: target.latitudeE7,
                toLongitudeE7: target.longitudeE7
            ),
            targetBearingDegrees: bearing,
            relativeArrowDegrees: headingDegrees.map {
                TargetGuidance.relativeArrowDegrees(targetBearing: bearing, deviceHeading: $0)
            }
        )
    }
}

@Observable
@MainActor
final class LocalGuidanceService: NSObject {
    private(set) var status: LocalGuidanceStatus = .idle
    private(set) var location: CLLocation?
    private(set) var headingDegrees: Double?
    private(set) var magneticHeadingDegrees: Double?
    private(set) var headingAccuracyDegrees: Double?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var hasRequestedLocationAccess = false

    override init() {
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
        manager.headingFilter = 2
    }

    func requestAccessAndStart() {
        manager.delegate = self
        hasRequestedLocationAccess = true
        switch manager.authorizationStatus {
        case .notDetermined:
            status = .needsPermission
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            startUpdates()
        case .denied, .restricted:
            status = .needsPermission
        @unknown default:
            status = .unavailable("Unknown location authorization state")
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        location = nil
        headingDegrees = nil
        magneticHeadingDegrees = nil
        headingAccuracyDegrees = nil
        status = .idle
    }

    func startHeadingOnly() {
        manager.delegate = self
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        } else {
            headingDegrees = nil
            magneticHeadingDegrees = nil
            headingAccuracyDegrees = -1
        }
    }

    func guidance(to target: TargetSnapshotPayload) -> LocalTargetGuidance? {
        guard let coordinate = location?.coordinate else { return nil }
        return LocalTargetGuidance.calculate(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            headingDegrees: headingDegrees,
            target: target
        )
    }

    private func startUpdates() {
        status = .locating
        manager.startUpdatingLocation()
        startHeadingOnly()
    }
}

extension LocalGuidanceService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.hasRequestedLocationAccess else {
                self.status = .idle
                return
            }
            self.requestAccessAndStart()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.location = latest
            self?.status = .ready
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard heading.headingAccuracy >= 0 else {
            Task { @MainActor [weak self] in
                self?.headingDegrees = nil
                self?.magneticHeadingDegrees = nil
                self?.headingAccuracyDegrees = heading.headingAccuracy
            }
            return
        }
        let resolvedHeading = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        Task { @MainActor [weak self] in
            self?.headingDegrees = resolvedHeading
            self?.magneticHeadingDegrees = heading.magneticHeading
            self?.headingAccuracyDegrees = heading.headingAccuracy
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.status = .unavailable(error.localizedDescription)
        }
    }
}
