using System.Buffers.Binary;

namespace Lifenizer.Api.Services;

/// <summary>
/// Splits PCM16 audio at long pauses (default 10 s, the pause itself is dropped) so each piece can be
/// transcribed separately; stretches longer than MaxChunk (default 28 s) are split into contiguous pieces at their best
/// gap. Null means "not chunkable" (callers fall back to one request); a plan with no chunks means "chunkable but nothing audible".
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

        var speech = AnalyzeSpeech(source, layout, options);
        var test = speech.Test;
        var ranges = PlanRanges(test, speech.FrameSeconds, options);
        var chunks = BuildChunks(ranges, test.Energy, options, new FrameGeometry(speech.FrameBytes, speech.FrameSeconds, layout));
        return new WavChunkPlan(format, chunks) { Speech = speech };
    }

    /// <summary>The whole PCM as one chunk (a short file sent whole), with its speech map so a part of it can be judged.</summary>
    public static WavChunkPlan WholePlan(byte[] source, WavLayout layout, WavChunkerOptions? options = null)
    {
        options ??= DefaultOptions;
        options.Validate();
        var chunk = new WavChunk(layout.DataOffset, layout.DataLength, TimeSpan.Zero);
        return new WavChunkPlan(layout.Format, [chunk]) { Speech = AnalyzeSpeech(source, layout, options) };
    }

    /// <summary>Frame levels and silence flags of the PCM, judged the way the planner judges them.</summary>
    private static WavSpeechMap AnalyzeSpeech(byte[] source, WavLayout layout, WavChunkerOptions options)
    {
        var format = layout.Format;
        var frameSamples = Math.Max(1, (int)(options.Frame.TotalSeconds * format.SampleRate));
        var frameBytes = frameSamples * format.BlockAlign;
        var frameSeconds = (double)frameSamples / format.SampleRate;
        var energy = FrameEnergies(source, layout, frameBytes);
        var silent = SilentFlags(energy, frameSeconds, options);
        var test = new SpeechTest(energy, silent, options.MinSilenceRms, Math.Max(1, Frames(options.MinSpeech, frameSeconds)));
        return new WavSpeechMap(test, frameBytes, frameSeconds, layout.DataOffset);
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
    internal readonly record struct FrameRange(int Start, int End);

    private static int Frames(TimeSpan span, double frameSeconds) => (int)(span.TotalSeconds / frameSeconds);

    /// <summary>
    /// Speech ranges between pauses that hold enough speech, each split further (without a gap between the pieces)
    /// when it exceeds the maximum chunk length. MinSpeech is judged on the whole range, so a cap piece of quiet speech is kept.
    /// </summary>
    private static List<FrameRange> PlanRanges(SpeechTest speech, double frameSeconds, WavChunkerOptions options)
    {
        var (energy, silent) = (speech.Energy, speech.Silent);
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
        foreach (var range in SpeechRanges(pauses, padding, silent.Length))
        {
            if (speech.IsWorthSending(range)) SplitLong(range, silent, energy, cap, ranges);
        }
        return ranges;
    }

    /// <summary>A range is sent when it is audible and holds at least MinSpeech of non-silent frames (drops stray noise between two pauses).</summary>
    internal sealed record SpeechTest(double[] Energy, bool[] Silent, double MinSilenceRms, int MinSpeechFrames)
    {
        public bool IsWorthSending(FrameRange range) => IsWorthSending(range, MinSpeechFrames);

        /// <summary>Same test with a caller-chosen minimum of non-silent frames.</summary>
        public bool IsWorthSending(FrameRange range, int minSpeechFrames) =>
            !IsInaudible(Energy, range.Start, range.End, MinSilenceRms) && SpeechFrames(Silent, range, minSpeechFrames) >= minSpeechFrames;
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

    /// <summary>Adds the range as contiguous pieces of at most MaxFrames, each cut at the best gap near the cap.</summary>
    private static void SplitLong(FrameRange range, bool[] silent, double[] energy, CapSplit cap, List<FrameRange> result)
    {
        var start = range.Start;
        while (range.End - start > cap.MaxFrames)
        {
            var cut = CapCut(new FrameRange(start, range.End), silent, energy, cap);
            result.Add(new FrameRange(start, cut));
            start = cut;
        }
        result.Add(new FrameRange(start, range.End));
    }

    /// <summary>
    /// Cut point for a range longer than the cap, inside the search window: the middle of the longest gap (silent
    /// run) touching the window, else a clearly quieter frame, else a hard cut at the window end.
    /// </summary>
    private static int CapCut(FrameRange range, bool[] silent, double[] energy, CapSplit cap)
    {
        var window = SearchWindow(range, cap);
        var gap = LongestGap(silent, window, range);
        if (gap.End > gap.Start) return Math.Clamp((gap.Start + gap.End) / 2, window.Start, window.End);

        return ClearDip(energy, window) ?? window.End;
    }

    /// <summary>
    /// [cap - search, cap], its end pulled in so the last piece keeps at least MinTrailingFrames (no sub-second
    /// whisper requests, no word split off at the very end).
    /// </summary>
    private static FrameRange SearchWindow(FrameRange range, CapSplit cap)
    {
        var hi = range.Start + cap.MaxFrames;
        var lo = hi - Math.Min(cap.SearchFrames, cap.MaxFrames - 1);
        return new FrameRange(lo, Math.Clamp(range.End - cap.MinTrailingFrames, lo + 1, hi));
    }

    /// <summary>Longest silent run overlapping the window, measured in full within the range (a gap straddling the window edge keeps its real length).</summary>
    private static FrameRange LongestGap(bool[] silent, FrameRange window, FrameRange range)
    {
        var best = new FrameRange(window.Start, window.Start);
        var f = window.Start;
        while (silent[window.Start] && f > range.Start && silent[f - 1]) f--;
        while (f < window.End)
        {
            if (!silent[f])
            {
                f++;
                continue;
            }
            var end = f;
            while (end < range.End && silent[end]) end++;
            if (end - f > best.End - best.Start) best = new FrameRange(f, end);
            f = end;
        }
        return best;
    }

    /// <summary>A frame is a gap when it is this much quieter than the window's median (speech gaps in a room where the threshold is not trusted).</summary>
    private const double DipShareOfMedian = 0.5;

    /// <summary>The quietest frame of the window when it is clearly quieter than the window's median, else null.</summary>
    private static int? ClearDip(double[] energy, FrameRange window)
    {
        var levels = energy[window.Start..window.End];
        var quietest = window.Start + Array.IndexOf(levels, levels.Min());
        Array.Sort(levels);
        var median = levels[levels.Length / 2];
        return energy[quietest] <= median * DipShareOfMedian ? quietest : null;
    }

    private sealed record FrameGeometry(int FrameBytes, double FrameSeconds, WavLayout Layout);

    /// <summary>Byte chunks for the planned ranges; a cap piece is only dropped when it is entirely inaudible.</summary>
    private static List<WavChunk> BuildChunks(List<FrameRange> ranges, double[] energy, WavChunkerOptions options, FrameGeometry geometry)
    {
        var chunks = new List<WavChunk>();
        foreach (var range in ranges)
        {
            if (IsInaudible(energy, range.Start, range.End, options.MinSilenceRms)) continue;
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
