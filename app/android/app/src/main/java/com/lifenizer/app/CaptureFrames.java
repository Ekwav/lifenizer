package com.lifenizer.app;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import javax.crypto.Cipher;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Independently authenticated PCM frames; incomplete trailing writes can be recovered. */
final class CaptureFrames {
    private static byte[] aad(String scope, String id, long timestamp, int index) {
        return (scope + "/" + id + "/" + timestamp + "/" + index).getBytes(StandardCharsets.UTF_8);
    }
    static void append(DataOutputStream output, SecretKey key, String scope, String id,
                       int index, long timestamp, byte[] bytes, int size) throws GeneralSecurityException, IOException {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key);
        cipher.updateAAD(aad(scope, id, timestamp, index));
        byte[] encrypted = cipher.doFinal(bytes, 0, size);
        output.writeInt(encrypted.length);
        output.write(cipher.getIV());
        output.write(encrypted);
        output.flush();
    }
    static byte[] read(DataInputStream input, SecretKey key, String scope, String id) throws GeneralSecurityException, IOException {
        long timestamp = input.readLong();
        ByteArrayOutputStream pcm = new ByteArrayOutputStream();
        int index = 0;
        while (true) {
            int length;
            try { length = input.readInt(); } catch (EOFException end) { break; }
            if (length < 16 || length > 65552) throw new IOException("Invalid recording frame.");
            byte[] iv = new byte[12];
            byte[] encrypted = new byte[length];
            try { input.readFully(iv); input.readFully(encrypted); } catch (EOFException end) { break; }
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, iv));
            cipher.updateAAD(aad(scope, id, timestamp, index++));
            pcm.write(cipher.doFinal(encrypted));
        }
        return pcm.toByteArray();
    }
}
