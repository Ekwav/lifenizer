package com.lifenizer.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.*
import android.os.*
import java.util.concurrent.Executors

/** A bounded, approximate, one-shot position. Never requests permission or blocks the microphone. */
object RecordingLocation {
    private val main = Handler(Looper.getMainLooper())
    private val geocoding = Executors.newSingleThreadExecutor()
    fun permitted(context: Context) = context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    @Suppress("DEPRECATION")
    fun current(context: Context, complete: (Map<String, Any>?) -> Unit) {
        if (!permitted(context)) { complete(null); return }
        val manager = context.getSystemService(LocationManager::class.java)
        var done = false
        var located = false
        var coordinates: Map<String, Any>? = null
        val cancellation = CancellationSignal()
        var listener: LocationListener? = null
        fun stopUpdates() {
            cancellation.cancel()
            listener?.let { runCatching { manager.removeUpdates(it) } }
        }
        lateinit var timeout: Runnable
        fun finish(value: Map<String, Any>?) {
            if (done) return
            done = true
            main.removeCallbacks(timeout)
            stopUpdates()
            complete(value)
        }
        timeout = Runnable { finish(coordinates) }
        main.postDelayed(timeout, 5000)
        fun location(value: Location?) {
            if (done || located) return
            located = true
            stopUpdates()
            if (value == null) { finish(null); return }
            val position = mapOf<String, Any>("latitude" to value.latitude, "longitude" to value.longitude)
            coordinates = position
            main.removeCallbacks(timeout)
            main.postDelayed(timeout, 2000)
            if (!Geocoder.isPresent()) { finish(position); return }
            fun address(addresses: List<Address>?) {
                val place = addresses?.firstOrNull()
                val town = place?.locality ?: place?.subAdminArea ?: ""
                val street = listOfNotNull(place?.thoroughfare, place?.subThoroughfare).joinToString(" ")
                // featureName can be a house number; never claim that it identifies a venue.
                main.post { finish(position + mapOf("town" to town, "address" to street)) }
            }
            try {
                val geocoder = Geocoder(context.applicationContext)
                if (Build.VERSION.SDK_INT >= 33) {
                    geocoder.getFromLocation(value.latitude, value.longitude, 1, object : Geocoder.GeocodeListener {
                        override fun onGeocode(addresses: MutableList<Address>) = address(addresses)
                        override fun onError(errorMessage: String?) { main.post { finish(position) } }
                    })
                } else geocoding.execute {
                    try { address(geocoder.getFromLocation(value.latitude, value.longitude, 1)) }
                    catch (_: Exception) { main.post { finish(position) } }
                }
            } catch (_: Exception) { finish(position) }
        }
        try {
            val providers = manager.getProviders(true)
            val provider = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)
                .firstOrNull { it in providers }
            if (provider == null) { finish(null); return }
            if (Build.VERSION.SDK_INT >= 30) {
                manager.getCurrentLocation(provider, cancellation, context.mainExecutor) { location(it) }
            } else {
                val recent = manager.getLastKnownLocation(provider)?.takeIf {
                    SystemClock.elapsedRealtimeNanos() - it.elapsedRealtimeNanos <= 30_000_000_000L
                }
                if (recent != null) { location(recent); return }
                listener = object : LocationListener {
                    override fun onLocationChanged(value: Location) = location(value)
                    override fun onProviderDisabled(provider: String) { finish(null) }
                    override fun onProviderEnabled(provider: String) {}
                    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                }
                manager.requestSingleUpdate(provider, listener!!, Looper.getMainLooper())
            }
        } catch (_: Exception) { finish(null) }
    }
}
