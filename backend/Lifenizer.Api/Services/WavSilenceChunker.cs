using System.Buffers.Binary;

namespace Lifenizer.Api.Services;

/// <summary>
/// Splits PCM16 audio into ~10 s pieces cut inside silences so each piece can be transcribed
/// separately. Null means "not chunkable" (callers fall back to one request); a plan with no
/// chunks means "chunkable but nothing audible".
/// </summary>
public static class WavSilenceChunker
{
    private const int HeaderLength = 44;
    public const int MinSampleRate = 8000;
    public const int MaxSampleRate = 192000;

    public static WavChunkerOptions DefaultOptions { get; } = new();

    public static WavChunkPlan? TryPlan(byte[] wav, WavChunkerOptions? options = null)
    {
        var layout = ParseLayout(wav);
        return layout is null ? null : PlanPcm(wav, layout, options);
    }

    /// <summary>Plans chunks for a WAV whose layout was already parsed.</summary>
    public static WavChunkPlan? TryPlan(byte[] wav, WavLayout layout, WavChunkerOptions? options = null) => PlanPcm(wav, layout, options);

    /// <summary>Plans chunks for raw PCM16 samples located by <paramref name="layout"/>.</summary>
    public static WavChunkPlan? PlanPcm(byte[] source, WavLayout layout, WavChunkerOptions? options = null)
    {
        options ??= DefaultOptions;
        options.Validate();
        var format = layout.Format;
        var duration = TimeSpan.FromSeconds((double)layout.DataLength / format.BlockAlign / format.SampleRate);
        if (duration <= options.NoChunkUpTo) return null;

        var frameSamples = Math.Max(1, (int)(options.Frame.TotalSeconds * format.SampleRate));
        var frameBytes = frameSamples * format.BlockAlign;
        var frameSeconds = (double)frameSamples / format.SampleRate;
        var energy = FrameEnergies(source, layout, frameBytes);
        var silent = SilentFlags(energy, options);
        var bounds = CutFrames(silent, energy, frameSeconds, options);

        var chunks = BuildChunks(bounds, energy, options, new FrameGeometry(frameBytes, frameSeconds, layout));
        return new WavChunkPlan(format, chunks);
    }

    /// <summary>Builds a standalone WAV for one chunk.</summary>
    public static byte[] ToWav(byte[] source, WavFormat format, WavChunk chunk)
    {
        var result = new byte[HeaderLength + chunk.ByteLength];
        WriteHeader(result, format, chunk.ByteLength);
        source.AsSpan(chunk.ByteOffset, chunk.ByteLength).CopyTo(result.AsSpan(HeaderLength));
        return result;
    }

    /// <summary>Builds a standalone WAV around PCM16 samples.</summary>
    public static byte[] ToWav(byte[] pcm, WavFormat format) => ToWav(pcm, format, new WavChunk(0, pcm.Length, TimeSpan.Zero));

    private static void WriteHeader(Span<byte> span, WavFormat format, int dataLength)
    {
        "RIFF"u8.CopyTo(span);
        BinaryPrimitives.WriteInt32LittleEndian(span[4..], 36 + dataLength);
        "WAVEfmt "u8.CopyTo(span[8..]);
        BinaryPrimitives.WriteInt32LittleEndian(span[16..], 16);
        BinaryPrimitives.WriteInt16LittleEndian(span[20..], 1);
        BinaryPrimitives.WriteInt16LittleEndian(span[22..], (short)format.Channels);
        BinaryPrimitives.WriteInt32LittleEndian(span[24..], format.SampleRate);
        BinaryPrimitives.WriteInt32LittleEndian(span[28..], format.SampleRate * format.BlockAlign);
        BinaryPrimitives.WriteInt16LittleEndian(span[32..], (short)format.BlockAlign);
        BinaryPrimitives.WriteInt16LittleEndian(span[34..], 16);
        "data"u8.CopyTo(span[36..]);
        BinaryPrimitives.WriteInt32LittleEndian(span[40..], dataLength);
    }

    /// <summary>Walks the RIFF chunks; returns null unless the file is PCM16 mono/stereo with samples.</summary>
    public static WavLayout? ParseLayout(byte[] wav)
    {
        if (wav.Length < 12 || !wav.AsSpan(0, 4).SequenceEqual("RIFF"u8) || !wav.AsSpan(8, 4).SequenceEqual("WAVE"u8)) return null;

        WavFormat? format = null;
        (int Offset, int Length)? data = null;
        var position = 12;
        while (position + 8 <= wav.Length)
        {
            var id = wav.AsSpan(position, 4);
            var body = position + 8;
            var size = ChunkSize(wav, position, body, isData: id.SequenceEqual("data"u8));
            if (id.SequenceEqual("fmt "u8)) format = ParseFormat(wav.AsSpan(body, size));
            if (id.SequenceEqual("data"u8)) data ??= (body, size);
            position = body + size + (size & 1);
        }
        return BuildLayout(format, data);
    }

    /// <summary>Declared size clamped to the file; 0 or 0xFFFFFFFF in a data chunk means "until end of file" (streamed WAV).</summary>
    private static int ChunkSize(byte[] wav, int position, int body, bool isData)
    {
        var declared = BinaryPrimitives.ReadUInt32LittleEndian(wav.AsSpan(position + 4));
        var remaining = wav.Length - body;
        var streamed = isData && (declared == 0 || declared == uint.MaxValue);
        return streamed ? remaining : (int)Math.Min(declared, (uint)remaining);
    }

    private static WavLayout? BuildLayout(WavFormat? format, (int Offset, int Length)? data)
    {
        if (format is null || data is null) return null;
        var length = data.Value.Length - data.Value.Length % format.BlockAlign;
        return length > 0 ? new WavLayout(format, data.Value.Offset, length) : null;
    }

    private static WavFormat? ParseFormat(ReadOnlySpan<byte> fmt)
    {
        if (fmt.Length < 16) return null;
        var tag = BinaryPrimitives.ReadUInt16LittleEndian(fmt);
        var channels = BinaryPrimitives.ReadUInt16LittleEndian(fmt[2..]);
        var rate = BinaryPrimitives.ReadInt32LittleEndian(fmt[4..]);
        var bits = BinaryPrimitives.ReadUInt16LittleEndian(fmt[14..]);
        var isPcm = tag == 1 || (tag == 0xFFFE && fmt.Length >= 26 && BinaryPrimitives.ReadUInt16LittleEndian(fmt[24..]) == 1);
        if (!isPcm || bits != 16 || channels is not (1 or 2)) return null;
        if (rate is < MinSampleRate or > MaxSampleRate) throw new UnsupportedAudioException($"WAV sample rate must be {MinSampleRate}-{MaxSampleRate} Hz.");
        return new WavFormat(rate, channels);
    }

    private static double[] FrameEnergies(byte[] source, WavLayout layout, int frameBytes)
    {
        var frames = (layout.DataLength + frameBytes - 1) / frameBytes;
        var energy = new double[frames];
        for (var f = 0; f < frames; f++)
        {
            var start = layout.DataOffset + f * frameBytes;
            var length = Math.Min(frameBytes, layout.DataOffset + layout.DataLength - start);
            energy[f] = Rms(source.AsSpan(start, length));
        }
        return energy;
    }

    private static double Rms(ReadOnlySpan<byte> pcm)
    {
        var samples = pcm.Length / 2;
        double sum = 0;
        for (var i = 0; i < samples; i++)
        {
            double value = BinaryPrimitives.ReadInt16LittleEndian(pcm[(i * 2)..]);
            sum += value * value;
        }
        return Math.Sqrt(sum / samples);
    }

    /// <summary>Adaptive threshold from the recording's noise floor; only used to choose cut points.</summary>
    private static bool[] SilentFlags(double[] energy, WavChunkerOptions options)
    {
        var sorted = energy.ToArray();
        Array.Sort(sorted);
        var floor = sorted[(int)((sorted.Length - 1) * options.NoiseFloorPercentile)];
        var threshold = Math.Clamp(floor * options.NoiseFloorFactor, options.MinSilenceRms, options.MaxSilenceRms);
        return energy.Select(e => e < threshold).ToArray();
    }

    /// <summary>Returns chunk boundary frame indices, starting with 0 and ending with the frame count.</summary>
    private static List<int> CutFrames(bool[] silent, double[] energy, double frameSeconds, WavChunkerOptions options)
    {
        var minFrames = Math.Max(1, (int)(options.MinChunk.TotalSeconds / frameSeconds));
        var searchFrames = Math.Max(minFrames + 1, (int)(options.SearchEnd.TotalSeconds / frameSeconds));
        var bounds = new List<int> { 0 };
        var start = 0;
        while (silent.Length - start > searchFrames)
        {
            start = BestCut(silent, energy, start + minFrames, start + searchFrames);
            bounds.Add(start);
        }
        bounds.Add(silent.Length);
        MergeTrailing(bounds, (int)(options.MinTrailingChunk.TotalSeconds / frameSeconds));
        return bounds;
    }

    /// <summary>Middle of the longest silent run in [from, to), else the quietest frame.</summary>
    private static int BestCut(bool[] silent, double[] energy, int from, int to)
    {
        var (runStart, runLength) = LongestSilentRun(silent, from, to);
        return runLength > 0 ? runStart + runLength / 2 : QuietestFrame(energy, from, to);
    }

    private static (int Start, int Length) LongestSilentRun(bool[] silent, int from, int to)
    {
        var best = (Start: from, Length: 0);
        var runStart = from;
        for (var f = from; f < to; f++)
        {
            if (!silent[f])
            {
                runStart = f + 1;
                continue;
            }
            var length = f - runStart + 1;
            if (length > best.Length) best = (runStart, length);
        }
        return best;
    }

    private static int QuietestFrame(double[] energy, int from, int to)
    {
        var quietest = from;
        for (var f = from + 1; f < to; f++)
        {
            if (energy[f] < energy[quietest]) quietest = f;
        }
        return quietest;
    }

    private static void MergeTrailing(List<int> bounds, int minTrailingFrames)
    {
        if (bounds.Count < 3) return;
        if (bounds[^1] - bounds[^2] < minTrailingFrames) bounds.RemoveAt(bounds.Count - 2);
    }

    private sealed record FrameGeometry(int FrameBytes, double FrameSeconds, WavLayout Layout);

    private static List<WavChunk> BuildChunks(List<int> bounds, double[] energy, WavChunkerOptions options, FrameGeometry geometry)
    {
        var chunks = new List<WavChunk>();
        for (var i = 0; i + 1 < bounds.Count; i++)
        {
            if (IsInaudible(energy, bounds[i], bounds[i + 1], options.MinSilenceRms)) continue;
            var startByte = bounds[i] * geometry.FrameBytes;
            var endByte = Math.Min(bounds[i + 1] * geometry.FrameBytes, geometry.Layout.DataLength);
            chunks.Add(new WavChunk(geometry.Layout.DataOffset + startByte, endByte - startByte, TimeSpan.FromSeconds(bounds[i] * geometry.FrameSeconds)));
        }
        return chunks;
    }

    /// <summary>Absolute test (not the adaptive threshold) so quiet speech in a noisy recording is kept.</summary>
    private static bool IsInaudible(double[] energy, int from, int to, double minRms)
    {
        for (var f = from; f < to; f++)
        {
            if (energy[f] >= minRms) return false;
        }
        return true;
    }
}
