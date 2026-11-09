using System.Globalization;

namespace Lifenizer.Api.Services;

/// <summary>Reads the whisper tuning keys; malformed, non-finite or absurd values are clamped, never thrown.</summary>
public static class WhisperSettings
{
    public const double DefaultChunkTimeoutSeconds = 180;
    public const double DefaultTimeoutPerAudioSecond = 2.0;
    public const double DefaultWholeFileTimeoutSeconds = 600;
    public const double MaxTimeoutSeconds = 6 * 3600;
    /// <summary>Accepted range of Whisper:MaxChunkSeconds (the trained whisper needs at most 30).</summary>
    public const double MinMaxChunkSeconds = 10;
    public const double MaxMaxChunkSeconds = 3600;
    /// <summary>The trained whisper decodes in windows of this length and drops the text past it.</summary>
    public static readonly TimeSpan WhisperWindow = TimeSpan.FromSeconds(30);

    public static TimeSpan ChunkTimeout(IConfiguration configuration) =>
        Seconds(configuration, "Whisper:ChunkTimeoutSeconds", DefaultChunkTimeoutSeconds, 1, MaxTimeoutSeconds);

    public static TimeSpan WholeFileTimeout(IConfiguration configuration) =>
        Seconds(configuration, "Whisper:WholeFileTimeoutSeconds", DefaultWholeFileTimeoutSeconds, 0.1, MaxTimeoutSeconds);

    public static double TimeoutPerAudioSecond(IConfiguration configuration) =>
        Number(configuration, "Whisper:ChunkTimeoutPerAudioSecond", DefaultTimeoutPerAudioSecond, 0, 20);

    /// <summary>Chunker options with the configured pause and cap; the cap search window is derived from the cap so the result always validates.</summary>
    public static WavChunkerOptions ChunkerOptions(IConfiguration configuration)
    {
        var defaults = WavSilenceChunker.DefaultOptions;
        var maxChunk = Seconds(configuration, "Whisper:MaxChunkSeconds", defaults.MaxChunk.TotalSeconds, MinMaxChunkSeconds, MaxMaxChunkSeconds);
        return defaults.WithMaxChunk(maxChunk) with
        {
            MinPause = Seconds(configuration, "Whisper:MinPauseSeconds", defaults.MinPause.TotalSeconds, 2, 3600)
        };
    }

    /// <summary>Warns when a configured cap lets one request outgrow the trained whisper's 30 s decoding window.</summary>
    public static void WarnIfChunksExceedWhisperWindow(IConfiguration configuration, ILogger logger)
    {
        var maxChunk = ChunkerOptions(configuration).MaxChunk;
        if (maxChunk <= WhisperWindow) return;
        logger.LogWarning(
            "Whisper:MaxChunkSeconds is {MaxChunkSeconds} s, above the {WindowSeconds} s decoding window: the trained whisper model drops the text " +
            "at the end of each window for longer requests (word recall fell to 60-72%). Keep it at 28 unless the whisper model handles long audio",
            maxChunk.TotalSeconds, WhisperWindow.TotalSeconds);
    }

    private static TimeSpan Seconds(IConfiguration configuration, string key, double fallback, double min, double max) =>
        TimeSpan.FromSeconds(Number(configuration, key, fallback, min, max));

    private static double Number(IConfiguration configuration, string key, double fallback, double min, double max)
    {
        var raw = configuration[key];
        var parsed = double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var value);
        return parsed && double.IsFinite(value) ? Math.Clamp(value, min, max) : fallback;
    }
}
