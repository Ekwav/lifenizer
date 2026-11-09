using System.Buffers.Binary;

namespace Lifenizer.Api.Services;

/// <summary>An Ogg Opus packet is implausibly large (valid ones are under ~61 KB); maps to a 400.</summary>
public sealed class InvalidOpusStreamException(string message) : InvalidOperationException(message);

/// <summary>What the Ogg pages of an Ogg Opus file reveal without decoding anything.</summary>
/// <param name="GranuleSamples48k">Final granule of the first stream (untrusted).</param>
/// <param name="TocSamples48k">Audio duration summed from every packet's TOC across all pages and streams.</param>
public sealed record OpusScan(int PreSkip48k, int GainQ8, long GranuleSamples48k, long TocSamples48k)
{
    /// <summary>Samples (48 kHz units) a decode may produce: the smaller of the granule and the TOC claims, minus pre-skip.</summary>
    public long DecodableSamples48k => Math.Max(0, Math.Min(GranuleSamples48k, TocSamples48k) - PreSkip48k);

    /// <summary>Compares raw sample counts, so an absurd granule can never overflow.</summary>
    public bool ExceedsSeconds(int maxSeconds) =>
        Math.Max(GranuleSamples48k - PreSkip48k, TocSamples48k) > maxSeconds * 48000L;
}

/// <summary>
/// Strictly walks a single clean Ogg Opus stream and sums packet durations from their TOC bytes.
/// Anything else (bad checksum, garbage between pages, a second stream, more than two channels, non-Opus) is rejected,
/// so the sum can never disagree with what another demuxer such as ffmpeg would play.
/// </summary>
public static class OpusStreamScanner
{
    public const int MaxPacketBytes = 128 * 1024;
    private const int HeaderPackets = 2;
    private const int MaxPacketSamples48k = 5760;

    /// <exception cref="UnsupportedAudioException">The file is not a clean single-stream Ogg Opus file.</exception>
    /// <exception cref="InvalidOpusStreamException">A packet is larger than any valid Opus packet.</exception>
    public static OpusScan Scan(byte[] data)
    {
        var state = new ScanState();
        var position = 0;
        while (position < data.Length)
        {
            var page = OggPage.TryRead(data, position);
            if (page is null || !page.HasValidCrc(data)) throw UnsupportedAudioException.Ogg();
            state.Add(data, page);
            position = page.End;
        }
        return state.Result();
    }

    /// <summary>Duration in 48 kHz samples from the TOC (RFC 6716 section 3.1); empty or invalid packets count as 0.</summary>
    public static int TocSamples(byte toc, byte secondByte, int packetLength)
    {
        if (packetLength == 0) return 0;
        var frames = (toc & 3) switch
        {
            0 => 1,
            3 => packetLength >= 2 ? secondByte & 0x3F : 0,
            _ => 2
        };
        return Math.Min(frames * FrameSamples(toc >> 3), MaxPacketSamples48k);
    }

    private static int FrameSamples(int config) => config switch
    {
        < 12 => new[] { 480, 960, 1920, 2880 }[config & 3],
        < 16 => (config & 1) == 0 ? 480 : 960,
        _ => new[] { 120, 240, 480, 960 }[config & 3]
    };

    private sealed class ScanState
    {
        private readonly byte[] firstBytes = new byte[2];
        private bool started;
        private uint serial;
        private (int PreSkip, int GainQ8) head;
        private long granule;
        private long tocSamples;
        private int packetIndex;
        private int packetLength;

        public void Add(byte[] data, OggPage page)
        {
            if (!started) Start(data, page);
            else if (page.IsFirstPage || page.Serial != serial) throw UnsupportedAudioException.Ogg();
            granule = Math.Max(granule, page.Granule);
            ReadSegments(data, page);
        }

        public OpusScan Result()
        {
            if (!started) throw UnsupportedAudioException.Ogg();
            return new OpusScan(head.PreSkip, head.GainQ8, granule, tocSamples);
        }

        private void Start(byte[] data, OggPage page)
        {
            var parsed = page.IsFirstPage ? OggOpusDecoder.ParseHead(data, page) : null;
            head = parsed ?? throw UnsupportedAudioException.Ogg();
            serial = page.Serial;
            started = true;
        }

        private void ReadSegments(byte[] data, OggPage page)
        {
            var offset = page.BodyOffset;
            for (var i = 0; i < page.SegmentCount; i++)
            {
                var size = data[page.SegmentTableOffset + i];
                CaptureLeadingBytes(data, offset, size);
                packetLength += size;
                offset += size;
                if (packetLength > MaxPacketBytes) throw new InvalidOpusStreamException("Ogg Opus packet is larger than any valid Opus packet.");
                if (size < 255) EndPacket();
            }
        }

        private void CaptureLeadingBytes(byte[] data, int offset, int size)
        {
            for (var i = 0; i < size && packetLength + i < 2; i++) firstBytes[packetLength + i] = data[offset + i];
        }

        private void EndPacket()
        {
            if (packetIndex++ >= HeaderPackets) tocSamples += TocSamples(firstBytes[0], firstBytes[1], packetLength);
            packetLength = 0;
            firstBytes[0] = firstBytes[1] = 0;
        }
    }
}
