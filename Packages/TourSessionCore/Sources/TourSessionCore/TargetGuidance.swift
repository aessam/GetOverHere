import Foundation

public enum TargetGuidance {
    private static let earthRadiusMeters = 6_371_000.0

    public static func distanceMeters(
        fromLatitudeE7: Int32,
        fromLongitudeE7: Int32,
        toLatitudeE7: Int32,
        toLongitudeE7: Int32
    ) -> Double {
        let fromLatitude = radians(fromLatitudeE7)
        let toLatitude = radians(toLatitudeE7)
        let latitudeDelta = toLatitude - fromLatitude
        let longitudeDelta = radians(toLongitudeE7) - radians(fromLongitudeE7)
        let rawA = pow(sin(latitudeDelta / 2), 2)
            + cos(fromLatitude) * cos(toLatitude) * pow(sin(longitudeDelta / 2), 2)
        let a = min(1, max(0, rawA))
        return earthRadiusMeters * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    public static func initialBearingDegrees(
        fromLatitudeE7: Int32,
        fromLongitudeE7: Int32,
        toLatitudeE7: Int32,
        toLongitudeE7: Int32
    ) -> Double {
        let fromLatitude = radians(fromLatitudeE7)
        let toLatitude = radians(toLatitudeE7)
        let longitudeDelta = radians(toLongitudeE7) - radians(fromLongitudeE7)
        let y = sin(longitudeDelta) * cos(toLatitude)
        let x = cos(fromLatitude) * sin(toLatitude)
            - sin(fromLatitude) * cos(toLatitude) * cos(longitudeDelta)
        return normalizeDegrees(atan2(y, x) * 180 / .pi)
    }

    public static func relativeArrowDegrees(targetBearing: Double, deviceHeading: Double) -> Double {
        normalizeDegrees(targetBearing - deviceHeading)
    }

    public static func normalizeDegrees(_ degrees: Double) -> Double {
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    private static func radians(_ coordinateE7: Int32) -> Double {
        Double(coordinateE7) / 10_000_000 * .pi / 180
    }
}
