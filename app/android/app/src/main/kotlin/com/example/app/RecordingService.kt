package com.lifenizer.app

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.*
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.DataOutputStream
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Owns the microphone and encrypted capture independently of any Activity or Flutter engine. */
class RecordingService : Service() {
    companion object {
        var onChanged: (() -> Unit)? = null
        var onStarted: ((Exception?) -> Unit)? = null
        @Volatile var activeId: String? = null
        @Volatile private var running = false
        @Volatile private var startedAt = 0L
        @Volatile private var activeScope: String? = null
        @Volatile private var failure: String? = null
        private const val CHANNEL = "lifenizer_recording"
        private const val STOP = "com.lifenizer.STOP_RECORDING"
        fun status(): Map<String, Any?> = mapOf("recording" to running, "startedAt" to startedAt, "scope" to activeScope, "error" to failure)
        fun requestStop() { running = false }
    }
    private var wakeLock: PowerManager.WakeLock? = null
    private var latestStartId = 0
    private val main = Handler(Looper.getMainLooper())
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        latestStartId = startId
        if (intent?.action == STOP) {
            requestStop()
            if (activeId == null) stopSelf(startId)
            return START_NOT_STICKY
        }
        if (activeId != null) {
            onStarted?.invoke(IllegalStateException("A recording is already active."))
            onStarted = null
            return START_NOT_STICKY
        }
        try {
            val scope = requireNotNull(intent?.getStringExtra("scope"))
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
            var captureLocation = intent?.getBooleanExtra("captureLocation", false) == true && RecordingLocation.permitted(this)
            if (Build.VERSION.SDK_INT >= 29) {
                val microphone = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                try {
                    startForeground(42, notification, microphone or if (captureLocation) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0)
                } catch (_: SecurityException) {
                    // Optional location access must never prevent microphone recording.
                    captureLocation = false
                    startForeground(42, notification, microphone)
                }
            } else startForeground(42, notification)
            if (wakeLock == null) {
                wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "lifenizer:recording")
                    .apply { acquire(31 * 60 * 1000L) }
            }
            activeScope = scope
            startedAt = System.currentTimeMillis()
            activeId = UUID.randomUUID().toString()
            failure = null
            running = true
            val id = activeId!!
            val completion = onStarted
            onStarted = null
            val locationReady = CountDownLatch(if (captureLocation) 1 else 0)
            val captureStarted: (Exception?) -> Unit = { error ->
                completion?.invoke(error)
                // The acknowledgement runs only after the capture file is durable and the mic started.
                if (error == null && captureLocation) RecordingLocation.current(this) { location ->
                    if (location != null) PendingRecordings.metadataWorker.execute {
                        try { PendingRecordings.saveLocation(this, scope, id, location) }
                        catch (_: Exception) { }
                        finally { locationReady.countDown() }
                    } else locationReady.countDown()
                    if (Build.VERSION.SDK_INT >= 29 && activeId == id) {
                        runCatching { startForeground(42, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE) }
                    }
                }
            }
            PendingRecordings.worker.execute { capture(scope, id, startedAt, captureStarted, locationReady) }
        } catch (error: Exception) {
            onStarted?.invoke(error)
            onStarted = null
            stopSelf()
        }
        return START_NOT_STICKY
    }
    private fun capture(scope: String, id: String, timestamp: Long, completion: ((Exception?) -> Unit)?, locationReady: CountDownLatch) {
        var starting = true
        var recorder: AudioRecord? = null
        val target = PendingRecordings.file(this, scope, id, true)
        try {
            val key = PendingRecordings.captureKey()
            val minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(minimum > 0) { "Microphone format is unavailable." }
            recorder = AudioRecord(MediaRecorder.AudioSource.MIC, 16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum, 32768))
            check(recorder.state == AudioRecord.STATE_INITIALIZED) { "Could not open the microphone." }
            FileOutputStream(target).use { file ->
                val output = DataOutputStream(file)
                output.writeLong(timestamp)
                output.flush()
                file.fd.sync()
                recorder.startRecording()
                check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "Could not start the microphone." }
                main.post { completion?.invoke(null) }
                starting = false
                val buffer = ByteArray(32768)
                var size = 0
                var index = 0
                while (running && size < 16000 * 2 * 60 * 30) {
                    val count = recorder.read(buffer, 0, minOf(buffer.size, 16000 * 2 * 60 * 30 - size))
                    check(count >= 0) { "Microphone interrupted ($count)." }
                    if (count == 0) continue
                    CaptureFrames.append(output, key, scope, id, index++, timestamp, buffer, count)
                    file.fd.sync()
                    size += count
                }
            }
        } catch (error: Exception) {
            failure = error.message
            if (starting) main.post { completion?.invoke(error) }
        } finally {
            try { recorder?.stop() } catch (_: Exception) { }
            recorder?.release()
            // Publish a short capture only after its bounded snapshot finishes; the mic is already off.
            if (!starting) try { locationReady.await(7, TimeUnit.SECONDS) }
            catch (_: InterruptedException) { Thread.currentThread().interrupt() }
            if (target.exists()) target.renameTo(PendingRecordings.file(this, scope, id))
            running = false
            activeId = null
            main.post {
                onChanged?.invoke()
                // Include notification Stop, while protecting any newer start
                // queued by Android but not yet delivered to onStartCommand.
                if (activeId == null) stopSelf(latestStartId)
            }
        }
    }
    // Removing the Activity/task must not stop an explicitly started microphone service.
    override fun onDestroy() {
        requestStop()
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
