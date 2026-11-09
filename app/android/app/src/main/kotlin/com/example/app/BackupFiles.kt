package com.lifenizer.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executors

/** SAF streams stay in the provider: no whole-file buffers or local copies. */
class BackupFiles(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.lifenizer/backup_files")
    private val worker = Executors.newSingleThreadExecutor()
    private var picker: MethodChannel.Result? = null
    private var tree: Uri? = null
    private var output: OutputStream? = null
    private val created = mutableListOf<Uri>()
    private val selected = mutableSetOf<String>()
    private val inputs = mutableMapOf<String, InputStream>()
    private val resolver get() = activity.contentResolver

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickTarget", "pickParts" -> {
                    if (picker != null) result.error("backup", "A backup picker is already open.", null)
                    else {
                        picker = result
                        try {
                            val target = call.method == "pickTarget"
                            val intent = Intent(if (target) Intent.ACTION_OPEN_DOCUMENT_TREE else Intent.ACTION_OPEN_DOCUMENT)
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            if (target) intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                            else intent.setType("*/*").addCategory(Intent.CATEGORY_OPENABLE)
                                .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                            @Suppress("DEPRECATION")
                            activity.startActivityForResult(intent, if (target) TARGET_REQUEST else PARTS_REQUEST)
                        } catch (error: Exception) {
                            picker = null
                            result.error("backup", error.message, null)
                        }
                    }
                }
                else -> worker.execute {
                    try {
                        val value: Any? = when (call.method) {
                            "openPart" -> {
                                check(output == null) { "A backup file is already open." }
                                val name = call.arguments as String
                                require(name.isNotEmpty() && name !in listOf(".", "..") && !name.contains('/') && !name.contains('\\'))
                                val folder = checkNotNull(tree) { "Choose a backup folder first." }
                                val parent = DocumentsContract.buildDocumentUriUsingTree(folder, DocumentsContract.getTreeDocumentId(folder))
                                val uri = checkNotNull(DocumentsContract.createDocument(resolver, parent, "application/octet-stream", name))
                                created.add(uri)
                                check(displayName(uri) == name) { "A backup file with this name already exists, or the provider renamed it. Choose another folder." }
                                output = checkNotNull(resolver.openOutputStream(uri, "w"))
                                null
                            }
                            "write" -> {
                                val bytes = call.arguments as ByteArray
                                require(bytes.size <= CHUNK_SIZE) { "Backup chunk is too large." }
                                checkNotNull(output) { "No backup file is open." }.write(bytes)
                                null
                            }
                            "closePart" -> { closeOutput(); null }
                            "abort" -> { abort(); null }
                            "openRead" -> {
                                val uri = call.arguments as String
                                check(uri in selected) { "Select this backup file first." }
                                check(uri !in inputs) { "This backup file is already open." }
                                inputs[uri] = checkNotNull(resolver.openInputStream(Uri.parse(uri)))
                                null
                            }
                            "read" -> {
                                val buffer = ByteArray(CHUNK_SIZE)
                                val count = checkNotNull(inputs[call.arguments as String]).read(buffer)
                                if (count < 0) null else buffer.copyOf(count)
                            }
                            "closeRead" -> { inputs.remove(call.arguments as String)?.close(); null }
                            else -> throw IllegalArgumentException("Unknown backup operation.")
                        }
                        activity.runOnUiThread { result.success(value) }
                    } catch (error: Exception) {
                        activity.runOnUiThread { result.error("backup", error.message, null) }
                    }
                }
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != TARGET_REQUEST && requestCode != PARTS_REQUEST) return false
        val result = picker ?: return true
        picker = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return true
        }
        worker.execute {
            try {
                val value: Any? = if (requestCode == TARGET_REQUEST) {
                    check(output == null) { "A backup is already being written." }
                    val folder = checkNotNull(data?.data) { "The provider returned no folder." }
                    tree = folder
                    created.clear()
                    val document = DocumentsContract.buildDocumentUriUsingTree(folder, DocumentsContract.getTreeDocumentId(folder))
                    displayName(document)
                } else {
                    check(inputs.isEmpty()) { "A backup is already being read." }
                    selected.clear()
                    val uris = (listOfNotNull(data?.data) + (0 until (data?.clipData?.itemCount ?: 0)).mapNotNull {
                        data?.clipData?.getItemAt(it)?.uri
                    }).distinct()
                    uris.map { uri ->
                        selected.add(uri.toString())
                        mapOf("uri" to uri.toString(), "name" to displayName(uri))
                    }
                }
                activity.runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                activity.runOnUiThread { result.error("backup", error.message, null) }
            }
        }
        return true
    }

    private fun displayName(uri: Uri): String =
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            check(it.moveToFirst()) { "The provider returned no filename." }
            it.getString(0)
        } ?: throw IllegalStateException("The provider returned no filename.")

    private fun closeOutput() {
        val stream = output
        output = null
        stream?.close()
    }

    private fun abort() {
        try {
            closeOutput()
        } finally {
            var failure: Exception? = null
            for (uri in created.toList()) {
                try {
                    check(DocumentsContract.deleteDocument(resolver, uri)) { "Could not remove an incomplete backup file." }
                    created.remove(uri)
                } catch (error: Exception) { failure = error }
            }
            failure?.let { throw it }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        picker?.error("backup", "The backup picker was interrupted. Please try again.", null)
        picker = null
        worker.execute {
            try {
                if (output != null) abort()
            } finally {
                for (input in inputs.values) runCatching { input.close() }
                inputs.clear()
            }
        }
        worker.shutdown()
    }

    companion object {
        private const val TARGET_REQUEST = 9044
        private const val PARTS_REQUEST = 9045
        private const val CHUNK_SIZE = 256 * 1024
    }
}
