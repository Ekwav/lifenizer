package com.lifenizer.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** Keeps the existing Flutter recorder alive; never opens a second microphone. */
class RecordingService : Service() {
    companion object {
        var onStarted: ((Exception?) -> Unit)? = null
        var onStopRequested: (() -> Unit)? = null
        private const val CHANNEL = "lifenizer_recording"
        private const val STOP = "com.lifenizer.STOP_RECORDING"
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            onStopRequested?.invoke() ?: stopSelf()
            return START_NOT_STICKY
        }
        try {
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(NotificationChannel(CHANNEL, "Microphone recording", NotificationManager.IMPORTANCE_LOW))
            }
            val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(Uri.parse("lifenizer://capture")), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val stop = PendingIntent.getService(this, 1, Intent(this, RecordingService::class.java).setAction(STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
            val notification = builder
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setContentTitle("Lifenizer is recording")
                .setContentText("Tap Stop to save the recording encrypted on this device.")
                .setContentIntent(open)
                .setOngoing(true)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(Notification.Action.Builder(android.R.drawable.ic_media_pause, "Stop and save", stop).build())
                .build()
            if (Build.VERSION.SDK_INT >= 29) startForeground(42, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            else startForeground(42, notification)
            if (wakeLock == null) {
                wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "lifenizer:recording")
                    .apply { acquire(31 * 60 * 1000L) }
            }
            val completion = onStarted
            onStarted = null
            completion?.invoke(null)
        } catch (error: Exception) {
            val completion = onStarted
            onStarted = null
            completion?.invoke(error)
            stopSelf()
        } finally {
            onStarted = null
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        onStopRequested?.invoke() ?: stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }
}
