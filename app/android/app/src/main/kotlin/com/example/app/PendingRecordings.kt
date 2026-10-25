package com.lifenizer.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONObject
import java.io.*
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.Executors
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** Each flushed frame is independently authenticated, so process death loses only a partial frame. */
object PendingRecordings {
    val worker = Executors.newSingleThreadExecutor()
    val metadataWorker = Executors.newSingleThreadExecutor()
    fun scope(value: String): String {
        require(value.isNotBlank()) { "Choose a library before recording." }
        return MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    }
    private fun directory(context: Context, scope: String) = File(context.noBackupFilesDir, "recordings/$scope").apply { mkdirs() }
    @Synchronized fun captureKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("lifenizer.capture", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("lifenizer.capture", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun file(context: Context, scope: String, id: String, active: Boolean = false): File {
        require(id.matches(Regex("[0-9a-f-]{36}")))
        return File(directory(context, scope), "$id.${if (active) "capture" else "pending"}")
    }
    fun pending(context: Context, scope: String): List<Map<String, Any>> {
        val files = directory(context, scope).listFiles().orEmpty()
        return files.mapNotNull { file ->
            if (file.extension != "capture" && file.extension != "pending") return@mapNotNull null
            val id = file.name.substringBefore('.')
            if (id == RecordingService.activeId) return@mapNotNull null
            if (file.extension == "capture") check(file.renameTo(file(context, scope, id)))
            val pending = file(context, scope, id)
            if (pending.length() < 8) return@mapNotNull null
            DataInputStream(FileInputStream(pending)).use {
                val value = mutableMapOf<String, Any>("id" to id, "startedAt" to it.readLong())
                location(context, scope, id)?.let { value["location"] = it }
                value
            }
        }.sortedBy { it["startedAt"] as Long }
    }
    private fun locationFile(context: Context, scope: String, id: String) =
        AtomicFile(File(file(context, scope, id).parentFile, "$id.location"))

    @Synchronized fun saveLocation(context: Context, scope: String, id: String, location: Map<String, Any>) {
        // A late geocoder callback must not resurrect an acknowledged capture.
        if (!file(context, scope, id, true).exists() && !file(context, scope, id).exists()) return
        val target = locationFile(context, scope, id)
        val output = target.startWrite()
        try {
            val bytes = JSONObject(location).toString().toByteArray(Charsets.UTF_8)
            val stream = DataOutputStream(output)
            stream.writeLong(0)
            CaptureFrames.append(stream, captureKey(), "$scope/location", id, 0, 0, bytes, bytes.size)
            target.finishWrite(output)
        } catch (error: Exception) { target.failWrite(output); throw error }
    }
    private fun location(context: Context, scope: String, id: String): Map<String, Any>? = try {
        DataInputStream(locationFile(context, scope, id).openRead()).use {
            val value = JSONObject(String(CaptureFrames.read(it, captureKey(), "$scope/location", id), Charsets.UTF_8))
            value.keys().asSequence().associateWith { key -> value.get(key) }
        }
    } catch (_: Exception) { null }

    @Synchronized fun acknowledge(context: Context, scope: String, id: String) {
        val target = file(context, scope, id)
        check(!target.exists() || target.delete()) { "Could not remove the imported capture." }
        locationFile(context, scope, id).delete()
    }
    fun read(context: Context, scope: String, id: String): ByteArray {
        DataInputStream(FileInputStream(file(context, scope, id))).use { input ->
            return CaptureFrames.read(input, captureKey(), scope, id)
        }
    }
}
