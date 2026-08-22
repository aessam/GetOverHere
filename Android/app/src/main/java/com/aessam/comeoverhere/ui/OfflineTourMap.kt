package com.aessam.comeoverhere.ui

import android.os.Bundle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.aessam.comeoverhere.service.LocalDevicePosition
import com.aessam.comeoverhere.service.OfflineMapConfiguration
import com.aessam.toursession.TargetSnapshotPayload
import org.maplibre.android.annotations.MarkerOptions
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style

@Composable
fun OfflineTourMap(
    configuration: OfflineMapConfiguration,
    target: TargetSnapshotPayload?,
    localPosition: LocalDevicePosition?,
    allowsTargetPlacement: Boolean,
    onTargetPlaced: (latitude: Double, longitude: Double) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val mapView = remember(configuration.styleJSON) {
        MapView(context).also { it.onCreate(Bundle()) }
    }
    var map by remember(configuration.styleJSON) { mutableStateOf<MapLibreMap?>(null) }
    var focusedTargetVersion by remember(configuration.styleJSON) { mutableStateOf<Long?>(null) }
    var didFocusLocal by remember(configuration.styleJSON) { mutableStateOf(false) }

    DisposableEffect(mapView, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> mapView.onStart()
                Lifecycle.Event.ON_RESUME -> mapView.onResume()
                Lifecycle.Event.ON_PAUSE -> mapView.onPause()
                Lifecycle.Event.ON_STOP -> mapView.onStop()
                Lifecycle.Event.ON_DESTROY -> mapView.onDestroy()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            mapView.onPause()
            mapView.onStop()
            mapView.onDestroy()
        }
    }

    AndroidView(
        factory = {
            mapView.apply {
                getMapAsync { readyMap ->
                    readyMap.setStyle(Style.Builder().fromJson(configuration.styleJSON)) {
                        map = readyMap
                        if (allowsTargetPlacement) {
                            readyMap.addOnMapLongClickListener { coordinate ->
                                onTargetPlaced(coordinate.latitude, coordinate.longitude)
                                true
                            }
                        }
                    }
                }
            }
        },
        update = {
            map?.let { readyMap ->
                readyMap.clear()
                localPosition?.let { position ->
                    readyMap.addMarker(
                        MarkerOptions()
                            .position(LatLng(position.latitude, position.longitude))
                            .title("You"),
                    )
                }
                if (target?.isVisible == true) {
                    readyMap.addMarker(
                        MarkerOptions()
                            .position(
                                LatLng(
                                    target.latitudeE7 / 10_000_000.0,
                                    target.longitudeE7 / 10_000_000.0,
                                ),
                            )
                            .title(target.label.ifBlank { "Guide target" }),
                    )
                }
                val focus = when {
                    target?.isVisible == true && focusedTargetVersion != target.stateVersion -> LatLng(
                        target.latitudeE7 / 10_000_000.0,
                        target.longitudeE7 / 10_000_000.0,
                    )
                    target?.isVisible != true && localPosition != null && !didFocusLocal ->
                        LatLng(localPosition.latitude, localPosition.longitude)
                    else -> null
                }
                focus?.let {
                    readyMap.moveCamera(CameraUpdateFactory.newLatLngZoom(it, 16.0))
                    if (target?.isVisible == true) focusedTargetVersion = target.stateVersion
                    else didFocusLocal = true
                }
            }
        },
        modifier = modifier,
    )
}
