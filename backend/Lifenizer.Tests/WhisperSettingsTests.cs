using Lifenizer.Api.Services;
using Microsoft.Extensions.Configuration;

namespace Lifenizer.Tests;

public sealed class WhisperSettingsTests
{
    private static IConfiguration Config(params (string Key, string Value)[] values) =>
        new ConfigurationBuilder().AddInMemoryCollection(values.ToDictionary(v => v.Key, v => (string?)v.Value)).Build();

    [TestCase("NaN")]
    [TestCase("Infinity")]
    [TestCase("-Infinity")]
    [TestCase("abc")]
    public void NonFiniteValues_FallBackToDefaults(string value)
    {
        var config = Config(("Whisper:MinPauseSeconds", value), ("Whisper:MaxChunkSeconds", value), ("Whisper:ChunkTimeoutSeconds", value),
            ("Whisper:ChunkTimeoutPerAudioSecond", value), ("Whisper:WholeFileTimeoutSeconds", value));

        var options = WhisperSettings.ChunkerOptions(config);

        Assert.Multiple(() =>
        {
            Assert.That(options.MinPause, Is.EqualTo(WavSilenceChunker.DefaultOptions.MinPause));
            Assert.That(options.MaxChunk, Is.EqualTo(WavSilenceChunker.DefaultOptions.MaxChunk));
            Assert.That(WhisperSettings.ChunkTimeout(config), Is.EqualTo(TimeSpan.FromSeconds(180)));
            Assert.That(WhisperSettings.TimeoutPerAudioSecond(config), Is.EqualTo(2.0));
            Assert.That(WhisperSettings.WholeFileTimeout(config), Is.EqualTo(TimeSpan.FromSeconds(600)));
        });
        options.Validate();
    }

    [Test]
    public void ExtremeValues_AreClamped()
    {
        var low = Config(("Whisper:MinPauseSeconds", "0"), ("Whisper:MaxChunkSeconds", "10"), ("Whisper:ChunkTimeoutSeconds", "-5"), ("Whisper:ChunkTimeoutPerAudioSecond", "-1"));
        var high = Config(("Whisper:MinPauseSeconds", "1e9"), ("Whisper:MaxChunkSeconds", "1e9"), ("Whisper:ChunkTimeoutSeconds", "1e12"), ("Whisper:ChunkTimeoutPerAudioSecond", "1e9"));

        Assert.Multiple(() =>
        {
            Assert.That(WhisperSettings.ChunkerOptions(low).MinPause, Is.EqualTo(TimeSpan.FromSeconds(2)));
            Assert.That(WhisperSettings.ChunkerOptions(low).MaxChunk, Is.EqualTo(TimeSpan.FromSeconds(90)));
            Assert.That(WhisperSettings.ChunkTimeout(low), Is.EqualTo(TimeSpan.FromSeconds(1)));
            Assert.That(WhisperSettings.TimeoutPerAudioSecond(low), Is.EqualTo(0));
            Assert.That(WhisperSettings.ChunkerOptions(high).MinPause, Is.EqualTo(TimeSpan.FromHours(1)));
            Assert.That(WhisperSettings.ChunkerOptions(high).MaxChunk, Is.EqualTo(TimeSpan.FromHours(1)));
            Assert.That(WhisperSettings.ChunkTimeout(high), Is.EqualTo(TimeSpan.FromHours(6)));
            Assert.That(WhisperSettings.TimeoutPerAudioSecond(high), Is.EqualTo(20));
        });
        WhisperSettings.ChunkerOptions(low).Validate();
        WhisperSettings.ChunkerOptions(high).Validate();
    }

    [Test]
    public void ConfiguredPauseAndMaxChunk_ReachThePlanner()
    {
        var pause12 = SyntheticWav.Build(60, t => t < 20 || t >= 32);
        var continuous = SyntheticWav.Build(400, _ => true);

        var longerPause = WhisperSettings.ChunkerOptions(Config(("Whisper:MinPauseSeconds", "20")));
        var shortCap = WhisperSettings.ChunkerOptions(Config(("Whisper:MaxChunkSeconds", "100")));
        var floored = WhisperSettings.ChunkerOptions(Config(("Whisper:MaxChunkSeconds", "5")));

        Assert.Multiple(() =>
        {
            Assert.That(WavSilenceChunker.TryPlan(pause12)!.Chunks, Has.Count.EqualTo(2));
            Assert.That(WavSilenceChunker.TryPlan(pause12, longerPause)!.Chunks, Has.Count.EqualTo(1));
            Assert.That(WavSilenceChunker.TryPlan(continuous, shortCap)!.Chunks.Count, Is.GreaterThanOrEqualTo(4));
            Assert.That(WavSilenceChunker.TryPlan(continuous, floored)!.Chunks.All(c => c.ByteLength <= 92 * SyntheticWav.Rate * 2), Is.True, "floored to 90 s, valid options");
        });
    }

    [Test]
    public void ChunkedTranscriber_AcceptsNonFiniteFactor()
    {
        Assert.DoesNotThrow(() => new ChunkedWhisperTranscriber(Microsoft.Extensions.Logging.Abstractions.NullLogger<ChunkedWhisperTranscriber>.Instance, 4, TimeSpan.FromSeconds(180), double.PositiveInfinity).Dispose());
    }
}
