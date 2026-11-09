using System.Globalization;

namespace Lifenizer.Api.Services;

/// <summary>Reads the whisper tuning keys; malformed, non-finite or absurd values are clamped, never thrown.</summary>
public static class WhisperSettings
{
    public const double DefaultChunkTimeoutSeconds = 180;
    public const double DefaultTimeoutPerAudioSecond = 2.0;
    public const double DefaultWholeFileTimeoutSeconds = 600;
    public const double MaxTimeoutSeconds = 6 * 3600;

    public static TimeSpan ChunkTimeout(IConfiguration configuration) =>
        Seconds(configuration, "Whisper:ChunkTimeoutSeconds", DefaultChunkTimeoutSeconds, 1, MaxTimeoutSeconds);

    public static TimeSpan WholeFileTimeout(IConfiguration configuration) =>
        Seconds(configuration, "Whisper:WholeFileTimeoutSeconds", DefaultWholeFileTimeoutSeconds, 0.1, MaxTimeoutSeconds);

    public static double TimeoutPerAudioSecond(IConfiguration configuration) =>
        Number(configuration, "Whisper:ChunkTimeoutPerAudioSecond", DefaultTimeoutPerAudioSecond, 0, 20);

    public static WavChunkerOptions ChunkerOptions(IConfiguration configuration)
    {
        var defaults = WavSilenceChunker.DefaultOptions;
        return defaults with
        {
            MinPause = Seconds(configuration, "Whisper:MinPauseSeconds", defaults.MinPause.TotalSeconds, 2, 3600),
            MaxChunk = Seconds(configuration, "Whisper:MaxChunkSeconds", defaults.MaxChunk.TotalSeconds, 90, 3600)
        };
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
