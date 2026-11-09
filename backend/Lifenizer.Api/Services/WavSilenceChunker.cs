using System.Buffers.Binary;

namespace Lifenizer.Api.Services;

/// <summary>
/// Splits PCM16 audio at long pauses (default 10 s, the pause itself is dropped) so each piece can be
/// transcribed separately; stretches longer than MaxChunk are cut at their best silence. Null means "not chunkable" (callers fall back to one request); a plan with no
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
        var silent = SilentFlags(energy, frameSeconds, options);
        var ranges = PlanRanges(silent, energy, frameSeconds, options);

        var chunks = BuildChunks(ranges, energy, silent, options, new FrameGeometry(frameBytes, frameSeconds, layout));
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

    public const int WavHeaderLength = HeaderLength;

    /// <summary>The 44-byte canonical header for <paramref name="dataLength"/> bytes of PCM16.</summary>
    public static byte[] CreateHeader(WavFormat format, int dataLength)
    {
        var header = new byte[HeaderLength];
        WriteHeader(header, format, dataLength);
        return header;
    }

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

    private const double MinContrast = 2.0;
    /// <summary>In a loud room (floor above MaxNoiseFloorRms) the threshold is trusted only when this share of the recording is clearly louder.</summary>
    private const double MinLoudShareOfNoisyRecording = 0.10;

    /// <summary>
    /// Adaptive threshold from the recording's noise floor; only used to choose cut points. The threshold is
    /// trusted only when there is clearly louder audio (at least MinLoudDuration at MinContrast times the
    /// threshold) and the floor is plausibly silence (not above MaxNoiseFloorRms, unless a tenth of the recording is that loud). Otherwise (steady or quiet
    /// recordings, or almost no speech) only the absolute MinSilenceRms level counts as silence.
    /// </summary>
    private static bool[] SilentFlags(double[] energy, double frameSeconds, WavChunkerOptions options)
    {
        var sorted = energy.ToArray();
        Array.Sort(sorted);
        var floor = sorted[(int)((sorted.Length - 1) * options.NoiseFloorPercentile)];
        var threshold = Math.Clamp(floor * options.NoiseFloorFactor, options.MinSilenceRms, options.MaxSilenceRms);
        var minLoudFrames = Math.Max(1, (int)(options.MinLoudDuration.TotalSeconds / frameSeconds));
        var loudFrames = CountAtLeast(energy, threshold * MinContrast);
        var plausibleSilence = floor <= options.MaxNoiseFloorRms || loudFrames >= energy.Length * MinLoudShareOfNoisyRecording;
        var trusted = plausibleSilence && loudFrames >= minLoudFrames;
        var limit = trusted ? threshold : options.MinSilenceRms;
        return energy.Select(e => e < limit).ToArray();
    }

    private static int CountAtLeast(double[] energy, double level)
    {
        var count = 0;
        foreach (var e in energy)
        {
            if (e >= level) count++;
        }
        return count;
    }

    /// <summary>Frame range [Start, End) of audio to transcribe.</summary>
    private readonly record struct FrameRange(int Start, int End);

    private static int Frames(TimeSpan span, double frameSeconds) => (int)(span.TotalSeconds / frameSeconds);

    /// <summary>Speech ranges between pauses, each split further when it exceeds the maximum chunk length.</summary>
    private static List<FrameRange> PlanRanges(bool[] silent, double[] energy, double frameSeconds, WavChunkerOptions options)
    {
        var rules = new PauseRules(
            Math.Max(1, Frames(options.MinPause, frameSeconds)),
            Frames(options.MaxBlipInPause, frameSeconds),
            Frames(options.MinSilenceBeforeBlip, frameSeconds));
        var pauses = FindPauses(silent, rules);
        var padding = Frames(options.PausePadding, frameSeconds);
        var cap = new CapSplit(
            Math.Max(2, Frames(options.MaxChunk, frameSeconds)),
            Math.Max(1, Frames(options.CapSearchWindow, frameSeconds)),
            Frames(options.MinTrailingChunk, frameSeconds));
        var ranges = new List<FrameRange>();
        foreach (var range in SpeechRanges(pauses, padding, silent.Length)) SplitLong(range, silent, energy, cap, ranges);
        return ranges;
    }

    private readonly record struct PauseRules(int MinFrames, int BlipFrames, int MinSilenceBeforeBlip);

    private readonly record struct CapSplit(int MaxFrames, int SearchFrames, int MinTrailingFrames);

    /// <summary>
    /// Pauses: runs of silent frames of at least <see cref="PauseRules.MinFrames"/>; a non-silent run of
    /// up to BlipFrames is bridged only after a long enough silent run. A pause ends at its last silent frame.
    /// </summary>
    private static List<FrameRange> FindPauses(bool[] silent, PauseRules rules)
    {
        var pauses = new List<FrameRange>();
        var f = 0;
        while (f < silent.Length)
        {
            if (!silent[f])
            {
                f++;
                continue;
            }
            var end = PauseEnd(silent, f, rules);
            if (end - f >= rules.MinFrames) pauses.Add(new FrameRange(f, end));
            f = end;
        }
        return pauses;
    }

    /// <summary>Exclusive end of the pause that starts at silent frame <paramref name="start"/>.</summary>
    private static int PauseEnd(bool[] silent, int start, PauseRules rules)
    {
        var end = start;
        var runStart = start;
        var f = start;
        while (f < silent.Length)
        {
            if (silent[f])
            {
                f++;
                end = f;
                continue;
            }
            var blipEnd = f;
            while (blipEnd < silent.Length && !silent[blipEnd]) blipEnd++;
            var bridgeable = blipEnd < silent.Length && blipEnd - f <= rules.BlipFrames
                && f - runStart >= rules.MinSilenceBeforeBlip && SilentRun(silent, blipEnd, rules.MinSilenceBeforeBlip) >= rules.MinSilenceBeforeBlip;
            if (!bridgeable) break;
            f = blipEnd;
            runStart = blipEnd;
        }
        return end;
    }

    /// <summary>Length of the silent run starting at <paramref name="from"/>, counting at most <paramref name="limit"/> frames.</summary>
    private static int SilentRun(bool[] silent, int from, int limit)
    {
        var count = 0;
        while (from + count < silent.Length && count < limit && silent[from + count]) count++;
        return count;
    }

    /// <summary>The audio between pauses, each pause shrunk by the padding on both sides; a pause at either edge trims it.</summary>
    private static IEnumerable<FrameRange> SpeechRanges(List<FrameRange> pauses, int padding, int frameCount)
    {
        var start = 0;
        foreach (var pause in pauses)
        {
            var end = pause.Start == 0 ? 0 : Math.Min(frameCount, pause.Start + padding);
            if (end > start) yield return new FrameRange(start, end);
            start = pause.End >= frameCount ? frameCount : Math.Max(start, pause.End - padding);
        }
        if (frameCount > start) yield return new FrameRange(start, frameCount);
    }

    /// <summary>Adds the range, cut at the best silence near the maximum length while it is longer than that.</summary>
    private static void SplitLong(FrameRange range, bool[] silent, double[] energy, CapSplit cap, List<FrameRange> result)
    {
        var first = result.Count;
        var start = range.Start;
        var searchFrames = Math.Min(cap.SearchFrames, cap.MaxFrames - 1);
        while (range.End - start > cap.MaxFrames)
        {
            var cut = BestCut(silent, energy, start + cap.MaxFrames - searchFrames, start + cap.MaxFrames);
            result.Add(new FrameRange(start, cut));
            start = cut;
        }
        if (result.Count > first && range.End - start < cap.MinTrailingFrames)
        {
            start = result[^1].Start;
            result.RemoveAt(result.Count - 1);
        }
        result.Add(new FrameRange(start, range.End));
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

    private sealed record FrameGeometry(int FrameBytes, double FrameSeconds, WavLayout Layout);

    private static List<WavChunk> BuildChunks(List<FrameRange> ranges, double[] energy, bool[] silent, WavChunkerOptions options, FrameGeometry geometry)
    {
        var chunks = new List<WavChunk>();
        var minSpeechFrames = Math.Max(1, (int)(options.MinSpeech.TotalSeconds / geometry.FrameSeconds));
        foreach (var range in ranges)
        {
            if (IsInaudible(energy, range.Start, range.End, options.MinSilenceRms)) continue;
            if (SpeechFrames(silent, range, minSpeechFrames) < minSpeechFrames) continue;
            var startByte = range.Start * geometry.FrameBytes;
            var endByte = Math.Min(range.End * geometry.FrameBytes, geometry.Layout.DataLength);
            chunks.Add(new WavChunk(geometry.Layout.DataOffset + startByte, endByte - startByte, TimeSpan.FromSeconds(range.Start * geometry.FrameSeconds)));
        }
        return chunks;
    }

    /// <summary>Number of non-silent frames in the range, counting stops at <paramref name="enough"/>.</summary>
    private static int SpeechFrames(bool[] silent, FrameRange range, int enough)
    {
        var count = 0;
        for (var f = range.Start; f < range.End && count < enough; f++)
        {
            if (!silent[f]) count++;
        }
        return count;
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
