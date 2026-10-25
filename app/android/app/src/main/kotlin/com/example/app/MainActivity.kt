package com.lifenizer.app

import android.Manifest
import android.content.pm.PackageManager
import android.app.SearchManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var recordingPermission: MethodChannel.Result? = null
    private var recordingPermissionGranted = false
    private var imagesPermission: MethodChannel.Result? = null
    private var locationPermission: MethodChannel.Result? = null
    private var resumed = false
    private lateinit var actions: MethodChannel
    private lateinit var shares: MethodChannel
    private var actionReady = false
    private var shareReady = false
    private var pendingAction: Map<String, String?>? = null
    private val pendingShares = mutableListOf<Map<String, String?>>()
    private val sharedUris = mutableSetOf<String>()
    private val reader = Executors.newSingleThreadExecutor()
    private var deviceProtection: DeviceCredentialProtection? = null
    private var backupFiles: BackupFiles? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        deviceProtection?.dispose()
        deviceProtection = DeviceCredentialProtection(this, flutterEngine.dartExecutor.binaryMessenger)
        backupFiles?.dispose()
        backupFiles = BackupFiles(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lifenizer/recording_location").setMethodCallHandler { call, result ->
            when (call.method) {
                "permission" -> {
                    if (RecordingLocation.permitted(this)) result.success(true)
                    else if (locationPermission != null || !resumed) result.success(false)
                    else {
                        locationPermission = result
                        requestPermissions(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION), 9044)
                    }
                }
                "current" -> RecordingLocation.current(this) { result.success(it) }
                else -> result.notImplemented()
            }
        }
        actions = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lifenizer/quick_actions")
        shares = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lifenizer/shares")
        actions.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialAction" -> {
                    actionReady = true
                    result.success(pendingAction)
                    pendingAction = null
                }
                else -> result.notImplemented()
            }
        }
        shares.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialShares" -> {
                    shareReady = true
                    result.success(pendingShares.toList())
                    pendingShares.clear()
                }
                "readSharedFile" -> {
                    val value = call.arguments as? String
                    if (value == null || value !in sharedUris) {
                        result.error("share", "This file was not shared with Lifenizer.", null)
                    } else reader.execute {
                        try {
                            val bytes = contentResolver.openInputStream(Uri.parse(value))!!.use { input ->
                                val buffer = java.io.ByteArrayOutputStream()
                                val chunk = ByteArray(65536)
                                var size: Int
                                while (input.read(chunk).also { size = it } != -1) {
                                    check(buffer.size() + size <= 64 * 1024 * 1024) { "Shared file exceeds 64 MiB; import it in the app." }
                                    buffer.write(chunk, 0, size)
                                }
                                buffer.toByteArray()
                            }
                            runOnUiThread { result.success(bytes) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("share", error.message, null) }
                        }
                    }
                }
                "releaseSharedFile" -> {
                    sharedUris.remove(call.arguments as? String)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        val recording = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lifenizer/recording")
        RecordingService.onChanged = { recording.invokeMethod("changed", null) }
        recording.setMethodCallHandler { call, result ->
            when (call.method) {
                "permission" -> {
                    val permissions = mutableListOf(Manifest.permission.RECORD_AUDIO)
                    if (Build.VERSION.SDK_INT >= 33) permissions.add(Manifest.permission.POST_NOTIFICATIONS)
                    val missing = permissions.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
                    if (recordingPermission != null) result.error("recording", "A microphone permission request is already open.", null)
                    else if (missing.isNotEmpty()) {
                        recordingPermission = result
                        requestPermissions(missing.toTypedArray(), 9042)
                    } else if (!resumed) {
                        recordingPermission = result
                        recordingPermissionGranted = true
                    } else result.success(true)
                }
                "start" -> {
                    if (!resumed) result.error("recording", "Start recording while Lifenizer is open.", null)
                    else try {
                        check(checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) { "Microphone permission is required." }
                        val scope = PendingRecordings.scope(requireNotNull(call.argument<String>("scope")))
                        RecordingService.onStarted = { error ->
                            if (error == null) result.success(RecordingService.status())
                            else result.error("recording", error.message, null)
                        }
                        val service = Intent(this, RecordingService::class.java).putExtra("scope", scope)
                            .putExtra("captureLocation", call.argument<Boolean>("captureLocation") == true)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
                    } catch (error: Exception) {
                        RecordingService.onStarted = null
                        result.error("recording", error.message, null)
                    }
                }
                "status" -> result.success(RecordingService.status())
                "stop", "pending", "read", "ack" -> {
                    if (call.method != "stop" && RecordingService.activeId != null) {
                        if (call.method == "pending") result.success(emptyList<Any>())
                        else result.error("recording", "Finish recording before importing captures.", null)
                        return@setMethodCallHandler
                    }
                    if (call.method == "stop") RecordingService.requestStop()
                    PendingRecordings.worker.execute {
                        try {
                            val value = if (call.method == "stop") RecordingService.status() else {
                                val scope = PendingRecordings.scope(requireNotNull(call.argument<String>("scope")))
                                when (call.method) {
                                    "pending" -> PendingRecordings.pending(this, scope)
                                    "read" -> PendingRecordings.read(this, scope, requireNotNull(call.argument<String>("id")))
                                    else -> {
                                        PendingRecordings.acknowledge(this, scope, requireNotNull(call.argument<String>("id")))
                                        null
                                    }
                                }
                            }
                            runOnUiThread { result.success(value) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("recording", error.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        val media = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lifenizer/media")
        media.setMethodCallHandler { call, result ->
            when (call.method) {
                "cameraFolders" -> {
                    @Suppress("DEPRECATION")
                    val dcim = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM)
                    val folders = listOf(java.io.File(dcim, "Camera"), java.io.File(dcim, "OpenCamera"))
                        .filter { it.isDirectory }
                        .map { it.absolutePath }
                    result.success(folders)
                }
                "hasImagesPermission" -> result.success(
                    checkSelfPermission(imagesPermissionName()) == PackageManager.PERMISSION_GRANTED
                )
                "requestImagesPermission" -> {
                    if (checkSelfPermission(imagesPermissionName()) == PackageManager.PERMISSION_GRANTED) {
                        result.success(true)
                    } else if (imagesPermission != null) {
                        result.error("media", "A photo permission request is already open.", null)
                    } else {
                        imagesPermission = result
                        requestPermissions(arrayOf(imagesPermissionName()), 9043)
                    }
                }
                else -> result.notImplemented()
            }
        }
        handleIntent(intent)
    }

    private fun imagesPermissionName() =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES
        else Manifest.permission.READ_EXTERNAL_STORAGE

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    @Suppress("DEPRECATION")
    private fun handleIntent(intent: Intent) {
        val action = when (intent.action) {
            Intent.ACTION_SEARCH -> mapOf("action" to "search", "query" to intent.getStringExtra(SearchManager.QUERY).orEmpty())
            Intent.ACTION_PROCESS_TEXT -> mapOf("action" to "search", "query" to intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString().orEmpty())
            Intent.ACTION_VIEW -> intent.data?.takeIf { it.scheme == "lifenizer" && it.host in listOf("search", "capture", "record", "imports", "connect", "connect-extension") }?.let {
                mapOf("action" to it.host, "uri" to it.toString(), "query" to it.getQueryParameter("q").orEmpty(), "conversationId" to it.getQueryParameter("conversation"))
            }
            else -> null
        }
        if (action != null) {
            if (actionReady) actions.invokeMethod("action", action) else pendingAction = action
            return
        }
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return
        val streams = if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        } else listOfNotNull(if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        val uris = (streams + (0 until (intent.clipData?.itemCount ?: 0)).mapNotNull {
            intent.clipData?.getItemAt(it)?.uri
        }).filter { it.scheme == "content" }.distinct()
        val items = uris.map { uri ->
            sharedUris.add(uri.toString())
            var name = "Shared file"
            var mimeType = intent.type
            try {
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0) ?: name
                }
                mimeType = contentResolver.getType(uri) ?: mimeType
            } catch (_: SecurityException) {
                // Surface an unreadable provider grant through the Dart read error.
            }
            mapOf("uri" to uri.toString(), "fileName" to name, "mimeType" to mimeType)
        }.toMutableList()
        if (uris.isEmpty()) intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.let {
            items.add(mapOf("text" to it, "mimeType" to intent.type))
        }
        if (shareReady) shares.invokeMethod("shares", items) else pendingShares.addAll(items)
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        if (recordingPermissionGranted) {
            recordingPermissionGranted = false
            recordingPermission?.success(true)
            recordingPermission = null
        }
    }

    override fun onPause() {
        resumed = false
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 9044) {
            locationPermission?.success(RecordingLocation.permitted(this))
            locationPermission = null
        }
        if (requestCode == 9043) {
            val result = imagesPermission
            imagesPermission = null
            result?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        }
        if (requestCode == 9042) {
            if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED } && !resumed) {
                recordingPermissionGranted = true
            } else {
                val result = recordingPermission
                recordingPermission = null
                if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) result?.success(true)
                else result?.error("recording", "Allow microphone and notifications to record with a visible Stop action.", null)
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (backupFiles?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        locationPermission?.success(false)
        locationPermission = null
        backupFiles?.dispose()
        backupFiles = null
        imagesPermission?.error("media", "Photo permission request was interrupted.", null)
        imagesPermission = null
        recordingPermission?.error("recording", "Recording permission request was interrupted.", null)
        recordingPermission = null
        RecordingService.onStarted?.invoke(IllegalStateException("Recording was interrupted."))
        RecordingService.onStarted = null
        RecordingService.onChanged = null
        deviceProtection?.dispose()
        deviceProtection = null
        reader.shutdown()
        super.onDestroy()
    }
}
