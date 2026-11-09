using Lifenizer.Api.Services;

namespace Lifenizer.Tests;

public sealed class WavSilenceChunkerTests
{
    private static readonly TimeSpan MaxChunk = WavSilenceChunker.DefaultOptions.MaxChunk;
    private static readonly TimeSpan WhisperWindow = TimeSpan.FromSeconds(30);
    /// <summary>Default options without the 28 s cap, to look at the pause rules alone.</summary>
    private static readonly WavChunkerOptions NoCap = WavSilenceChunker.DefaultOptions.WithMaxChunk(TimeSpan.FromHours(1));
    private const double FrameSeconds = 0.03;

    [Test]
    public void ShortPauses_DoNotCut_ASpeechRecordingIsOnlySplitByTheCap()
    {
        // 4 s speech / 1 s silence over 2 min used to produce ~10 chunks.
        var wav = SyntheticWav.Build(120, SyntheticWav.SentencePattern);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(WavSilenceChunker.TryPlan(wav, NoCap)!.Chunks, Has.Count.EqualTo(1), "no pause cut");
        Assert.That(plan.Chunks[0].Start, Is.EqualTo(TimeSpan.Zero));
        AssertContiguousCover(wav, plan);
        AssertWhisperSized(plan);
    }

    [Test]
    public void TwoToFourSecondPauses_DoNotCut()
    {
        var wav = SyntheticWav.Build(120, t => t % 12 < 8 || (t % 12 >= 10 && t % 12 < 11));

        Assert.That(WavSilenceChunker.TryPlan(wav, NoCap)!.Chunks, Has.Count.EqualTo(1));
        AssertContiguousCover(wav, WavSilenceChunker.TryPlan(wav)!);
    }

    [Test]
    public void LongPause_CutsTheRecording_AndIsDropped()
    {
        // speech 0-20, pause 20-32 (12 s), speech 32-58 (both sides below the 28 s cap)
        var wav = SyntheticWav.Build(58, t => t < 20 || t >= 32);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(2));
        Assert.That(plan.Chunks[0].Start, Is.EqualTo(TimeSpan.Zero));
        Assert.That(End(plan.Chunks[0]), Is.EqualTo(20.5).Within(FrameSeconds));
        Assert.That(plan.Chunks[1].Start.TotalSeconds, Is.EqualTo(31.5).Within(FrameSeconds));
        Assert.That(End(plan.Chunks[1]), Is.EqualTo(58).Within(FrameSeconds));
        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.LessThan(58 * SyntheticWav.Rate * 2 - 10 * SyntheticWav.Rate * 2));
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

        Assert.That(WavSilenceChunker.TryPlan(wav, NoCap)!.Chunks, Has.Count.EqualTo(1));
        AssertContiguousCover(wav, WavSilenceChunker.TryPlan(wav)!);
    }

    [Test]
    public void ClickInsideAPause_DoesNotBreakIt()
    {
        var wav = SyntheticWav.Build(58, t => t < 20 || t >= 32 || (t >= 26 && t < 26.1));

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
            var wav = SyntheticWav.Build(45, t => (t >= 20 && t < 20.25) || t >= speechStart);

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

        Assert.That(WavSilenceChunker.TryPlan(wav, NoCap)!.Chunks, Has.Count.EqualTo(1));
        AssertContiguousCover(wav, WavSilenceChunker.TryPlan(wav)!);
    }

    [Test]
    public void LeadingAndTrailingSilence_IsTrimmed()
    {
        var wav = SyntheticWav.Build(65, t => t >= 20 && t < 45);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(1));
        Assert.That(plan.Chunks[0].Start.TotalSeconds, Is.EqualTo(19.5).Within(FrameSeconds));
        Assert.That(End(plan.Chunks[0]), Is.EqualTo(45.5).Within(FrameSeconds));
    }

    [Test]
    public void ContinuousSpeechWithShortGaps_IsCappedAtMaxChunk_CuttingInsideGaps()
    {
        var wav = SyntheticWav.Build(12 * 60, SyntheticWav.SentencePattern);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.GreaterThanOrEqualTo(12 * 60 / 28));
        AssertWhisperSized(plan);
        foreach (var chunk in plan.Chunks.Skip(1))
        {
            Assert.That(SyntheticWav.SentencePattern(chunk.Start.TotalSeconds), Is.False, $"cut at {chunk.Start} is inside speech");
        }
        AssertContiguousCover(wav, plan);
    }

    [Test]
    public void ContinuousSpeechWithHalfToOneSecondGaps_IsPlannedIntoWhisperSizedChunks_CutInsideGaps()
    {
        // Regression: chunks of up to 5 min lost the text past whisper's 30 s window.
        var speech = SyntheticWav.Sentences(6 * 60, seed: 7);
        var wav = SyntheticWav.BuildShaped(6 * 60, t => speech(t) ? 6000 : 0, noiseRms: 100);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        AssertWhisperSized(plan);
        Assert.That(plan.Chunks, Has.Count.GreaterThanOrEqualTo(6 * 60 / 28));
        foreach (var chunk in plan.Chunks.Skip(1))
        {
            Assert.That(speech(chunk.Start.TotalSeconds), Is.False, $"cap cut at {chunk.Start} is inside speech");
        }
        AssertContiguousCover(wav, plan);
    }

    [Test]
    public void QuietSpeechInANoisyRoom_IsCapCutAtAQuieterGap()
    {
        // Floor RMS 400 and no clearly loud audio: no frame counts as silent, the gaps are only quieter than the speech.
        var speech = SyntheticWav.Sentences(3 * 60, seed: 3);
        var wav = SyntheticWav.BuildShaped(3 * 60, t => speech(t) ? 1500 : 0, noiseRms: 400);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        AssertWhisperSized(plan);
        foreach (var chunk in plan.Chunks.Skip(1))
        {
            Assert.That(speech(chunk.Start.TotalSeconds), Is.False, $"cap cut at {chunk.Start} is inside speech");
        }
        AssertContiguousCover(wav, plan);
    }

    [Test]
    public void LongSpeechWithoutGaps_IsHardCutAtMaxChunk()
    {
        var wav = SyntheticWav.Build(100, _ => true);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks.Select(c => c.Start.TotalSeconds), Is.EqualTo(new[] { 0.0, 28, 56, 84 }).Within(3 * FrameSeconds), "cap rounded down to whole 30 ms frames");
        AssertWhisperSized(plan);
        AssertContiguousCover(wav, plan);
    }

    [Test]
    public void Chunks_NeverExceedMaxChunk_EvenWithoutSilence()
    {
        var wav = SyntheticWav.Build(100, _ => true);
        var options = new WavChunkerOptions { MaxChunk = TimeSpan.FromSeconds(30), CapSearchWindow = TimeSpan.FromSeconds(10) };

        var plan = WavSilenceChunker.TryPlan(wav, options)!;

        Assert.That(plan.Chunks.Select(c => c.Start.TotalSeconds), Is.EqualTo(new[] { 0.0, 30, 60, 90 }).Within(3 * FrameSeconds));
        Assert.That(plan.Chunks.All(c => ChunkLength(c) <= options.MaxChunk), Is.True);
        AssertContiguousCover(wav, plan);
    }

    [Test]
    public void PausesOfTenSecondsOrMore_StillCutAndAreDropped_WhileTheSpeechAroundThemIsCapped()
    {
        // sentences 1-60 s, 12 s pause, sentences 72-130 s
        bool Speech(double t) => (t < 60 && t % 5 >= 1) || (t >= 72 && (t - 72) % 5 < 4);
        var wav = SyntheticWav.Build(130, Speech);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        AssertWhisperSized(plan);
        Assert.That(plan.Chunks.Select(End), Has.Some.EqualTo(60.5).Within(FrameSeconds), "cut 0.5 s after the last word");
        Assert.That(plan.Chunks.Select(c => c.Start.TotalSeconds), Has.Some.EqualTo(71.5).Within(FrameSeconds), "resumes 0.5 s before the next word");
        Assert.That(plan.Chunks.Where(c => End(c) > 60.5 + FrameSeconds && c.Start.TotalSeconds < 71.5 - FrameSeconds), Is.Empty, "the pause is dropped");
        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(119 * SyntheticWav.Rate * 2).Within(2 * FrameSeconds * SyntheticWav.Rate * 2));
    }

    [Test]
    public void CapSplit_CutsAtAGap_ThatLeavesAtLeastMinTrailingChunk()
    {
        // brief gaps at 30 s and 57 s
        var wav = SyntheticWav.Build(61, t => !(t >= 29.9 && t < 30.1) && !(t >= 56.9 && t < 57.1));
        var options = new WavChunkerOptions { MaxChunk = TimeSpan.FromSeconds(30), CapSearchWindow = TimeSpan.FromSeconds(10) };

        var plan = WavSilenceChunker.TryPlan(wav, options)!;

        Assert.That(plan.Chunks.Select(c => c.Start.TotalSeconds), Is.EqualTo(new[] { 0.0, 30, 57 }).Within(0.15));
        Assert.That(plan.Chunks.All(c => ChunkLength(c) <= options.MaxChunk), Is.True, "never merged past the cap");
        AssertContiguousCover(wav, plan);
    }

    [Test]
    public void GapNearTheEnd_IsNotUsed_WhenItWouldLeaveATinyLastPiece()
    {
        // Regression: 28.3 s with a gap at 27.6-27.9 s was cut there, sending a 0.55 s request that split the last word.
        var wav = SyntheticWav.Build(28.3, t => !(t >= 27.6 && t < 27.9));

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(2));
        Assert.That(plan.Chunks.Select(ChunkLength), Has.All.GreaterThanOrEqualTo(WavSilenceChunker.DefaultOptions.MinTrailingChunk - TimeSpan.FromSeconds(2 * FrameSeconds)));
        AssertWhisperSized(plan);
        AssertContiguousCover(wav, plan);
    }

    [Test]
    public void ShortLastWordAfterAGapNearTheCap_IsSent()
    {
        // Regression: 28.04 s with a 0.3 s gap at 27.6 s and a 0.14 s last word planned only 0+27.75; the word was lost.
        var wav = SyntheticWav.Build(28.04, t => !(t >= 27.6 && t < 27.9));

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(End(plan.Chunks[^1]), Is.EqualTo(28.04).Within(FrameSeconds));
        AssertWhisperSized(plan);
        AssertContiguousCover(wav, plan);
    }

    [Test]
    public void QuietTalkAfterLoudTalk_IsSent_ThoughTheThresholdCallsItSilence()
    {
        // Regression: loud talk to 25 s, then audible but quieter talk (RMS ~265, below the adaptive threshold)
        // to 31 s. The cap piece 28-31 s had no "non-silent" frames and was dropped by MinSpeech.
        var wav = SyntheticWav.BuildShaped(31, t => t < 25 ? 8000 : 375, noiseRms: 100);

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(2));
        Assert.That(End(plan.Chunks[^1]), Is.EqualTo(31).Within(FrameSeconds));
        AssertWhisperSized(plan);
        AssertContiguousCover(wav, plan);
    }

    [Test]
    public void GapCrossingTheWindowEnd_IsMeasuredInFull_AndTheCutIsClampedIntoTheWindow()
    {
        // Window [20, 30): a 0.6 s gap at 22 s, and a 1.7 s gap at 29.8-31.5 s of which only 0.2 s is inside.
        bool Speech(double t) => !(t >= 22 && t < 22.6) && !(t >= 29.8 && t < 31.5);
        var wav = SyntheticWav.Build(50, Speech);
        var options = new WavChunkerOptions { MaxChunk = TimeSpan.FromSeconds(30), CapSearchWindow = TimeSpan.FromSeconds(10) };

        var plan = WavSilenceChunker.TryPlan(wav, options)!;

        Assert.That(plan.Chunks[1].Start.TotalSeconds, Is.EqualTo(30).Within(FrameSeconds), "longer gap wins; its middle (30.65 s) is clamped to the cap");
        Assert.That(Speech(plan.Chunks[1].Start.TotalSeconds), Is.False);
        AssertContiguousCover(wav, plan);
    }

    [Test]
    public void GapCrossingTheWindowStart_IsMeasuredInFull_AndTheCutIsClampedIntoTheWindow()
    {
        // Window [20, 30): a 1.3 s gap at 19.0-20.3 s of which only 0.3 s is inside, and a 0.5 s gap at 25 s.
        bool Speech(double t) => !(t >= 19 && t < 20.3) && !(t >= 25 && t < 25.5);
        var wav = SyntheticWav.Build(50, Speech);
        var options = new WavChunkerOptions { MaxChunk = TimeSpan.FromSeconds(30), CapSearchWindow = TimeSpan.FromSeconds(10) };

        var plan = WavSilenceChunker.TryPlan(wav, options)!;

        Assert.That(plan.Chunks[1].Start.TotalSeconds, Is.EqualTo(20).Within(FrameSeconds), "longer gap wins; its middle (19.65 s) is clamped to the window start");
        Assert.That(Speech(plan.Chunks[1].Start.TotalSeconds), Is.False);
        AssertContiguousCover(wav, plan);
    }

    [Test]
    public void HardCut_LeavesAtLeastMinTrailingChunkForTheLastPiece()
    {
        var wav = SyntheticWav.Build(61, _ => true);
        var options = new WavChunkerOptions { MaxChunk = TimeSpan.FromSeconds(30), CapSearchWindow = TimeSpan.FromSeconds(10) };

        var plan = WavSilenceChunker.TryPlan(wav, options)!;

        Assert.That(plan.Chunks, Has.Count.EqualTo(3));
        Assert.That(ChunkLength(plan.Chunks[^1]).TotalSeconds, Is.GreaterThanOrEqualTo(options.MinTrailingChunk.TotalSeconds - 2 * FrameSeconds), "whole frames, last one partial");
        Assert.That(plan.Chunks.All(c => ChunkLength(c) <= options.MaxChunk), Is.True);
        AssertContiguousCover(wav, plan);
    }

    [TestCase("sentences")]
    [TestCase("tone")]
    [TestCase("noisy")]
    public void CapPieces_AreContiguous_SoNoAudioIsLostBetweenThem(string kind)
    {
        var speech = SyntheticWav.Sentences(300, seed: 11);
        var wav = kind switch
        {
            "sentences" => SyntheticWav.Build(300, speech),
            "tone" => SyntheticWav.Build(300, _ => true),
            _ => SyntheticWav.BuildShaped(300, t => speech(t) ? 1500 : 300, noiseRms: 200)
        };

        var plan = WavSilenceChunker.TryPlan(wav)!;

        Assert.That(plan.Chunks, Has.Count.GreaterThan(300 / 28));
        AssertContiguousCover(wav, plan);
        AssertWhisperSized(plan);
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
        Assert.Throws<ArgumentException>(() => WavSilenceChunker.TryPlan(wav, new WavChunkerOptions { NoChunkUpTo = TimeSpan.FromSeconds(40) }), "a whole-file send must fit the cap");
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
    public void RecordingThatFitsTheCap_IsNotChunked_ALongerOneIs()
    {
        Assert.That(WavSilenceChunker.TryPlan(SyntheticWav.Build(28, SyntheticWav.SentencePattern)), Is.Null);
        var plan = WavSilenceChunker.TryPlan(SyntheticWav.Build(30, SyntheticWav.SentencePattern))!;
        Assert.That(plan.Chunks, Has.Count.EqualTo(2), "30 s used to be sent whole");
        AssertWhisperSized(plan);
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

    /// <summary>Every chunk fits the cap and therefore whisper's 30 s decoding window.</summary>
    private static void AssertWhisperSized(WavChunkPlan plan)
    {
        foreach (var chunk in plan.Chunks)
        {
            Assert.That(ChunkLength(chunk), Is.LessThanOrEqualTo(MaxChunk).And.LessThanOrEqualTo(WhisperWindow), $"chunk at {chunk.Start}");
        }
    }

    /// <summary>The chunks follow each other byte for byte and together hold the whole recording.</summary>
    private static void AssertContiguousCover(byte[] wav, WavChunkPlan plan)
    {
        var layout = WavSilenceChunker.ParseLayout(wav)!;
        Assert.That(plan.Chunks[0].ByteOffset, Is.EqualTo(layout.DataOffset), "starts at the first sample");
        for (var i = 1; i < plan.Chunks.Count; i++)
        {
            var previous = plan.Chunks[i - 1];
            Assert.That(plan.Chunks[i].ByteOffset, Is.EqualTo(previous.ByteOffset + previous.ByteLength), $"gap or overlap before chunk {i}");
        }
        Assert.That(plan.Chunks.Sum(c => c.ByteLength), Is.EqualTo(layout.DataLength), "every byte is sent");
    }

    private static double End(WavChunk chunk) => chunk.Start.TotalSeconds + ChunkLength(chunk).TotalSeconds;

    private static TimeSpan ChunkLength(WavChunk chunk) => TimeSpan.FromSeconds((double)chunk.ByteLength / 2 / SyntheticWav.Rate);
}
