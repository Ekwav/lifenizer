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
        var low = Config(("Whisper:MinPauseSeconds", "0"), ("Whisper:MaxChunkSeconds", "1"), ("Whisper:ChunkTimeoutSeconds", "-5"), ("Whisper:ChunkTimeoutPerAudioSecond", "-1"));
        var high = Config(("Whisper:MinPauseSeconds", "1e9"), ("Whisper:MaxChunkSeconds", "1e9"), ("Whisper:ChunkTimeoutSeconds", "1e12"), ("Whisper:ChunkTimeoutPerAudioSecond", "1e9"));

        Assert.Multiple(() =>
        {
            Assert.That(WhisperSettings.ChunkerOptions(low).MinPause, Is.EqualTo(TimeSpan.FromSeconds(2)));
            Assert.That(WhisperSettings.ChunkerOptions(low).MaxChunk, Is.EqualTo(TimeSpan.FromSeconds(10)));
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
        var pause12 = SyntheticWav.Build(58, t => t < 20 || t >= 32);
        var continuous = SyntheticWav.Build(400, _ => true);

        var longerPause = WhisperSettings.ChunkerOptions(Config(("Whisper:MinPauseSeconds", "20")));
        var shortCap = WhisperSettings.ChunkerOptions(Config(("Whisper:MaxChunkSeconds", "100")));
        var floored = WhisperSettings.ChunkerOptions(Config(("Whisper:MaxChunkSeconds", "5")));
        var raised = WhisperSettings.ChunkerOptions(Config(("Whisper:MaxChunkSeconds", "300")));

        Assert.Multiple(() =>
        {
            Assert.That(WavSilenceChunker.TryPlan(pause12)!.Chunks, Has.Count.EqualTo(2));
            Assert.That(WavSilenceChunker.TryPlan(pause12, longerPause)!.Chunks.Sum(c => c.ByteLength), Is.EqualTo(58 * SyntheticWav.Rate * 2), "the 12 s pause is kept, only cap cuts");
            Assert.That(WavSilenceChunker.TryPlan(continuous, shortCap)!.Chunks.Count, Is.GreaterThanOrEqualTo(4));
            Assert.That(WavSilenceChunker.TryPlan(continuous, floored)!.Chunks.All(c => c.ByteLength <= 10 * SyntheticWav.Rate * 2), Is.True, "floored to 10 s, valid options");
            Assert.That(WavSilenceChunker.TryPlan(continuous, raised)!.Chunks, Has.Count.EqualTo(2), "a longer cap can still be configured");
        });
    }

    [Test]
    public void DefaultMaxChunk_Is28Seconds_InCodeAndInAppSettings()
    {
        var appSettings = new ConfigurationBuilder().AddJsonFile(AppSettingsPath()).Build();

        Assert.Multiple(() =>
        {
            Assert.That(WhisperSettings.ChunkerOptions(Config()).MaxChunk, Is.EqualTo(TimeSpan.FromSeconds(28)));
            Assert.That(appSettings["Whisper:MaxChunkSeconds"], Is.EqualTo("28"));
            Assert.That(WhisperSettings.ChunkerOptions(appSettings).MaxChunk, Is.EqualTo(TimeSpan.FromSeconds(28)));
        });
    }

    [TestCase("28", 28)]
    [TestCase("15", 15)]
    [TestCase("12.5", 12.5)]
    public void ConfiguredMaxChunk_IsHonored_AndEveryChunkFitsIt(string value, double expected)
    {
        var options = WhisperSettings.ChunkerOptions(Config(("Whisper:MaxChunkSeconds", value)));
        var continuous = SyntheticWav.Build(120, _ => true);
        var talk = SyntheticWav.Build(120, SyntheticWav.Sentences(120, seed: 5));

        Assert.That(options.MaxChunk, Is.EqualTo(TimeSpan.FromSeconds(expected)));
        Assert.That(options.CapSearchWindow, Is.LessThanOrEqualTo(options.MaxChunk / 2), "search window scaled to the cap");
        Assert.That(options.NoChunkUpTo, Is.LessThanOrEqualTo(options.MaxChunk), "a whole-file send fits the cap");
        foreach (var wav in new[] { continuous, talk })
        {
            var plan = WavSilenceChunker.TryPlan(wav, options)!;
            Assert.That(plan.Chunks.All(c => c.ByteLength <= expected * SyntheticWav.Rate * 2), Is.True);
            Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(120 * SyntheticWav.Rate * 2), "no audio lost at cap cuts");
        }
    }

    [TestCase("0", 10)]
    [TestCase("-28", 10)]
    [TestCase("9.99", 10)]
    [TestCase("1e9", 3600)]
    [TestCase("28,5", 28)]
    [TestCase("", 28)]
    public void InvalidOrOutOfRangeMaxChunk_ClampsToAValidConfig(string value, double expected)
    {
        var options = WhisperSettings.ChunkerOptions(Config(("Whisper:MaxChunkSeconds", value)));

        Assert.That(() => options.Validate(), Throws.Nothing);
        Assert.That(options.MaxChunk, Is.EqualTo(TimeSpan.FromSeconds(expected)));
        Assert.That(options.CapSearchWindow, Is.LessThan(options.MaxChunk));
    }

    [TestCase("28", false)]
    [TestCase("30", false)]
    [TestCase("31", true)]
    [TestCase("300", true)]
    public void MaxChunkAboveTheWhisperWindow_LogsAStartupWarning(string value, bool warns)
    {
        var logger = new ListLogger<WhisperSettingsTests>();

        WhisperSettings.WarnIfChunksExceedWhisperWindow(Config(("Whisper:MaxChunkSeconds", value)), logger);

        var warnings = logger.Entries.Where(e => e.Level == Microsoft.Extensions.Logging.LogLevel.Warning).ToList();
        Assert.That(warnings, Has.Count.EqualTo(warns ? 1 : 0));
        if (warns) Assert.That(warnings[0].Message, Does.Contain("Whisper:MaxChunkSeconds").And.Contain("30 s decoding window"));
    }

    private static string AppSettingsPath()
    {
        var directory = new DirectoryInfo(TestContext.CurrentContext.TestDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "Lifenizer.Api", "appsettings.json"))) directory = directory.Parent;
        return Path.Combine(directory?.FullName ?? throw new FileNotFoundException("Lifenizer.Api/appsettings.json not found"), "Lifenizer.Api", "appsettings.json");
    }

    [Test]
    public void ChunkedTranscriber_AcceptsNonFiniteFactor()
    {
        Assert.DoesNotThrow(() => new ChunkedWhisperTranscriber(Microsoft.Extensions.Logging.Abstractions.NullLogger<ChunkedWhisperTranscriber>.Instance, 4, TimeSpan.FromSeconds(180), double.PositiveInfinity).Dispose());
    }
}
