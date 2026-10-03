package com.lifenizer.app

import android.app.SearchManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private lateinit var actions: MethodChannel
    private lateinit var shares: MethodChannel
    private var actionReady = false
    private var shareReady = false
    private var pendingAction: Map<String, String?>? = null
    private val pendingShares = mutableListOf<Map<String, String?>>()
    private val sharedUris = mutableSetOf<String>()
    private val reader = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
        handleIntent(intent)
    }

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
            Intent.ACTION_VIEW -> intent.data?.takeIf { it.scheme == "lifenizer" && it.host in listOf("search", "capture", "imports") }?.let {
                mapOf("action" to it.host, "query" to it.getQueryParameter("q").orEmpty(), "conversationId" to it.getQueryParameter("conversation"))
            }
            else -> null
        }
        if (action != null) {
            if (actionReady) actions.invokeMethod("action", action) else pendingAction = action
            return
        }
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return
        val uris = if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        } else listOfNotNull(if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        val items = uris.filter { it.scheme == "content" }.map { uri ->
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

    override fun onDestroy() {
        reader.shutdown()
        super.onDestroy()
    }
}
