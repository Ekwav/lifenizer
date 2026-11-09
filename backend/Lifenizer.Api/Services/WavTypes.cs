namespace Lifenizer.Api.Services;

/// <summary>Tunable parameters for <see cref="WavSilenceChunker"/>.</summary>
public sealed record WavChunkerOptions
{
    public TimeSpan Frame { get; init; } = TimeSpan.FromMilliseconds(30);
    /// <summary>Earliest cut, measured from a chunk's start.</summary>
    public TimeSpan MinChunk { get; init; } = TimeSpan.FromSeconds(7);
    /// <summary>Latest cut, measured from a chunk's start. Chunks are normally at most this long.</summary>
    public TimeSpan SearchEnd { get; init; } = TimeSpan.FromSeconds(15);
    /// <summary>A shorter final chunk is merged into its predecessor.</summary>
    public TimeSpan MinTrailingChunk { get; init; } = TimeSpan.FromSeconds(2);
    /// <summary>Recordings up to this length are not chunked.</summary>
    public TimeSpan NoChunkUpTo { get; init; } = TimeSpan.FromSeconds(30);
    public double NoiseFloorPercentile { get; init; } = 0.10;
    public double NoiseFloorFactor { get; init; } = 3.0;
    /// <summary>Lower bound of the adaptive cut threshold; also the level below which a chunk counts as silent.</summary>
    public double MinSilenceRms { get; init; } = 120;
    public double MaxSilenceRms { get; init; } = 1500;

    /// <summary>The real upper bound of a chunk (whisper's window is 30 s).</summary>
    public TimeSpan MaxChunkLength => SearchEnd + MinTrailingChunk;

    public void Validate()
    {
        if (Frame <= TimeSpan.Zero) throw new ArgumentException("Frame must be positive.", nameof(Frame));
        if (MinChunk <= TimeSpan.Zero) throw new ArgumentException("MinChunk must be positive.", nameof(MinChunk));
        if (SearchEnd <= MinChunk) throw new ArgumentException("SearchEnd must be after MinChunk.", nameof(SearchEnd));
        if (MinChunk < Frame) throw new ArgumentException("MinChunk must span at least one frame.", nameof(MinChunk));
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
public sealed record AudioLimits(int MaxAudioSeconds, AudioMemoryBudget Budget)
{
    public const int MinConfigurableSeconds = 1;
    public const int MaxConfigurableSeconds = 36_000;

    public static int ClampSeconds(int seconds) => Math.Clamp(seconds, MinConfigurableSeconds, MaxConfigurableSeconds);
}
