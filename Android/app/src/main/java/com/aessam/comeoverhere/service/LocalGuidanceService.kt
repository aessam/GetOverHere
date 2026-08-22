package com.aessam.comeoverhere.service

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import androidx.core.content.ContextCompat
import com.aessam.toursession.TargetGuidance
import com.aessam.toursession.TargetSnapshotPayload
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.math.roundToInt

enum class LocalGuidanceStatus { IDLE, NEEDS_PERMISSION, LOCATING, READY, UNAVAILABLE }

data class LocalDevicePosition(
    val latitude: Double,
    val longitude: Double,
    val accuracyMeters: Float,
    val sampledAtMilliseconds: Long,
)

data class LocalTargetGuidance(
    val distanceMeters: Double,
    val targetBearingDegrees: Double,
    val relativeArrowDegrees: Double?,
) {
    companion object {
        fun calculate(
            latitude: Double,
            longitude: Double,
            headingDegrees: Double?,
            target: TargetSnapshotPayload,
        ): LocalTargetGuidance {
            val latitudeE7 = (latitude * 10_000_000).roundToInt()
            val longitudeE7 = (longitude * 10_000_000).roundToInt()
            val bearing = TargetGuidance.initialBearingDegrees(
                latitudeE7,
                longitudeE7,
                target.latitudeE7,
                target.longitudeE7,
            )
            return LocalTargetGuidance(
                TargetGuidance.distanceMeters(
                    latitudeE7,
                    longitudeE7,
                    target.latitudeE7,
                    target.longitudeE7,
                ),
                bearing,
                headingDegrees?.let { TargetGuidance.relativeArrowDegrees(bearing, it) },
            )
        }
    }
}

class LocalGuidanceService(context: Context) : LocationListener, SensorEventListener {
    private val applicationContext = context.applicationContext
    private val locationManager = applicationContext.getSystemService(LocationManager::class.java)
    private val sensorManager = applicationContext.getSystemService(SensorManager::class.java)
    private val rotationVector = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)

    private val mutableStatus = MutableStateFlow(LocalGuidanceStatus.IDLE)
    val status: StateFlow<LocalGuidanceStatus> = mutableStatus.asStateFlow()

    private val mutablePosition = MutableStateFlow<LocalDevicePosition?>(null)
    val position: StateFlow<LocalDevicePosition?> = mutablePosition.asStateFlow()

    private val mutableHeadingDegrees = MutableStateFlow<Double?>(null)
    val headingDegrees: StateFlow<Double?> = mutableHeadingDegrees.asStateFlow()

    private val mutableMagneticHeadingDegrees = MutableStateFlow<Double?>(null)
    val magneticHeadingDegrees: StateFlow<Double?> = mutableMagneticHeadingDegrees.asStateFlow()

    private val mutableHeadingAccuracy = MutableStateFlow<Int?>(null)
    val headingAccuracy: StateFlow<Int?> = mutableHeadingAccuracy.asStateFlow()

    fun start() {
        if (
            ContextCompat.checkSelfPermission(applicationContext, Manifest.permission.ACCESS_FINE_LOCATION) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            mutableStatus.value = LocalGuidanceStatus.NEEDS_PERMISSION
            return
        }
        if (!locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            mutableStatus.value = LocalGuidanceStatus.UNAVAILABLE
            return
        }
        mutableStatus.value = LocalGuidanceStatus.LOCATING
        locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1_000, 2f, this)
        locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)?.let(::onLocationChanged)
        startHeadingOnly()
    }

    fun startHeadingOnly() {
        val sensor = rotationVector
        if (sensor == null || !sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_UI)) {
            mutableHeadingDegrees.value = null
            mutableMagneticHeadingDegrees.value = null
            mutableHeadingAccuracy.value = SensorManager.SENSOR_STATUS_UNRELIABLE
        }
    }

    fun stop() {
        locationManager.removeUpdates(this)
        sensorManager.unregisterListener(this)
        mutablePosition.value = null
        mutableHeadingDegrees.value = null
        mutableMagneticHeadingDegrees.value = null
        mutableHeadingAccuracy.value = null
        mutableStatus.value = LocalGuidanceStatus.IDLE
    }

    fun guidance(target: TargetSnapshotPayload): LocalTargetGuidance? {
        val local = mutablePosition.value ?: return null
        return LocalTargetGuidance.calculate(
            local.latitude,
            local.longitude,
            mutableHeadingDegrees.value,
            target,
        )
    }

    override fun onLocationChanged(location: Location) {
        mutablePosition.value = LocalDevicePosition(
            location.latitude,
            location.longitude,
            location.accuracy,
            location.time,
        )
        mutableStatus.value = LocalGuidanceStatus.READY
    }

    override fun onProviderDisabled(provider: String) {
        if (provider == LocationManager.GPS_PROVIDER) mutableStatus.value = LocalGuidanceStatus.UNAVAILABLE
    }

    override fun onProviderEnabled(provider: String) {
        if (provider == LocationManager.GPS_PROVIDER) start()
    }

    @Deprecated("Legacy callback required below API 31")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit

    override fun onSensorChanged(event: SensorEvent) {
        if (mutableHeadingAccuracy.value == SensorManager.SENSOR_STATUS_UNRELIABLE) return
        val rotationMatrix = FloatArray(9)
        SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
        val orientation = FloatArray(3)
        SensorManager.getOrientation(rotationMatrix, orientation)
        var magneticHeading = Math.toDegrees(orientation[0].toDouble())
        if (magneticHeading < 0) magneticHeading += 360
        mutableMagneticHeadingDegrees.value = magneticHeading
        val local = mutablePosition.value
        val declination = if (local == null) 0f else GeomagneticField(
            local.latitude.toFloat(),
            local.longitude.toFloat(),
            0f,
            local.sampledAtMilliseconds,
        ).declination
        mutableHeadingDegrees.value = (magneticHeading + declination + 360) % 360
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        if (sensor?.type != Sensor.TYPE_ROTATION_VECTOR) return
        mutableHeadingAccuracy.value = accuracy
        if (accuracy == SensorManager.SENSOR_STATUS_UNRELIABLE) {
            mutableHeadingDegrees.value = null
            mutableMagneticHeadingDegrees.value = null
        }
    }
}
