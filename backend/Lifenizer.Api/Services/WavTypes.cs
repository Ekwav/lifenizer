namespace Lifenizer.Api.Services;

/// <summary>Tunable parameters for <see cref="WavSilenceChunker"/>.</summary>
public sealed record WavChunkerOptions
{
    public TimeSpan Frame { get; init; } = TimeSpan.FromMilliseconds(30);
    /// <summary>A silence at least this long is a pause: the audio is cut there and the pause is dropped.</summary>
    public TimeSpan MinPause { get; init; } = TimeSpan.FromSeconds(10);
    /// <summary>Non-silent blips up to this long (a cough, a click) do not break a pause.</summary>
    public TimeSpan MaxBlipInPause { get; init; } = TimeSpan.FromMilliseconds(300);
    /// <summary>A blip is only bridged when at least this much silence precedes it, so syllable-sized gaps in noisy speech never form a pause.</summary>
    public TimeSpan MinSilenceBeforeBlip { get; init; } = TimeSpan.FromSeconds(1);
    /// <summary>Silence kept on both sides of a dropped pause so word edges are not clipped.</summary>
    public TimeSpan PausePadding { get; init; } = TimeSpan.FromMilliseconds(500);
    /// <summary>Longest chunk; a longer stretch without a pause is cut at its best silence near this length.</summary>
    public TimeSpan MaxChunk { get; init; } = TimeSpan.FromMinutes(5);
    /// <summary>A forced cut is searched in the last part of the window: [MaxChunk - this, MaxChunk].</summary>
    public TimeSpan CapSearchWindow { get; init; } = TimeSpan.FromSeconds(60);
    /// <summary>A shorter final piece of a forced split is merged into its predecessor.</summary>
    public TimeSpan MinTrailingChunk { get; init; } = TimeSpan.FromSeconds(2);
    /// <summary>Recordings up to this length are not chunked.</summary>
    public TimeSpan NoChunkUpTo { get; init; } = TimeSpan.FromSeconds(30);
    /// <summary>A chunk with less non-silent audio than this is dropped (stray noise between two pauses).</summary>
    public TimeSpan MinSpeech { get; init; } = TimeSpan.FromMilliseconds(200);
    /// <summary>The adaptive threshold needs at least this much clearly loud audio, else only the absolute MinSilenceRms counts as silence.</summary>
    public TimeSpan MinLoudDuration { get; init; } = TimeSpan.FromSeconds(1);
    /// <summary>A noise floor above this is not trusted as silence (it may be quiet speech) unless a tenth of the recording is clearly louder; otherwise only the absolute MinSilenceRms counts.</summary>
    public double MaxNoiseFloorRms { get; init; } = 250;
    public double NoiseFloorPercentile { get; init; } = 0.10;
    public double NoiseFloorFactor { get; init; } = 3.0;
    /// <summary>Lower bound of the adaptive cut threshold; also the level below which a chunk counts as silent.</summary>
    public double MinSilenceRms { get; init; } = 120;
    public double MaxSilenceRms { get; init; } = 1500;

    public void Validate()
    {
        if (Frame <= TimeSpan.Zero) throw new ArgumentException("Frame must be positive.", nameof(Frame));
        if (MinPause < Frame) throw new ArgumentException("MinPause must span at least one frame.", nameof(MinPause));
        if (MaxBlipInPause < TimeSpan.Zero) throw new ArgumentException("MaxBlipInPause must not be negative.", nameof(MaxBlipInPause));
        if (MinSilenceBeforeBlip < TimeSpan.Zero) throw new ArgumentException("MinSilenceBeforeBlip must not be negative.", nameof(MinSilenceBeforeBlip));
        if (PausePadding < TimeSpan.Zero || PausePadding * 2 > MinPause) throw new ArgumentException("PausePadding must be between zero and half of MinPause.", nameof(PausePadding));
        if (CapSearchWindow < Frame) throw new ArgumentException("CapSearchWindow must span at least one frame.", nameof(CapSearchWindow));
        if (MaxChunk <= CapSearchWindow) throw new ArgumentException("MaxChunk must be longer than CapSearchWindow.", nameof(MaxChunk));
        if (MinTrailingChunk < TimeSpan.Zero) throw new ArgumentException("MinTrailingChunk must not be negative.", nameof(MinTrailingChunk));
    }
}

public sealed record WavFormat(int SampleRate, int Channels)
{
    public int BlockAlign => Channels * 2;
}

/// <summary>Where the PCM samples sit inside a WAV file.</summary>
public sealed record WavLayout(WavFormat Format, int DataOffset, int DataLength);

/// <summary>A byte range of the source PCM (absolute offsets) and where it starts in time.</summary>
public sealed record WavChunk(int ByteOffset, int ByteLength, TimeSpan Start);

/// <summary>Chunks to transcribe; an empty list means the audio holds nothing audible.</summary>
public sealed record WavChunkPlan(WavFormat Format, IReadOnlyList<WavChunk> Chunks);

/// <summary>
/// Audio bytes that the plan's chunk offsets refer to (original WAV, or decoded PCM). Holds the audio
/// memory budget lease; dispose it once the transcription has finished with the bytes.
/// </summary>
public sealed class AudioChunkSource(byte[] bytes, WavChunkPlan plan, IDisposable? lease) : IDisposable
{
    public byte[] Bytes { get; } = bytes;
    public WavChunkPlan Plan { get; } = plan;

    public void Dispose() => lease?.Dispose();
}

/// <summary>Limits applied while preparing uploaded audio.</summary>
public sealed record AudioLimits(int MaxAudioSeconds, AudioMemoryBudget Budget, WavChunkerOptions? Chunking = null)
{
    public const int MinConfigurableSeconds = 1;
    public const int MaxConfigurableSeconds = 36_000;

    public static int ClampSeconds(int seconds) => Math.Clamp(seconds, MinConfigurableSeconds, MaxConfigurableSeconds);
}
