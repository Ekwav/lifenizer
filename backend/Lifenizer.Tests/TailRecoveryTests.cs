using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Lifenizer.Tests;

/// <summary>
/// The trained whisper sometimes stops transcribing seconds before the end of a request; the tail is then sent
/// once more and its text appended.
/// </summary>
public sealed class TailRecoveryTests
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    [Test]
    public async Task EarlyStop_TailIsResent_AndMergedInOrderWithAbsoluteOffsets()
    {
        // speech 0-20 s, a 12 s pause, speech 32-45 s: two chunks, both with speech to their end
        var wav = SyntheticWav.Build(45, t => t < 20 || t >= 32);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        var chunkLengths = plan.Chunks.Select(c => Seconds(c.ByteLength)).ToList();
        var logger = new ListLogger<ChunkedWhisperTranscriber>();
        using var transcriber = new ChunkedWhisperTranscriber(logger, 2, TimeSpan.FromSeconds(30), timeoutPerAudioSecond: 0);
        var requests = new ConcurrentQueue<double>();

        var result = await transcriber.TranscribeAsync(wav, plan, 2, (audio, _) =>
        {
            var seconds = Seconds(audio);
            requests.Enqueue(seconds);
            var isChunk = chunkLengths.Any(l => Math.Abs(l - seconds) < 1e-6);
            return Task.FromResult(isChunk ? Result((0.5, 0.6 * seconds, "one two")) : Result((0.6, seconds - 0.3, "three four")));
        }, CancellationToken.None);

        Assert.That(plan.Chunks, Has.Count.EqualTo(2));
        var expectedStarts = plan.Chunks.SelectMany((chunk, i) => new[]
        {
            chunk.Start.TotalSeconds + 0.5,
            chunk.Start.TotalSeconds + TailStart(0.6 * chunkLengths[i]) + 0.6
        }).ToList();
        Assert.Multiple(() =>
        {
            Assert.That(requests, Has.Count.EqualTo(4), "one tail request per chunk");
            Assert.That(result.Segments.Select(s => s.Text), Is.EqualTo(new[] { "one two", "three four", "one two", "three four" }));
            Assert.That(result.Segments.Select(s => s.Start), Is.EqualTo(expectedStarts).Within(1e-3));
            Assert.That(result.Segments.Select(s => s.Start), Is.Ordered.Ascending);
            Assert.That(result.Text, Is.EqualTo("one two three four one two three four"));
        });
        var recovered = logger.Entries.Where(e => e.Values.ContainsKey("RecoveredWords")).ToList();
        Assert.That(recovered, Has.Count.EqualTo(2));
        Assert.That(recovered.Select(e => e.Values["RecoveredWords"]), Has.All.EqualTo(2));
        var byChunk = recovered.OrderBy(e => (int)e.Values["ChunkNumber"]!).ToList();
        Assert.That(byChunk.Select(e => (int)e.Values["ChunkNumber"]!), Is.EqualTo(new[] { 1, 2 }));
        Assert.That(byChunk.Select(e => (double)e.Values["TailStartSeconds"]!), Is.EqualTo(new[] { expectedStarts[1] - 0.6, expectedStarts[3] - 0.6 }).Within(1e-3));
        Assert.That(logger.Lines.Single(l => l.StartsWith("Transcribed 2 audio chunks", StringComparison.Ordinal)), Does.EndWith("recovered 2/2 cut-off tail(s)"));
    }

    [TestCase(11.9, 1, TestName = "SilentTail_IsNotResent")]
    [TestCase(10.0, 2, TestName = "TailWithSpeech_IsResent")]
    public async Task OnlyATailWithSpeech_IsResent(double lastEnd, int expectedRequests)
    {
        // speech ends at 12 s, then 8 s of silence; after 11.9 s only 0.1 s of speech is left (below MinSpeech)
        var (wav, plan) = Whole(20, t => t < 12);

        var requests = await CountRequestsAsync(wav, plan, seconds => seconds > 19 ? Result((0, lastEnd, "head")) : Result((0, 1, "tail")));

        Assert.That(requests, Is.EqualTo(expectedRequests));
    }

    [TestCase(17.6, 1, TestName = "GapBelowThreshold_IsNotResent")]
    [TestCase(17.4, 2, TestName = "GapAboveThreshold_IsResent")]
    public async Task OnlyAGapLongerThanTheThreshold_IsResent(double lastEnd, int expectedRequests)
    {
        var (wav, plan) = Whole(20, _ => true);

        var requests = await CountRequestsAsync(wav, plan, seconds => seconds > 19 ? Result((0, lastEnd, "head")) : Result((0, 1, "tail")));

        Assert.That(requests, Is.EqualTo(expectedRequests));
    }

    [Test]
    public async Task RecoveryThatStopsEarlyAgain_IsNotResentAgain()
    {
        var (wav, plan) = Whole(20, _ => true);
        var calls = 0;

        var result = await NewTranscriber().TranscribeAsync(wav, plan, 1, (_, _) =>
            Task.FromResult(Interlocked.Increment(ref calls) == 1 ? Result((0, 1, "first")) : Result((0, 1, "second"))), CancellationToken.None);

        Assert.That(calls, Is.EqualTo(2));
        Assert.That(result.Text, Is.EqualTo("first second"));
    }

    [Test]
    public async Task NoSegmentsOrNoEndTime_IsNotResent()
    {
        var (wav, plan) = Whole(20, _ => true);

        Assert.That(await CountRequestsAsync(wav, plan, _ => new WhisperTranscriptionResult("", "en", [])), Is.EqualTo(1), "a tail would be the whole chunk again");
        Assert.That(await CountRequestsAsync(wav, plan, _ => new WhisperTranscriptionResult("text", "en", [new WhisperSegment(0, null, "text")])), Is.EqualTo(1));
    }

    [Test]
    public async Task OverlappingDuplicateAtTheJoin_IsRemoved()
    {
        var (wav, plan) = Whole(20, _ => true);

        // the tail starts at 11.5 s and hears "big market" again
        var result = await NewTranscriber().TranscribeAsync(wav, plan, 1, (audio, _) => Task.FromResult(Seconds(audio) > 19
            ? Result((0, 6, " we went to"), (6, 12, " the big market"))
            : Result((0, 1.0, " Big market, and"), (1.0, 3, " bought bread."))), CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(result.Segments.Select(s => s.Text.Trim()), Is.EqualTo(new[] { "we went to", "the big market", "and", "bought bread." }));
            Assert.That(result.Segments[2].Start, Is.EqualTo(12).Within(1e-9), "the trimmed segment starts where the repeat ended");
            Assert.That(result.Segments[3].Start, Is.EqualTo(12.5).Within(1e-3));
            Assert.That(result.Text, Is.EqualTo("we went to the big market and bought bread."));
        });
    }

    [Test]
    public void Merge_DropsAFullyRepeatedSegment_AndKeepsRepeatsThatDoNotOverlapInTime()
    {
        var head = Result((0, 5, "hello there"));

        var repeated = WhisperTailMerge.Append(head, Result((0, 0.4, "There."), (0.4, 2, "how are you")), 4.5);
        var later = WhisperTailMerge.Append(head, Result((0.6, 1, "there")), 4.5);

        Assert.Multiple(() =>
        {
            Assert.That(repeated.Result.Segments.Select(s => s.Text), Is.EqualTo(new[] { "hello there", "how are you" }));
            Assert.That(repeated.WordsAdded, Is.EqualTo(3));
            Assert.That(later.Result.Segments.Select(s => s.Text), Is.EqualTo(new[] { "hello there", "there" }), "starts after the head ended: a real repeat");
            Assert.That(WhisperTailMerge.Append(head, Result((0, 0.4, "there")), 4.5).Result, Is.SameAs(head));
        });
    }

    [Test]
    public async Task CancellationDuringTheRecoveryRequest_StopsPromptly_AndReleasesTheGate()
    {
        var (wav, plan) = Whole(20, _ => true);
        using var transcriber = NewTranscriber(maxConcurrent: 1);
        using var cts = new CancellationTokenSource();
        var tailStarted = new TaskCompletionSource();

        var run = transcriber.TranscribeAsync(wav, plan, 1, async (audio, token) =>
        {
            if (Seconds(audio) > 19) return Result((0, 5, "head"));
            tailStarted.SetResult();
            await Task.Delay(Timeout.Infinite, token);
            return Result();
        }, cts.Token);
        await tailStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cts.Cancel();

        var stopped = await Task.WhenAny(run, Task.Delay(2000));
        Assert.That(stopped, Is.SameAs(run), "the run stops promptly");
        Assert.CatchAsync<OperationCanceledException>(async () => await run);
        using var probe = new CancellationTokenSource(TimeSpan.FromSeconds(1));
        Assert.That(await transcriber.RunGatedAsync(_ => Task.FromResult(1), probe.Token), Is.EqualTo(1), "the global slot was released");
    }

    [TestCase(0)]
    [TestCase(-3)]
    [TestCase(double.NaN)]
    public async Task TailRecoveryOff_SendsOneRequest(double seconds)
    {
        var (wav, plan) = Whole(20, _ => true);
        using var transcriber = new ChunkedWhisperTranscriber(NullLogger<ChunkedWhisperTranscriber>.Instance, 4, TimeSpan.FromSeconds(30), 0, seconds);
        var calls = 0;

        await transcriber.TranscribeAsync(wav, plan, 1, (_, _) =>
        {
            Interlocked.Increment(ref calls);
            return Task.FromResult(Result((0, 5, "head")));
        }, CancellationToken.None);

        Assert.That(calls, Is.EqualTo(1));
    }

    [TestCase(null, 2.5)]
    [TestCase("0", 0)]
    [TestCase("-3", 0)]
    [TestCase("abc", 2.5)]
    [TestCase("NaN", 2.5)]
    [TestCase("Infinity", 2.5)]
    [TestCase("0.2", 1)]
    [TestCase("4", 4)]
    [TestCase("1e9", 30)]
    public void TailRecoverySetting_IsClampedSensibly(string? configured, double expected)
    {
        var values = new Dictionary<string, string?>();
        if (configured is not null) values["Whisper:TailRecoverySeconds"] = configured;
        var config = new ConfigurationBuilder().AddInMemoryCollection(values).Build();

        Assert.That(WhisperSettings.TailRecoverySeconds(config), Is.EqualTo(expected));
    }

    [Test]
    public async Task WholeWav_ThatStopsEarly_GetsItsTailRecovered()
    {
        var wav = SyntheticWav.Build(20, _ => true);
        var uploads = new ConcurrentQueue<string>();
        await using var whisper = new MockHttpServer(request =>
        {
            uploads.Enqueue(UploadContentType(request));
            return uploads.Count == 1 ? WhisperJson((0, 8, "first part")) : WhisperJson((0, 11.5, "second part"));
        });
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Whisper:BaseUrl"] = whisper.Url });
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "tail-whole-wav@example.test");

        var result = await ChunkedAudioImportTests.ImportAsync(client, wav);

        var segments = result.Conversations[0].Segments;
        Assert.Multiple(() =>
        {
            Assert.That(uploads, Has.Count.EqualTo(2));
            Assert.That(segments.Select(s => s.Text), Is.EqualTo(new[] { "first part", "second part" }));
            Assert.That(segments[1].OffsetMs, Is.EqualTo(8000), "the tail is sent from 7.5 s but its segment starts where the first part ended");
            Assert.That(segments[1].EndMs, Is.EqualTo(19000));
        });
    }

    [Test]
    public async Task WholeOggOpus_ThatStopsEarly_GetsItsTailRecoveredAsAWavSlice()
    {
        var ogg = OpusUploadTests.EncodeOpus(20, _ => true);
        var uploads = new ConcurrentQueue<string>();
        await using var whisper = new MockHttpServer(request =>
        {
            uploads.Enqueue(UploadContentType(request));
            return uploads.Count == 1 ? WhisperJson((0, 8, "first part")) : WhisperJson((0, 11, "second part"));
        });
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Whisper:BaseUrl"] = whisper.Url });
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "tail-whole-ogg@example.test");

        var response = await client.PostAsync("/api/imports/audio/upload", OpusUploadTests.Multipart(ogg, "audio/ogg", new ImportRequest(OriginalFileName: "note.ogg")));

        response.EnsureSuccessStatusCode();
        var result = (await response.Content.ReadFromJsonAsync<NormalizedImportResponse>(JsonOptions))!;
        Assert.That(uploads, Is.EqualTo(new[] { "audio/ogg", "audio/wav" }), "the file goes out as is, the tail as a decoded slice");
        Assert.That(result.Conversations[0].Segments.Select(s => s.Text), Is.EqualTo(new[] { "first part", "second part" }));
    }

    [Test]
    public async Task WholeFileThatCannotBeSliced_IsSentOnce()
    {
        await using var whisper = new MockHttpServer(_ => WhisperJson((0, 1, "only once")));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Whisper:BaseUrl"] = whisper.Url });
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "tail-whole-mp3@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/audio",
            new ImportRequest(OriginalFileName: "note.mp3", MimeType: "audio/mpeg", PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("ID3 not really mp3"))), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(whisper.RequestCount, Is.EqualTo(1));
    }

    [Test]
    public async Task TailThatTimesOut_KeepsTheHeadTranscript_AndLogsAWarning()
    {
        var (wav, plan) = Whole(20, _ => true);
        var logger = new ListLogger<ChunkedWhisperTranscriber>();
        using var transcriber = new ChunkedWhisperTranscriber(logger, 4, TimeSpan.FromSeconds(30), timeoutPerAudioSecond: 0);

        var result = await transcriber.TranscribeAsync(wav, plan, 1, (audio, _) =>
            Seconds(audio) > 19 ? Task.FromResult(Result((0, 5, "head text"))) : throw new WhisperTimeoutException("tail timed out"), CancellationToken.None);

        Assert.That(result.Text, Is.EqualTo("head text"));
        var warning = logger.Entries.Single(e => e.Level == LogLevel.Warning);
        Assert.Multiple(() =>
        {
            Assert.That(warning.Values["ChunkNumber"], Is.EqualTo(1));
            Assert.That(warning.Values["ChunkCount"], Is.EqualTo(1));
            Assert.That(warning.Message, Does.Contain(nameof(WhisperTimeoutException)).And.Contain("tail timed out"));
            Assert.That(logger.Lines.Single(l => l.StartsWith("Transcribed 1 audio chunks", StringComparison.Ordinal)), Does.EndWith("recovered 0/1 cut-off tail(s)"));
        });
    }

    [Test]
    public async Task TailThatFailsTwiceWithA500_KeepsTheHeadTranscript()
    {
        var (wav, plan) = Whole(20, _ => true);
        var logger = new ListLogger<ChunkedWhisperTranscriber>();
        using var transcriber = new ChunkedWhisperTranscriber(logger, 4, TimeSpan.FromSeconds(30), timeoutPerAudioSecond: 0);
        var tailCalls = 0;

        var result = await transcriber.TranscribeAsync(wav, plan, 1, (audio, _) =>
        {
            if (Seconds(audio) > 19) return Task.FromResult(Result((0, 5, "head text")));
            Interlocked.Increment(ref tailCalls);
            throw new WhisperTransientException("whisper failed with 500");
        }, CancellationToken.None);

        Assert.That(result.Text, Is.EqualTo("head text"));
        Assert.That(tailCalls, Is.EqualTo(2), "the tail got its one retry");
        Assert.That(logger.Entries.Count(e => e.Level == LogLevel.Warning && e.Message.Contains("Could not recover")), Is.EqualTo(1));
    }

    [Test]
    public async Task SiblingChunkFailing_StillCancelsATailInFlight()
    {
        var wav = SyntheticWav.Build(45, t => t < 20 || t >= 32);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        var lengths = plan.Chunks.Select(c => Seconds(c.ByteLength)).ToArray();
        using var transcriber = NewTranscriber();
        var tailStarted = new TaskCompletionSource();

        var run = transcriber.TranscribeAsync(wav, plan, 2, async (audio, token) =>
        {
            var seconds = Seconds(audio);
            if (Math.Abs(seconds - lengths[0]) < 1e-6) return Result((0, 0.5 * seconds, "head"));
            if (Math.Abs(seconds - lengths[1]) > 1e-6)
            {
                tailStarted.TrySetResult();
                await Task.Delay(Timeout.Infinite, token);
            }
            await tailStarted.Task;
            throw new InvalidOperationException("sibling failed");
        }, CancellationToken.None);

        var thrown = Assert.CatchAsync<Exception>(async () => await run.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.That(thrown, Is.Not.InstanceOf<TimeoutException>().And.Not.InstanceOf<WhisperTimeoutException>());
    }

    [TestCase(10.3, 1, TestName = "TailWithLessThanHalfASecondOfSpeech_IsNotResent")]
    [TestCase(10.8, 2, TestName = "TailWithHalfASecondOfSpeech_IsResent")]
    public async Task TailNeedsHalfASecondOfSpeech(double speechEnd, int expectedRequests)
    {
        var (wav, plan) = Whole(20, t => t < speechEnd);

        var requests = await CountRequestsAsync(wav, plan, seconds => seconds > 19 ? Result((0, 10.0, "head")) : Result((0, 1, "tail")));

        Assert.That(requests, Is.EqualTo(expectedRequests));
    }

    [Test]
    public async Task TailIsSentInTheLanguageTheHeadReported()
    {
        var (wav, plan) = Whole(20, _ => true);
        var languages = new ConcurrentQueue<string?>();
        using var transcriber = NewTranscriber();

        await transcriber.TranscribeAsync(wav, plan, 1, (audio, _) =>
        {
            languages.Enqueue(audio.Language);
            return Task.FromResult(languages.Count == 1 ? Result("de", (0, 5, "hallo")) : Result("en", (0, 1, "welt")));
        }, CancellationToken.None);

        Assert.That(languages, Is.EqualTo(new string?[] { null, "de" }));
    }

    [TestCase("auto")]
    [TestCase("  ")]
    public async Task WholeWav_AutoCallerLanguage_StillSendsTheTailInTheHeadsLanguage(string callerLanguage)
    {
        var wav = SyntheticWav.Build(20, _ => true);
        var queries = new ConcurrentQueue<string>();
        await using var whisper = new MockHttpServer(request =>
        {
            queries.Enqueue(request.Url!.Query);
            return queries.Count == 1 ? WhisperJson("de", (0, 8, "erster teil")) : WhisperJson("en", (0, 11.5, "zweiter teil"));
        });
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Whisper:BaseUrl"] = whisper.Url });
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "tail-auto@example.test");
        var request = new ImportRequest(OriginalFileName: "long.wav", MimeType: "audio/wav", PayloadBase64: Convert.ToBase64String(wav),
            Metadata: new Dictionary<string, string> { ["language"] = callerLanguage });

        var response = await client.PostAsJsonAsync("/api/imports/audio", request);
        response.EnsureSuccessStatusCode();

        Assert.That(queries, Has.Count.EqualTo(2));
        Assert.That(queries.Last(), Does.Contain("language=de"));
    }

    [Test]
    public async Task WholeWav_TailRequestCarriesTheDetectedLanguage()
    {
        var wav = SyntheticWav.Build(20, _ => true);
        var queries = new ConcurrentQueue<string>();
        await using var whisper = new MockHttpServer(request =>
        {
            queries.Enqueue(request.Url!.Query);
            return queries.Count == 1 ? WhisperJson("de", (0, 8, "erster teil")) : WhisperJson("en", (0, 11.5, "zweiter teil"));
        });
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Whisper:BaseUrl"] = whisper.Url });
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "tail-language@example.test");

        await ChunkedAudioImportTests.ImportAsync(client, wav);

        Assert.That(queries, Has.Count.EqualTo(2));
        Assert.That(queries.First(), Does.Not.Contain("language="));
        Assert.That(queries.Last(), Does.Contain("language=de"));
    }

    [Test]
    public async Task ChunkTailSlice_OfStereo44kHzAudio_KeepsFormatAndAlignment()
    {
        var (wav, plan) = Whole(20, _ => true, channels: 2, rate: 44100);
        var slices = new ConcurrentQueue<byte[]>();
        using var transcriber = NewTranscriber();

        await transcriber.TranscribeAsync(wav, plan, 1, async (audio, _) =>
        {
            slices.Enqueue(await audio.ReadAsByteArrayAsync());
            return slices.Count == 1 ? Result((0, 10, "head")) : Result((0, 1, "tail"));
        }, CancellationToken.None);

        var tail = slices.Last();
        var tailStartSample = (int)Math.Floor(9.5 * 44100);
        var expectedData = 20 * 44100 * 4 - tailStartSample * 4;
        Assert.Multiple(() =>
        {
            Assert.That(BinaryPrimitives.ReadInt16LittleEndian(tail.AsSpan(22)), Is.EqualTo(2), "channels");
            Assert.That(BinaryPrimitives.ReadInt32LittleEndian(tail.AsSpan(24)), Is.EqualTo(44100), "sample rate");
            Assert.That(BinaryPrimitives.ReadInt16LittleEndian(tail.AsSpan(32)), Is.EqualTo(4), "block align");
            Assert.That(BinaryPrimitives.ReadInt32LittleEndian(tail.AsSpan(40)), Is.EqualTo(expectedData), "data length");
            Assert.That(expectedData % 4, Is.EqualTo(0));
            Assert.That(tail, Has.Length.EqualTo(WavSilenceChunker.WavHeaderLength + expectedData));
        });
    }

    [Test]
    public void Merge_DedupsAcrossHeadSegments()
    {
        var head = Result((0, 9, "we went"), (9, 10, "home"));

        var merged = WhisperTailMerge.Append(head, Result((0, 1, "went home and slept")), 9.5);

        Assert.That(merged.Result.Text, Is.EqualTo("we went home and slept"));
        Assert.That(merged.Result.Segments.Select(s => s.Text), Is.EqualTo(new[] { "we went", "home", "and slept" }));
        Assert.That(merged.WordsAdded, Is.EqualTo(2));
    }

    [Test]
    public void Merge_StripsAtMostThreeWords_AndAtMostWhatTheHeadEndsWith()
    {
        // "no no" is the longest repeated prefix (up to 3 words) that the head ends with: the tail's third "no" is new speech
        var stuttering = WhisperTailMerge.Append(Result((0, 5, "I said no no")), Result((0, 1, "no no no stop")), 4.5);
        // a four-word repeat cannot come from 0.5 s of audio: nothing is stripped (it is real speech)
        var long4 = WhisperTailMerge.Append(Result((0, 5, "a b c d")), Result((0, 1, "a b c d e")), 4.5);

        Assert.Multiple(() =>
        {
            Assert.That(stuttering.Result.Text, Is.EqualTo("I said no no no stop"));
            Assert.That(long4.Result.Text, Is.EqualTo("a b c d a b c d e"));
        });
    }

    [Test]
    public void Merge_KeepsStartBeforeEnd_AndNeverOverlapsThePreviousSegment()
    {
        var head = Result((9.0, 9.8, "so"), (9.8, 10.0, "yes"));

        var merged = WhisperTailMerge.Append(head, Result((0, 0.2, "uh")), 9.5);

        var added = merged.Result.Segments[^1];
        Assert.Multiple(() =>
        {
            Assert.That(added.Text, Is.EqualTo("uh"));
            Assert.That(added.Start, Is.GreaterThanOrEqualTo(10.0));
            Assert.That(added.End, Is.GreaterThanOrEqualTo(added.Start));
        });
    }

    [Test]
    public void Merge_KeptSegmentWithoutEnd_UsesItsStartAsTheFloorForTheNext()
    {
        var head = Result((0, 5, "hello"));
        var tail = new WhisperTranscriptionResult("big world", null,
            [new WhisperSegment(10.0, null, "big"), new WhisperSegment(9.6, 11.0, "world")]);

        var segments = WhisperTailMerge.Append(head, tail, 0).Result.Segments;

        Assert.That(segments.Select(s => s.Text), Is.EqualTo(new[] { "hello", "big", "world" }));
        for (var i = 1; i < segments.Count; i++)
        {
            Assert.That(segments[i].Start, Is.GreaterThanOrEqualTo(segments[i - 1].Start), $"segment {i} starts in order");
            Assert.That(segments[i].End ?? segments[i].Start, Is.GreaterThanOrEqualTo(segments[i].Start), $"segment {i} Start <= End");
        }
    }

    [Test]
    public void Merge_IgnoresWhitespaceOnlyTailSegments()
    {
        var head = Result((0, 5, "hello"));

        var merged = WhisperTailMerge.Append(head, Result((0, 1, "  "), (1, 2, " ")), 4.5);

        Assert.That(merged.Result, Is.SameAs(head));
        Assert.That(merged.WordsAdded, Is.EqualTo(0));
    }

    [Test]
    public async Task WholeOgg_ThatReachesTheEnd_NeitherDecodesNorTakesBudget()
    {
        var ogg = OpusUploadTests.EncodeOpus(20, _ => true);
        var budget = new AudioMemoryBudget(50);
        var loads = 0;
        var sent = 0;
        using var transcriber = NewTranscriber();

        var result = await transcriber.RecoverWholeFileTailAsync(Result((0, 19.5, "complete")), () => AudioChunking.WholeDurationSeconds(ogg),
            token => { loads++; return AudioChunking.TryLoadWholeAsync(ogg, new AudioLimits(3600, budget), token); },
            (_, _) => { sent++; return Task.FromResult(Result()); }, CancellationToken.None);

        Assert.That(result.Text, Is.EqualTo("complete"));
        Assert.That((loads, sent, budget.PeakUsedMb), Is.EqualTo((0, 0, 0L)));
    }

    [Test]
    public async Task WholeOggRecovery_GivesTheBudgetBack()
    {
        var ogg = OpusUploadTests.EncodeOpus(20, _ => true);
        var budget = new AudioMemoryBudget(50);
        using var transcriber = NewTranscriber();

        var result = await transcriber.RecoverWholeFileTailAsync(Result((0, 8, "first")), () => AudioChunking.WholeDurationSeconds(ogg),
            token => AudioChunking.TryLoadWholeAsync(ogg, new AudioLimits(3600, budget), token),
            (_, _) => Task.FromResult(Result((0, 11, "second"))), CancellationToken.None);

        Assert.That(result.Text, Is.EqualTo("first second"));
        Assert.That(budget.PeakUsedMb, Is.GreaterThan(0));
        await AssertBudgetIsFreeAsync(budget);
    }

    [Test]
    public async Task WholeOggThatFailsToDecode_GivesTheBudgetBack_AndKeepsTheTranscript()
    {
        var ogg = OggTestKit.CorruptPacket(OpusUploadTests.EncodeOpus(20, _ => true), pageIndex: 3);
        var budget = new AudioMemoryBudget(50);
        var sent = 0;
        using var transcriber = NewTranscriber();

        var result = await transcriber.RecoverWholeFileTailAsync(Result((0, 8, "first")), () => AudioChunking.WholeDurationSeconds(ogg),
            token => AudioChunking.TryLoadWholeAsync(ogg, new AudioLimits(3600, budget), token),
            (_, _) => { sent++; return Task.FromResult(Result()); }, CancellationToken.None);

        Assert.That(result.Text, Is.EqualTo("first"));
        Assert.That(sent, Is.EqualTo(0));
        Assert.That(budget.PeakUsedMb, Is.GreaterThan(0), "the decode was attempted");
        await AssertBudgetIsFreeAsync(budget);
    }

    [Test]
    public async Task WholeFileWhoseDurationCannotBeRead_KeepsTheTranscript()
    {
        using var transcriber = NewTranscriber();
        var sent = 0;

        var result = await transcriber.RecoverWholeFileTailAsync(Result((0, 8, "first")), () => throw new InvalidOperationException("no duration"),
            _ => throw new InvalidOperationException("must not load"), (_, _) => { sent++; return Task.FromResult(Result()); }, CancellationToken.None);

        Assert.That(result.Text, Is.EqualTo("first"));
        Assert.That(sent, Is.EqualTo(0));
    }

    [Test]
    public void WholeFileWhoseDurationLookupIsCancelled_Propagates()
    {
        using var transcriber = NewTranscriber();
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        Assert.ThrowsAsync<OperationCanceledException>(() => transcriber.RecoverWholeFileTailAsync(Result((0, 8, "first")),
            () => throw new OperationCanceledException(cts.Token), _ => Task.FromResult<AudioChunkSource?>(null), (_, _) => Task.FromResult(Result()), cts.Token));
    }

    [Test]
    public async Task WholeFileThatCannotBeLoaded_KeepsTheTranscript()
    {
        using var transcriber = NewTranscriber();

        var result = await transcriber.RecoverWholeFileTailAsync(Result((0, 8, "first")), () => 20,
            _ => throw new AudioMemoryBudgetExceededException(900, 600), (_, _) => Task.FromResult(Result()), CancellationToken.None);

        Assert.That(result.Text, Is.EqualTo("first"));
    }

    private static async Task AssertBudgetIsFreeAsync(AudioMemoryBudget budget)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        using var all = await budget.AcquireAsync(budget.TotalMb << 20, timeout.Token);
    }

    private static WhisperTranscriptionResult Result(string language, params (double Start, double End, string Text)[] segments) =>
        Result(segments) with { Language = language };

    private static ChunkedWhisperTranscriber NewTranscriber(int maxConcurrent = 4) =>
        new(NullLogger<ChunkedWhisperTranscriber>.Instance, maxConcurrent, TimeSpan.FromSeconds(30), timeoutPerAudioSecond: 0);

    private static async Task<int> CountRequestsAsync(byte[] wav, WavChunkPlan plan, Func<double, WhisperTranscriptionResult> respond)
    {
        using var transcriber = NewTranscriber();
        var calls = 0;
        await transcriber.TranscribeAsync(wav, plan, 1, (audio, _) =>
        {
            Interlocked.Increment(ref calls);
            return Task.FromResult(respond(Seconds(audio)));
        }, CancellationToken.None);
        return calls;
    }

    /// <summary>The whole WAV as one chunk, the way a file sent whole is judged.</summary>
    private static (byte[] Wav, WavChunkPlan Plan) Whole(double seconds, Func<double, bool> isSpeech, int channels = 1, int rate = SyntheticWav.Rate)
    {
        var wav = SyntheticWav.Build(seconds, isSpeech, channels: channels, rate: rate);
        return (wav, WavSilenceChunker.WholePlan(wav, WavSilenceChunker.ParseLayout(wav)!));
    }

    /// <summary>Tail start in chunk seconds for a transcript ending at <paramref name="lastEnd"/>, on a sample boundary.</summary>
    private static double TailStart(double lastEnd) => Math.Floor((lastEnd - ChunkedWhisperTranscriber.TailOverlapSeconds) * SyntheticWav.Rate) / SyntheticWav.Rate;

    private static double Seconds(WavChunkContent audio) => Seconds((int)audio.Headers.ContentLength!.Value - WavSilenceChunker.WavHeaderLength);

    private static double Seconds(int pcmBytes) => pcmBytes / 2.0 / SyntheticWav.Rate;

    private static WhisperTranscriptionResult Result(params (double Start, double End, string Text)[] segments) =>
        new(string.Join(" ", segments.Select(s => s.Text.Trim())), "en", segments.Select(s => new WhisperSegment(s.Start, s.End, s.Text)).ToList());

    private static MockHttpResponse WhisperJson(params (double Start, double End, string Text)[] segments) => WhisperJson("en", segments);

    private static MockHttpResponse WhisperJson(string language, params (double Start, double End, string Text)[] segments) => new("application/json", JsonSerializer.Serialize(new
    {
        text = string.Join(" ", segments.Select(s => s.Text)),
        language,
        segments = segments.Select(s => new { start = s.Start, end = s.End, text = s.Text })
    }, JsonOptions));

    /// <summary>Content type of the uploaded audio part of the multipart request.</summary>
    private static string UploadContentType(HttpListenerRequest request)
    {
        using var body = new MemoryStream();
        request.InputStream.CopyTo(body);
        var text = Encoding.Latin1.GetString(body.ToArray());
        var header = text.IndexOf("Content-Type: audio/", StringComparison.OrdinalIgnoreCase);
        return header < 0 ? "" : text[(header + "Content-Type: ".Length)..].Split('\r')[0].Trim();
    }
}
