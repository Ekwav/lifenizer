package com.lifenizer.app

import android.app.Activity
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Authentication is bound to each Cipher operation, never to cached app state. */
class DeviceCredentialProtection(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.lifenizer/device_protection")
    private var pending: MethodChannel.Result? = null
    private var cancellation: CancellationSignal? = null
    private var pendingInput: ByteArray? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "cancel" -> { cancel(); result.success(null) }
                "encrypt", "decrypt" -> protect(call.method == "encrypt", call.arguments, result)
                else -> result.notImplemented()
            }
        }
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.R)
    private fun protect(encrypt: Boolean, arguments: Any?, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.error("unsupported", "Device verification requires Android 11 or newer.", null)
            return
        }
        if (pending != null) {
            result.error("busy", "Device verification is already open.", null)
            return
        }
        var input: ByteArray? = null
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val key = key(encrypt)
            if (encrypt) {
                input = (arguments as String).toByteArray(Charsets.UTF_8)
                cipher.init(Cipher.ENCRYPT_MODE, key)
            } else {
                val payload = arguments as Map<*, *>
                val nonce = Base64.decode(payload["nonce"] as String, Base64.DEFAULT)
                input = Base64.decode(payload["cipherText"] as String, Base64.DEFAULT)
                require(nonce.size == 12 && input.size >= 16)
                cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, nonce))
            }
            val bytes = requireNotNull(input)
            val signal = CancellationSignal()
            pending = result
            pendingInput = bytes
            cancellation = signal
            val prompt = BiometricPrompt.Builder(activity)
                .setTitle("Unlock Lifenizer")
                .setSubtitle("Verify your fingerprint or device PIN")
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL)
                .build()
            prompt.authenticate(BiometricPrompt.CryptoObject(cipher), signal, activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(authentication: BiometricPrompt.AuthenticationResult) {
                        if (pending !== result) { bytes.fill(0); return }
                        try {
                            val authenticated = authentication.cryptoObject?.cipher
                                ?: throw IllegalStateException("Authentication did not authorize encryption.")
                            val output = authenticated.doFinal(bytes)
                            if (encrypt) {
                                complete(result, mapOf(
                                    "cipherText" to Base64.encodeToString(output, Base64.NO_WRAP),
                                    "nonce" to Base64.encodeToString(authenticated.iv, Base64.NO_WRAP),
                                ))
                            } else {
                                try { complete(result, String(output, Charsets.UTF_8)) }
                                finally { output.fill(0) }
                            }
                        } catch (_: Exception) {
                            fail(result, "Device verification could not unlock these credentials.")
                        } finally { bytes.fill(0) }
                    }

                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        bytes.fill(0)
                        fail(result, "Device verification was cancelled or unavailable.")
                    }
                })
        } catch (_: Exception) {
            input?.fill(0)
            if (pending === result) {
                fail(result, "Device verification is unavailable. Keep your existing device security settings.")
            } else {
                result.error("device_protection", "Device verification is unavailable.", null)
            }
        }
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.R)
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "lifenizer.device.protection.v1"
        if (!store.containsAlias(alias)) {
            check(create) { "The protected device key is unavailable." }
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setUserAuthenticationRequired(true)
                    .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
                    .build())
                generateKey()
            }
        }
        return store.getKey(alias, null) as SecretKey
    }

    private fun complete(result: MethodChannel.Result, value: Any) {
        if (pending !== result) return
        pending = null
        pendingInput?.fill(0)
        pendingInput = null
        cancellation = null
        result.success(value)
    }

    private fun fail(result: MethodChannel.Result, message: String) {
        if (pending !== result) return
        pending = null
        pendingInput?.fill(0)
        pendingInput = null
        cancellation = null
        result.error("device_protection", message, null)
    }

    private fun cancel() {
        val result = pending
        pending = null
        pendingInput?.fill(0)
        pendingInput = null
        cancellation?.cancel()
        cancellation = null
        result?.error("cancelled", "Device verification was cancelled.", null)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        cancel()
    }
}
