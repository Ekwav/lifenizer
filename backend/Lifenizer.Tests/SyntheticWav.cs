using System.Buffers.Binary;

namespace Lifenizer.Tests;

/// <summary>Builds PCM16 test WAVs from a speech/silence pattern (sine tone = "speech").</summary>
internal static class SyntheticWav
{
    public const int Rate = 16000;

    public static byte[] Build(double seconds, Func<double, bool> isSpeech, int channels = 1, bool listChunkFirst = false, int formatTag = 1, int bits = 16, double amplitude = 8000, bool extensible = false, bool fmtAfterData = false, int rate = Rate)
    {
        var frames = (int)(seconds * rate);
        var data = new byte[frames * channels * 2];
        for (var i = 0; i < frames; i++)
        {
            var t = (double)i / rate;
            var value = isSpeech(t) ? (short)(amplitude * Math.Sin(2 * Math.PI * (300 + 7 * Math.Floor(t / 5)) * t)) : (short)0;
            for (var c = 0; c < channels; c++) BinaryPrimitives.WriteInt16LittleEndian(data.AsSpan((i * channels + c) * 2), value);
        }
        return Wrap(data, channels, listChunkFirst, formatTag, bits, extensible, fmtAfterData, rate);
    }

    /// <summary>4 s speech followed by 1 s silence, repeated.</summary>
    public static bool SentencePattern(double t) => t % 5 < 4;

    public static byte[] Wrap(byte[] data, int channels, bool listChunkFirst, int formatTag = 1, int bits = 16, bool extensible = false, bool fmtAfterData = false, int rate = Rate)
    {
        var fmt = FormatChunk(channels, extensible ? 0xFFFE : formatTag, bits, extensible, rate);
        using var stream = new MemoryStream();
        using var w = new BinaryWriter(stream);
        w.Write("RIFF"u8.ToArray());
        w.Write(0); // patched below
        w.Write("WAVE"u8.ToArray());
        if (!fmtAfterData) w.Write(fmt);
        if (listChunkFirst) WriteList(w);
        w.Write("data"u8.ToArray());
        w.Write(data.Length);
        w.Write(data);
        if (fmtAfterData) w.Write(fmt);
        var bytes = stream.ToArray();
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(4), bytes.Length - 8);
        return bytes;
    }

    private static byte[] FormatChunk(int channels, int tag, int bits, bool extensible, int rate)
    {
        using var stream = new MemoryStream();
        using var w = new BinaryWriter(stream);
        w.Write("fmt "u8.ToArray());
        w.Write(extensible ? 40 : 16);
        w.Write((short)tag);
        w.Write((short)channels);
        w.Write(rate);
        w.Write(rate * channels * 2);
        w.Write((short)(channels * 2));
        w.Write((short)bits);
        if (extensible)
        {
            w.Write((short)22);
            w.Write((short)16);
            w.Write(0);
            w.Write(new byte[] { 1, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71 }); // PCM subformat GUID
        }
        return stream.ToArray();
    }

    private static void WriteList(BinaryWriter w)
    {
        w.Write("LIST"u8.ToArray());
        w.Write(7);
        w.Write(new byte[] { (byte)'I', (byte)'N', (byte)'F', (byte)'O', 1, 2, 3 });
        w.Write((byte)0); // odd-size padding
    }
}
