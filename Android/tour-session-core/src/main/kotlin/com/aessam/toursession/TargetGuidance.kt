package com.aessam.toursession

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

object TargetGuidance {
    private const val EARTH_RADIUS_METERS = 6_371_000.0

    fun distanceMeters(
        fromLatitudeE7: Int,
        fromLongitudeE7: Int,
        toLatitudeE7: Int,
        toLongitudeE7: Int,
    ): Double {
        val fromLatitude = radians(fromLatitudeE7)
        val toLatitude = radians(toLatitudeE7)
        val latitudeDelta = toLatitude - fromLatitude
        val longitudeDelta = radians(toLongitudeE7) - radians(fromLongitudeE7)
        val a = (
            sin(latitudeDelta / 2).pow(2) +
                cos(fromLatitude) * cos(toLatitude) * sin(longitudeDelta / 2).pow(2)
            ).coerceIn(0.0, 1.0)
        return EARTH_RADIUS_METERS * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    fun initialBearingDegrees(
        fromLatitudeE7: Int,
        fromLongitudeE7: Int,
        toLatitudeE7: Int,
        toLongitudeE7: Int,
    ): Double {
        val fromLatitude = radians(fromLatitudeE7)
        val toLatitude = radians(toLatitudeE7)
        val longitudeDelta = radians(toLongitudeE7) - radians(fromLongitudeE7)
        val y = sin(longitudeDelta) * cos(toLatitude)
        val x = cos(fromLatitude) * sin(toLatitude) -
            sin(fromLatitude) * cos(toLatitude) * cos(longitudeDelta)
        return normalizeDegrees(Math.toDegrees(atan2(y, x)))
    }

    fun relativeArrowDegrees(targetBearing: Double, deviceHeading: Double): Double =
        normalizeDegrees(targetBearing - deviceHeading)

    fun normalizeDegrees(degrees: Double): Double {
        val remainder = degrees % 360
        return if (remainder < 0) remainder + 360 else remainder
    }

    private fun radians(coordinateE7: Int): Double = Math.toRadians(coordinateE7 / 10_000_000.0)
}
