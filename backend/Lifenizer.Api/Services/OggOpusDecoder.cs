using System.Buffers.Binary;
using Concentus;

namespace Lifenizer.Api.Services;

/// <summary>The audio is longer than Imports:MaxAudioSeconds. Never forwarded to whisper; maps to a 400.</summary>
public sealed class AudioTooLongException(int maxSeconds)
    : InvalidOperationException($"Audio is longer than the maximum of {maxSeconds} seconds.");

/// <summary>The audio is in a form we refuse to forward or process; maps to a 400.</summary>
public sealed class UnsupportedAudioException(string message, Exception? inner = null) : InvalidOperationException(message, inner)
{
    public static UnsupportedAudioException Ogg(Exception? inner = null) =>
        new("Unsupported or damaged Ogg audio - export as WAV or Opus mono/stereo.", inner);
}

/// <summary>Concentus could not decode a packet.</summary>
public sealed class OpusDecodeException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>Decodes Ogg Opus (pure managed Concentus) to 16 kHz mono PCM16. Parses the Ogg pages itself so a corrupt stream can never stall.</summary>
public static class OggOpusDecoder
{
    public const int SampleRate = 16000;
    private const int OpusRate = 48000;
    private const int MaxPacketSamples = SampleRate * 120 / 1000;
    private const int PacketsPerCancellationCheck = 256;
    private const int HeaderPackets = 2;

    public static WavFormat Format { get; } = new(SampleRate, 1);

    static OggOpusDecoder()
    {
        OpusCodecFactory.AttemptToUseNativeLibrary = false;
    }

    /// <summary>True for anything that starts like an Ogg file (Opus, Vorbis, ...).</summary>
    public static bool IsOgg(ReadOnlySpan<byte> data) => data.Length >= 4 && data[..4].SequenceEqual("OggS"u8);

    /// <summary>PCM16 byte length a decode of this scan produces at most.</summary>
    public static long OutputBytes(OpusScan scan) => scan.DecodableSamples48k * SampleRate / OpusRate * 2;

    /// <summary>Decodes to PCM16 (pre-skip removed, trailing padding trimmed, output gain applied, empty packets skipped).</summary>
    /// <exception cref="AudioTooLongException">The stream's duration exceeds <paramref name="maxSeconds"/>.</exception>
    /// <exception cref="OpusDecodeException">A packet cannot be decoded.</exception>
    public static byte[] DecodeToPcm16(byte[] ogg, OpusScan scan, int maxSeconds, CancellationToken cancellationToken)
    {
        if (scan.ExceedsSeconds(maxSeconds)) throw new AudioTooLongException(maxSeconds);

        var output = new byte[OutputBytes(scan)];
        var skip = scan.PreSkip48k * SampleRate / OpusRate;
        var written = DecodePackets(ogg, scan, output, skip, cancellationToken);
        if (written == 0) throw new OpusDecodeException("Ogg Opus stream contains no decodable audio.");
        return written == output.Length ? output : output[..written];
    }

    private static int DecodePackets(byte[] ogg, OpusScan scan, byte[] output, int skipSamples, CancellationToken cancellationToken)
    {
        var decoder = CreateDecoder(scan);
        var scratch = new short[MaxPacketSamples];
        var written = 0;
        var index = 0;
        foreach (var packet in OggPage.Packets(ogg))
        {
            if (index++ < HeaderPackets || packet.Length == 0) continue;
            if (index % PacketsPerCancellationCheck == 0) cancellationToken.ThrowIfCancellationRequested();
            var count = DecodePacket(decoder, packet, scratch);
            written += CopySamples(scratch.AsSpan(0, count), ref skipSamples, output.AsSpan(written));
            if (written == output.Length) break;
        }
        return written;
    }

    private static IOpusDecoder CreateDecoder(OpusScan scan)
    {
        var decoder = OpusCodecFactory.CreateDecoder(SampleRate, 1);
        decoder.Gain = scan.GainQ8;
        return decoder;
    }

    private static int DecodePacket(IOpusDecoder decoder, ReadOnlyMemory<byte> packet, short[] scratch)
    {
        try
        {
            return decoder.Decode(packet.Span, scratch, scratch.Length, false);
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            throw new OpusDecodeException("Ogg Opus packet could not be decoded.", exception);
        }
    }

    /// <summary>Copies samples after the pre-skip into the destination; returns the bytes written.</summary>
    private static int CopySamples(ReadOnlySpan<short> samples, ref int skipSamples, Span<byte> destination)
    {
        var skipped = Math.Min(skipSamples, samples.Length);
        skipSamples -= skipped;
        var usable = Math.Min(samples.Length - skipped, destination.Length / 2);
        for (var i = 0; i < usable; i++)
        {
            BinaryPrimitives.WriteInt16LittleEndian(destination[(i * 2)..], samples[skipped + i]);
        }
        return usable * 2;
    }

    /// <summary>Pre-skip and output gain from an OpusHead page; null when unusable (more than two channels, mapping family other than 0).</summary>
    internal static (int PreSkip, int GainQ8)? ParseHead(byte[] ogg, OggPage page)
    {
        var body = ogg.AsSpan(page.BodyOffset, page.BodyLength);
        if (body.Length < 19 || !body[..8].SequenceEqual("OpusHead"u8)) return null;
        var channels = body[9];
        var mappingFamily = body[18];
        if (channels is < 1 or > 2 || mappingFamily != 0) return null;
        return (BinaryPrimitives.ReadUInt16LittleEndian(body[10..]), BinaryPrimitives.ReadInt16LittleEndian(body[16..]));
    }
}
