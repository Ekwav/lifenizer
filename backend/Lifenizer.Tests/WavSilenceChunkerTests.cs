using Lifenizer.Api.Services;

namespace Lifenizer.Tests;

public sealed class WavSilenceChunkerTests
{
    private static readonly TimeSpan MaxChunk = WavSilenceChunker.DefaultOptions.MaxChunkLength;

    [Test]
    public void Chunks_CutInsideSilences_AndCoverTheAudio()
    {
        var wav = SyntheticWav.Build(120, SyntheticWav.SentencePattern);

        var plan = WavSilenceChunker.TryPlan(wav);

        Assert.That(plan, Is.Not.Null);
        Assert.That(plan!.Chunks.Count, Is.GreaterThan(5));
        foreach (var chunk in plan.Chunks.Skip(1))
        {
            Assert.That(SyntheticWav.SentencePattern(chunk.Start.TotalSeconds), Is.False, $"cut at {chunk.Start} is inside speech");
        }
        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(120 * SyntheticWav.Rate * 2));
    }

    [Test]
    public void Chunks_NeverExceedSearchEndPlusTrailing_EvenWithoutSilence()
    {
        var wav = SyntheticWav.Build(100, _ => true);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks.Count, Is.GreaterThan(3));
        Assert.That(plan.Chunks.All(c => ChunkLength(c) <= MaxChunk), Is.True);
        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(100 * SyntheticWav.Rate * 2));
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
        var bad = new WavChunkerOptions { SearchEnd = TimeSpan.FromSeconds(5) };

        Assert.Throws<ArgumentException>(() => WavSilenceChunker.TryPlan(wav, bad));
        Assert.Throws<ArgumentException>(() => WavSilenceChunker.TryPlan(wav, new WavChunkerOptions { MinChunk = TimeSpan.Zero }));
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
        var wav = SyntheticWav.Build(60, SyntheticWav.SentencePattern, channels: 2);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Format.Channels, Is.EqualTo(2));
        Assert.That(plan.Chunks.All(c => c.ByteLength % 4 == 0), Is.True);
        Assert.That(SyntheticWav.SentencePattern(plan.Chunks[1].Start.TotalSeconds), Is.False);
    }

    [Test]
    public void ToWav_ProducesStandaloneWavThatParsesAsExpected()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.SentencePattern);
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

    private static TimeSpan ChunkLength(WavChunk chunk) => TimeSpan.FromSeconds((double)chunk.ByteLength / 2 / SyntheticWav.Rate);
}
