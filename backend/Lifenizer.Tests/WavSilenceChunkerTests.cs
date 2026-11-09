using Lifenizer.Api.Services;

namespace Lifenizer.Tests;

public sealed class WavSilenceChunkerTests
{
    private static readonly TimeSpan MaxChunk = WavSilenceChunker.DefaultOptions.MaxChunk;
    private const double FrameSeconds = 0.03;

    [Test]
    public void ShortPauses_DoNotCut_ASpeechRecordingStaysOneChunk()
    {
        // 4 s speech / 1 s silence over 2 min used to produce ~10 chunks.
        var wav = SyntheticWav.Build(120, SyntheticWav.SentencePattern);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(1));
        Assert.That(plan.Chunks[0].Start, Is.EqualTo(TimeSpan.Zero));
        Assert.That(plan.Chunks[0].ByteLength, Is.EqualTo(120 * SyntheticWav.Rate * 2));
    }

    [Test]
    public void TwoToFourSecondPauses_DoNotCut()
    {
        var wav = SyntheticWav.Build(120, t => t % 12 < 8 || (t % 12 >= 10 && t % 12 < 11));

        Assert.That(WavSilenceChunker.TryPlan(wav)!.Chunks, Has.Count.EqualTo(1));
    }

    [Test]
    public void LongPause_CutsTheRecording_AndIsDropped()
    {
        // speech 0-20, pause 20-32 (12 s), speech 32-60
        var wav = SyntheticWav.Build(60, t => t < 20 || t >= 32);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(2));
        Assert.That(plan.Chunks[0].Start, Is.EqualTo(TimeSpan.Zero));
        Assert.That(End(plan.Chunks[0]), Is.EqualTo(20.5).Within(FrameSeconds));
        Assert.That(plan.Chunks[1].Start.TotalSeconds, Is.EqualTo(31.5).Within(FrameSeconds));
        Assert.That(End(plan.Chunks[1]), Is.EqualTo(60).Within(FrameSeconds));
        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.LessThan(60 * SyntheticWav.Rate * 2 - 10 * SyntheticWav.Rate * 2));
    }

    [Test]
    public void ChunkOffset_MatchesTheByteOffsetInTheSource()
    {
        var wav = SyntheticWav.Build(60, t => t < 20 || t >= 32);
        var layout = WavSilenceChunker.ParseLayout(wav)!;

        var chunk = WavSilenceChunker.TryPlan(wav)!.Chunks[1];

        var expectedSeconds = (double)(chunk.ByteOffset - layout.DataOffset) / 2 / SyntheticWav.Rate;
        Assert.That(chunk.Start.TotalSeconds, Is.EqualTo(expectedSeconds).Within(1e-9));
    }

    [Test]
    public void PauseBelowMinimum_IsNotCut()
    {
        var wav = SyntheticWav.Build(60, t => t < 20 || t >= 29);

        Assert.That(WavSilenceChunker.TryPlan(wav)!.Chunks, Has.Count.EqualTo(1));
    }

    [Test]
    public void ClickInsideAPause_DoesNotBreakIt()
    {
        var wav = SyntheticWav.Build(60, t => t < 20 || t >= 32 || (t >= 26 && t < 26.1));

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(2));
        Assert.That(End(plan.Chunks[0]), Is.EqualTo(20.5).Within(FrameSeconds));
    }

    [Test]
    public void LowSnrSyllabicSpeech_IsNotMistakenForAPause()
    {
        // 4 Hz syllable envelope over room noise: every syllable dip is a short "silent" run followed by a blip.
        var wav = SyntheticWav.BuildShaped(60, t => 4000 * Math.Pow(Math.Abs(Math.Sin(4 * Math.PI * t)), 3), noiseRms: 150);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(60 * SyntheticWav.Rate * 2));
        var oldBridging = new WavChunkerOptions { MinSilenceBeforeBlip = TimeSpan.Zero };
        Assert.That(WavSilenceChunker.TryPlan(wav, oldBridging)!.Chunks.Sum(c => c.ByteLength), Is.LessThan(60 * SyntheticWav.Rate), "without the guard the speech is dropped");
    }

    [Test]
    public void SparseSpeechInAHalfHourRecording_SendsOnlyASmallFraction()
    {
        // six 2 s utterances, one every 5 min, in room noise
        var wav = SyntheticWav.BuildShaped(1800, t => t % 300 >= 100 && t % 300 < 102 ? 8000 : 0, noiseRms: 100);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(6));
        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.LessThan(1800 * SyntheticWav.Rate * 2 / 20));
    }

    [Test]
    public void QuietSpeechWithLoudTransients_IsKept()
    {
        var wav = SyntheticWav.BuildShaped(120, t => (t >= 30 && t < 31) || (t >= 90 && t < 91) ? 20000 : 600);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(120 * SyntheticWav.Rate * 2));
    }

    [Test]
    public void OneWordAnswersBetweenLongPauses_AreKept()
    {
        // 0.4 s "Ja" every 30 s
        var wav = SyntheticWav.Build(100, t => t % 30 >= 10 && t % 30 < 10.4);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(3));
    }

    [Test]
    public void ShortWordAfterLongSilenceFollowedByShortGap_IsNotSwallowed()
    {
        // 20 s silence, 0.25 s "Hey", gap, speech from 22 s
        foreach (var gap in new[] { 0.5, 0.8 })
        {
            var speechStart = 20.25 + gap;
            var wav = SyntheticWav.Build(60, t => (t >= 20 && t < 20.25) || t >= speechStart);

            var plan = WavSilenceChunker.TryPlan(wav)!;

            Assert.That(plan.Chunks, Has.Count.EqualTo(1), $"gap {gap}");
            Assert.That(plan.Chunks[0].Start.TotalSeconds, Is.LessThanOrEqualTo(20).Within(FrameSeconds), $"gap {gap}: word inside the chunk");
        }
    }

    [Test]
    public void ConversationWithPausesInLoudRoom_IsCutAtThePauses()
    {
        // 4 s speech / 12 s pause in room noise RMS 350
        var wav = SyntheticWav.BuildShaped(80, t => t % 16 < 4 ? 6000 : 0, noiseRms: 350);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(5));
        Assert.That(plan.Chunks.All(c => ChunkLength(c).TotalSeconds < 6), Is.True);
    }

    [Test]
    public void SpeechInsideAPause_SplitsItIntoTwoShortPauses()
    {
        var wav = SyntheticWav.Build(60, t => t < 20 || t >= 32 || (t >= 26 && t < 27));

        Assert.That(WavSilenceChunker.TryPlan(wav)!.Chunks, Has.Count.EqualTo(1));
    }

    [Test]
    public void LeadingAndTrailingSilence_IsTrimmed()
    {
        var wav = SyntheticWav.Build(80, t => t >= 20 && t < 60);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(1));
        Assert.That(plan.Chunks[0].Start.TotalSeconds, Is.EqualTo(19.5).Within(FrameSeconds));
        Assert.That(End(plan.Chunks[0]), Is.EqualTo(60.5).Within(FrameSeconds));
    }

    [Test]
    public void ContinuousSpeechWithShortGaps_IsCappedAtMaxChunk_CuttingInsideGaps()
    {
        var wav = SyntheticWav.Build(12 * 60, SyntheticWav.SentencePattern);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.GreaterThanOrEqualTo(3));
        Assert.That(plan.Chunks.All(c => ChunkLength(c) <= MaxChunk + WavSilenceChunker.DefaultOptions.MinTrailingChunk), Is.True);
        foreach (var chunk in plan.Chunks.Skip(1))
        {
            Assert.That(SyntheticWav.SentencePattern(chunk.Start.TotalSeconds), Is.False, $"cut at {chunk.Start} is inside speech");
        }
        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(12 * 60 * SyntheticWav.Rate * 2));
    }

    [Test]
    public void Chunks_NeverExceedMaxChunk_EvenWithoutSilence()
    {
        var wav = SyntheticWav.Build(100, _ => true);
        var options = new WavChunkerOptions { MaxChunk = TimeSpan.FromSeconds(30), CapSearchWindow = TimeSpan.FromSeconds(10) };

        var plan = WavSilenceChunker.TryPlan(wav, options)!;

        Assert.That(plan.Chunks.Count, Is.GreaterThan(2));
        Assert.That(plan.Chunks.All(c => ChunkLength(c) <= options.MaxChunk + options.MinTrailingChunk), Is.True);
        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(100 * SyntheticWav.Rate * 2));
    }

    [Test]
    public void ShortTrailingPieceOfACapSplit_IsMergedIntoItsPredecessor()
    {
        // brief gaps at 30 s and 60 s: the cuts land there, leaving a 1 s remainder that is merged back
        var wav = SyntheticWav.Build(61, t => !(t >= 29.9 && t < 30.1) && !(t >= 59.9 && t < 60.1));
        var options = new WavChunkerOptions { MaxChunk = TimeSpan.FromSeconds(30), CapSearchWindow = TimeSpan.FromSeconds(10) };

        var plan = WavSilenceChunker.TryPlan(wav, options)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(2));
        Assert.That(plan.Chunks[1].Start.TotalSeconds, Is.EqualTo(30).Within(0.15));
        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(61 * SyntheticWav.Rate * 2));
    }

    [Test]
    public void ChunksThatAreEntirelySilent_AreDropped()
    {
        var wav = SyntheticWav.Build(120, t => t < 20 || t >= 100);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        var total = 120 * SyntheticWav.Rate * 2;
        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.LessThan(total - 40 * SyntheticWav.Rate * 2));
        foreach (var chunk in plan.Chunks)
        {
            var pcm = wav.AsSpan(chunk.ByteOffset, chunk.ByteLength);
            Assert.That(pcm.ContainsAnyExcept((byte)0), Is.True, $"chunk at {chunk.Start} is silent");
        }
    }

    [Test]
    public void FullySilentRecording_IsChunkableButHasNoChunks()
    {
        var plan = WavSilenceChunker.TryPlan(SyntheticWav.Build(90, _ => false));

        Assert.That(plan, Is.Not.Null);
        Assert.That(plan!.Chunks, Is.Empty);
    }

    [Test]
    public void QuietSpeechInNoisyRecording_IsNotDropped()
    {
        // Noise floor high enough that the adaptive threshold hits its cap; quiet "speech" stays above MinSilenceRms.
        var wav = SyntheticWav.Build(90, _ => true, amplitude: 400);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(90 * SyntheticWav.Rate * 2));
    }

    [Test]
    public void InvalidOptions_AreRejected()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.SentencePattern);
        var bad = new WavChunkerOptions { MaxChunk = TimeSpan.FromSeconds(30), CapSearchWindow = TimeSpan.FromSeconds(30) };

        Assert.Throws<ArgumentException>(() => WavSilenceChunker.TryPlan(wav, bad));
        Assert.Throws<ArgumentException>(() => WavSilenceChunker.TryPlan(wav, new WavChunkerOptions { MinPause = TimeSpan.Zero }));
        Assert.Throws<ArgumentException>(() => WavSilenceChunker.TryPlan(wav, new WavChunkerOptions { PausePadding = TimeSpan.FromSeconds(6) }));
        Assert.Throws<ArgumentException>(() => WavSilenceChunker.TryPlan(wav, new WavChunkerOptions { CapSearchWindow = TimeSpan.Zero }));
    }

    [Test]
    public void ExtensibleFormat_IsParsed()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.SentencePattern, extensible: true);

        Assert.That(WavSilenceChunker.TryPlan(wav), Is.Not.Null);
    }

    [TestCase(0u)]
    [TestCase(uint.MaxValue)]
    [TestCase(2_000_000_000u)]
    public void StreamedOrOversizedDataLength_UsesRestOfFile(uint declared)
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.SentencePattern);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(wav.AsSpan(40), declared);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(60 * SyntheticWav.Rate * 2));
    }

    [Test]
    public void OddDataLength_IsTruncatedToWholeSamples()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.SentencePattern).Append((byte)7).ToArray();
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(wav.AsSpan(40), (uint)(60 * SyntheticWav.Rate * 2 + 1));

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(60 * SyntheticWav.Rate * 2));
    }

    [Test]
    public void FormatChunkAfterData_IsParsed()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.SentencePattern, fmtAfterData: true);

        var plan = WavSilenceChunker.TryPlan(wav);

        Assert.That(plan, Is.Not.Null);
        Assert.That(plan!.Chunks.Sum(c => c.ByteLength), Is.EqualTo(60 * SyntheticWav.Rate * 2));
    }

    [Test]
    public void ShortRecording_IsNotChunked()
    {
        Assert.That(WavSilenceChunker.TryPlan(SyntheticWav.Build(30, SyntheticWav.SentencePattern)), Is.Null);
    }

    [Test]
    public void ExtraChunkBeforeData_IsParsed()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.SentencePattern, listChunkFirst: true);

        var plan = WavSilenceChunker.TryPlan(wav);

        Assert.That(plan, Is.Not.Null);
        Assert.That(plan!.Chunks.Sum(c => c.ByteLength), Is.EqualTo(60 * SyntheticWav.Rate * 2));
    }

    [Test]
    public void Stereo_IsChunkedOnBlockBoundaries()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.PausedPattern, channels: 2);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Format.Channels, Is.EqualTo(2));
        Assert.That(plan.Chunks.All(c => c.ByteLength % 4 == 0), Is.True);
        Assert.That(plan.Chunks, Has.Count.EqualTo(4));
        Assert.That(SyntheticWav.PausedPattern(plan.Chunks[1].Start.TotalSeconds), Is.False);
    }

    [Test]
    public void ToWav_ProducesStandaloneWavThatParsesAsExpected()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        var chunk = plan.Chunks[0];

        var piece = WavSilenceChunker.ToWav(wav, plan.Format, chunk);

        Assert.That(piece.Length, Is.EqualTo(44 + chunk.ByteLength));
        Assert.That(piece.AsSpan(44).SequenceEqual(wav.AsSpan(chunk.ByteOffset, chunk.ByteLength)), Is.True);
        Assert.That(WavSilenceChunker.TryPlan(piece), Is.Null, "a short piece is valid but not chunkable again");
    }

    [Test]
    public void NonPcm16OrGarbageInput_IsNotChunkable()
    {
        var data = new byte[60 * SyntheticWav.Rate * 2];
        Assert.Multiple(() =>
        {
            Assert.That(WavSilenceChunker.TryPlan(SyntheticWav.Wrap(data, 1, false, formatTag: 3)), Is.Null, "float");
            Assert.That(WavSilenceChunker.TryPlan(SyntheticWav.Wrap(data, 1, false, bits: 8)), Is.Null, "8-bit");
            Assert.That(WavSilenceChunker.TryPlan(SyntheticWav.Wrap(data, 6, false)), Is.Null, "6 channels");
            Assert.That(WavSilenceChunker.TryPlan("ID3"u8.ToArray().Concat(data).ToArray()), Is.Null, "mp3");
            Assert.That(WavSilenceChunker.TryPlan([]), Is.Null, "empty");
            Assert.That(WavSilenceChunker.TryPlan(SyntheticWav.Wrap(data, 1, false)[..30]), Is.Null, "truncated header");
            Assert.That(WavSilenceChunker.TryPlan(new byte[1000]), Is.Null, "zeros");
        });
    }

    private static double End(WavChunk chunk) => chunk.Start.TotalSeconds + ChunkLength(chunk).TotalSeconds;

    private static TimeSpan ChunkLength(WavChunk chunk) => TimeSpan.FromSeconds((double)chunk.ByteLength / 2 / SyntheticWav.Rate);
}
