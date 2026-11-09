package com.lifenizer.app;

import java.io.*;
import java.util.Arrays;
import javax.crypto.AEADBadTagException;
import javax.crypto.spec.SecretKeySpec;
import org.junit.Test;
import static org.junit.Assert.*;

public class CaptureFramesTest {
    private final SecretKeySpec key = new SecretKeySpec(new byte[32], "AES");
    private byte[] capture() throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        DataOutputStream output = new DataOutputStream(bytes);
        output.writeLong(1234);
        CaptureFrames.append(output, key, "library-a", "capture", 0, 1234, new byte[]{1, 2}, 2);
        CaptureFrames.append(output, key, "library-a", "capture", 1, 1234, new byte[]{3, 4}, 2);
        return bytes.toByteArray();
    }
    private byte[] read(byte[] bytes, String scope, String id) throws Exception {
        return CaptureFrames.read(new DataInputStream(new ByteArrayInputStream(bytes)), key, scope, id);
    }
    @Test public void roundTripAndRecoverEveryTruncatedTail() throws Exception {
        byte[] bytes = capture();
        assertArrayEquals(new byte[]{1, 2, 3, 4}, read(bytes, "library-a", "capture"));
        int firstFrameEnd = 8 + 4 + 12 + 18;
        for (int end = firstFrameEnd; end < bytes.length; end++) {
            assertArrayEquals(new byte[]{1, 2}, read(Arrays.copyOf(bytes, end), "library-a", "capture"));
        }
    }
    @Test public void rejectsAlteredAudioTimestampAndAccountOrCaptureScope() throws Exception {
        byte[] bytes = capture();
        for (String scope : new String[]{"library-b", "library-a"}) {
            try { read(bytes, scope, "other-capture"); fail("Capture scope accepted"); }
            catch (AEADBadTagException expected) { }
        }
        try { read(bytes, "library-b", "capture"); fail("Account scope accepted"); }
        catch (AEADBadTagException expected) { }
        for (int offset : new int[]{0, 8 + 4 + 12}) {
            byte[] altered = bytes.clone(); altered[offset] ^= 1;
            try { read(altered, "library-a", "capture"); fail("Altered capture accepted"); }
            catch (AEADBadTagException expected) { }
        }
    }
    @Test public void locationMetadataIsBoundToCaptureAndCannotReplaceAudio() throws Exception {
        byte[] location = "{\"town\":\"Berlin\",\"latitude\":52.52,\"longitude\":13.405}".getBytes("UTF-8");
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        DataOutputStream output = new DataOutputStream(bytes);
        output.writeLong(0);
        CaptureFrames.append(output, key, "library-a/location", "capture", 0, 0, location, location.length);
        assertArrayEquals(location, read(bytes.toByteArray(), "library-a/location", "capture"));
        for (String[] binding : new String[][]{{"library-a", "capture"}, {"library-a/location", "other"}, {"library-b/location", "capture"}}) {
            try { read(bytes.toByteArray(), binding[0], binding[1]); fail("Location binding accepted"); }
            catch (AEADBadTagException expected) { }
        }
    }
}
