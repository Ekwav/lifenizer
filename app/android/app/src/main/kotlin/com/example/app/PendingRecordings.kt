package com.lifenizer.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.*
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.Executors
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** Each flushed frame is independently authenticated, so process death loses only a partial frame. */
object PendingRecordings {
    val worker = Executors.newSingleThreadExecutor()
    fun scope(value: String): String {
        require(value.isNotBlank()) { "Choose a library before recording." }
        return MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    }
    private fun directory(context: Context, scope: String) = File(context.noBackupFilesDir, "recordings/$scope").apply { mkdirs() }
    fun captureKey(): SecretKey {
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
            val id = file.name.substringBefore('.')
            if (id == RecordingService.activeId) return@mapNotNull null
            if (file.extension == "capture") check(file.renameTo(file(context, scope, id)))
            val pending = file(context, scope, id)
            if (pending.length() < 8) return@mapNotNull null
            DataInputStream(FileInputStream(pending)).use { mapOf("id" to id, "startedAt" to it.readLong()) }
        }.sortedBy { it["startedAt"] as Long }
    }
    fun read(context: Context, scope: String, id: String): ByteArray {
        DataInputStream(FileInputStream(file(context, scope, id))).use { input ->
            return CaptureFrames.read(input, captureKey(), scope, id)
        }
    }
}
