using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Lifenizer.Tests;

/// <summary>Long WAV recordings are split on silence and transcribed in parallel chunks.</summary>
public sealed class ChunkedAudioImportTests
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    [Test]
    public async Task LongWav_IsTranscribedInBoundedParallelChunks_WithShiftedMonotonicSegments()
    {
        var wav = SyntheticWav.Build(120, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        await using var whisper = new ConcurrentWhisper(wav, plan, (_, _) => ConcurrentWhisper.Ok);
        await using var factory = FactoryFor(whisper, maxParallel: 3);
        using var client = await AuthenticatedClientAsync(factory, "chunk-parallel@example.test");

        var result = await ImportAsync(client, wav);

        var segments = result.Conversations[0].Segments;
        Assert.Multiple(() =>
        {
            Assert.That(whisper.Calls.Count, Is.EqualTo(plan.Chunks.Count));
            Assert.That(whisper.MaxConcurrency, Is.GreaterThan(1).And.LessThanOrEqualTo(3));
            Assert.That(segments, Has.Count.EqualTo(plan.Chunks.Count));
            Assert.That(segments.Select(s => s.OffsetMs), Is.Ordered.Ascending);
            for (var i = 0; i < segments.Count; i++)
            {
                var expected = (int)Math.Round(plan.Chunks[i].Start.TotalMilliseconds + 500);
                Assert.That(segments[i].OffsetMs, Is.EqualTo(expected).Within(1));
                Assert.That(segments[i].EndMs, Is.GreaterThan(segments[i].OffsetMs));
                Assert.That(segments[i].Text, Is.EqualTo($"chunk {i}"));
            }
            Assert.That(result.Conversations[0].Metadata!["language"], Is.EqualTo("en"));
        });
    }

    [Test]
    public async Task TransientFailureOnOneChunk_IsRetriedOnce_AndImportSucceeds()
    {
        var wav = SyntheticWav.Build(120, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        await using var whisper = new ConcurrentWhisper(wav, plan, (index, attempt) =>
            index == 2 && attempt == 1 ? new MockHttpResponse("text/plain", "busy", 503) : ConcurrentWhisper.Ok);
        await using var factory = FactoryFor(whisper, maxParallel: 4);
        using var client = await AuthenticatedClientAsync(factory, "chunk-retry@example.test");

        var result = await ImportAsync(client, wav);

        Assert.That(result.Conversations[0].Segments, Has.Count.EqualTo(plan.Chunks.Count));
        Assert.That(whisper.Calls.Count(i => i == 2), Is.EqualTo(2));
    }

    [Test]
    public async Task PermanentFailureOnOneChunk_FailsImport_AndStopsRemainingChunks()
    {
        var wav = SyntheticWav.Build(120, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        await using var whisper = new ConcurrentWhisper(wav, plan, (index, _) =>
            index == 1 ? new MockHttpResponse("text/plain", "bad audio", 400) : ConcurrentWhisper.Ok);
        await using var factory = FactoryFor(whisper, maxParallel: 1);
        using var client = await AuthenticatedClientAsync(factory, "chunk-fail@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/audio", Request(wav), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(await response.Content.ReadAsStringAsync(), Does.Contain("Whisper transcription service").And.Contain("400"));
        Assert.That(whisper.Calls, Is.EqualTo(new[] { 0, 1 }), "400 is not retried and later chunks never start");
    }

    [Test]
    public async Task PersistentServerError_IsRetriedOnce_ThenFailsImport()
    {
        var wav = SyntheticWav.Build(120, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        await using var whisper = new ConcurrentWhisper(wav, plan, (index, _) =>
            index == 0 ? new MockHttpResponse("text/plain", "down", 500) : ConcurrentWhisper.Ok);
        await using var factory = FactoryFor(whisper, maxParallel: 1);
        using var client = await AuthenticatedClientAsync(factory, "chunk-500@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/audio", Request(wav), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(whisper.Calls, Is.EqualTo(new[] { 0, 0 }));
    }

    [Test]
    public async Task Cancellation_StopsStartingChunks_AndThrowsOperationCanceled()
    {
        var wav = SyntheticWav.Build(120, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        using var transcriber = NewTranscriber();
        using var cts = new CancellationTokenSource();
        var started = 0;

        var run = transcriber.TranscribeAsync(wav, plan, maxParallel: 2, async (_, token) =>
        {
            if (Interlocked.Increment(ref started) == 2) cts.Cancel();
            await Task.Delay(Timeout.Infinite, token);
            return new WhisperTranscriptionResult("", null, []);
        }, cts.Token);

        Assert.CatchAsync<OperationCanceledException>(async () => await run);
        await Task.Delay(200);
        Assert.That(started, Is.EqualTo(2));
    }

    [Test]
    public async Task FailureOfOneChunk_CancelsInFlightSiblings()
    {
        var wav = SyntheticWav.Build(120, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        using var transcriber = NewTranscriber();
        var siblingCancelled = new TaskCompletionSource();
        var calls = 0;

        var run = transcriber.TranscribeAsync(wav, plan, maxParallel: 2, async (_, token) =>
        {
            if (Interlocked.Increment(ref calls) == 1)
            {
                try { await Task.Delay(Timeout.Infinite, token); }
                catch (OperationCanceledException) { siblingCancelled.SetResult(); throw; }
            }
            throw new InvalidOperationException("whisper exploded");
        }, CancellationToken.None);

        var error = Assert.ThrowsAsync<InvalidOperationException>(async () => await run);
        Assert.That(error!.Message, Is.EqualTo("whisper exploded"));
        Assert.That(await Task.WhenAny(siblingCancelled.Task, Task.Delay(2000)), Is.SameAs(siblingCancelled.Task));
        Assert.That(calls, Is.EqualTo(2));
    }

    [Test]
    public async Task FullySilentLongWav_FailsWithoutCallingWhisper()
    {
        var wav = SyntheticWav.Build(120, _ => false);
        await using var whisper = new ConcurrentWhisper(wav, new WavChunkPlan(new WavFormat(16000, 1), []), (_, _) => ConcurrentWhisper.Ok);
        await using var factory = FactoryFor(whisper, maxParallel: 4);
        using var client = await AuthenticatedClientAsync(factory, "chunk-silent@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/audio", Request(wav), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(await response.Content.ReadAsStringAsync(), Does.Contain("no usable text"));
        Assert.That(whisper.Calls, Is.Empty);
    }

    [Test]
    public async Task TwoSimultaneousImports_ShareTheGlobalRequestLimit()
    {
        var wav = SyntheticWav.Build(120, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        await using var whisper = new ConcurrentWhisper(wav, plan, (_, _) => ConcurrentWhisper.Ok);
        await using var factory = FactoryFor(whisper, maxParallel: 4, maxConcurrent: 3);
        using var first = await AuthenticatedClientAsync(factory, "chunk-global-a@example.test");
        using var second = await AuthenticatedClientAsync(factory, "chunk-global-b@example.test");

        await Task.WhenAll(ImportAsync(first, wav), ImportAsync(second, wav));

        Assert.That(whisper.Calls.Count, Is.EqualTo(plan.Chunks.Count * 2));
        Assert.That(whisper.MaxConcurrency, Is.GreaterThan(1).And.LessThanOrEqualTo(3));
    }

    [Test]
    public async Task ChunkTimeout_FailsWithTimeoutError_AndIsNotRetried()
    {
        var wav = SyntheticWav.Build(120, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        using var transcriber = NewTranscriber(timeoutSeconds: 0.2);
        var calls = 0;

        var run = transcriber.TranscribeAsync(wav, plan, maxParallel: 1, async (_, token) =>
        {
            Interlocked.Increment(ref calls);
            await Task.Delay(Timeout.Infinite, token);
            return new WhisperTranscriptionResult("", null, []);
        }, CancellationToken.None);

        Assert.ThrowsAsync<WhisperTimeoutException>(async () => await run);
        Assert.That(calls, Is.EqualTo(1));
    }

    [Test]
    public void ChunkTimeout_ScalesWithChunkAudioLengthAndGlobalConcurrency()
    {
        var baseTimeout = TimeSpan.FromSeconds(180);

        Assert.Multiple(() =>
        {
            Assert.That(ChunkedWhisperTranscriber.TimeoutFor(baseTimeout, 20, 2.0, 4), Is.EqualTo(baseTimeout), "short chunk keeps the base");
            Assert.That(ChunkedWhisperTranscriber.TimeoutFor(baseTimeout, 300, 2.0, 1), Is.EqualTo(TimeSpan.FromSeconds(600)));
            Assert.That(ChunkedWhisperTranscriber.TimeoutFor(baseTimeout, 300, 2.0, 4), Is.EqualTo(TimeSpan.FromSeconds(2400)), "requests queue inside whisper");
            Assert.That(ChunkedWhisperTranscriber.TimeoutFor(baseTimeout, 300, 0, 4), Is.EqualTo(baseTimeout));
            Assert.That(ChunkedWhisperTranscriber.TimeoutFor(baseTimeout, 1e9, 20, 64), Is.EqualTo(TimeSpan.FromHours(6)), "capped");
            Assert.That(ChunkedWhisperTranscriber.TimeoutFor(baseTimeout, double.NaN, 2, 4), Is.EqualTo(baseTimeout));
            // A 28 s chunk behind 3 queued ones in whisper (one at a time, ~10 s overhead each) needs about
            // 4 x (10 s + 28 s at real time) = 152 s; the scaled 224 s covers that even at real-time speed.
            Assert.That(ChunkedWhisperTranscriber.TimeoutFor(baseTimeout, 28, 2.0, 4), Is.EqualTo(TimeSpan.FromSeconds(224)));
            Assert.That(ChunkedWhisperTranscriber.TimeoutFor(baseTimeout, 28, 2.0, 1), Is.EqualTo(baseTimeout), "a lone 28 s chunk keeps the base");
        });
    }

    [Test]
    public async Task ChunkPlan_AndEachFinishedChunk_AreLoggedAtInformation()
    {
        var wav = SyntheticWav.Build(70, _ => true);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        var logger = new ListLogger<ChunkedWhisperTranscriber>();
        using var transcriber = new ChunkedWhisperTranscriber(logger, 2, TimeSpan.FromSeconds(30), timeoutPerAudioSecond: 0);

        await transcriber.TranscribeAsync(wav, plan, 2, (_, _) => Task.FromResult(new WhisperTranscriptionResult("x", "en", [])), CancellationToken.None);

        var planLines = logger.Lines.Where(l => l.StartsWith("Planned ", StringComparison.Ordinal)).ToList();
        Assert.That(plan.Chunks, Has.Count.EqualTo(3));
        Assert.That(planLines, Has.Count.EqualTo(1), "one plan line per file");
        Assert.That(planLines[0], Does.Contain("Planned 3 audio chunks").And.Contain("#1 0.0+28.0").And.Contain("#2 28.0+28.0").And.Contain("#3 56.0+14.0"));
        var finished = logger.Lines.Where(l => l.StartsWith("Transcribed audio chunk ", StringComparison.Ordinal)).ToList();
        Assert.That(finished, Has.Count.EqualTo(3));
        Assert.That(finished, Has.All.Match(@"^Transcribed audio chunk [1-3]/3 \(start \d+[.,]\d s, length \d+[.,]\d s\): whisper \d+ ms, queued \d+ ms, 1 attempt\(s\)$"));
    }

    [Test]
    public async Task ChunkLog_SeparatesWhisperTimeFromTheWaitForAGlobalSlot()
    {
        var wav = SyntheticWav.Build(70, _ => true);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        var logger = new ListLogger<ChunkedWhisperTranscriber>();
        using var transcriber = new ChunkedWhisperTranscriber(logger, 1, TimeSpan.FromSeconds(30), timeoutPerAudioSecond: 0);

        // one global slot, three chunks in parallel: they queue behind each other for ~300 ms each
        await transcriber.TranscribeAsync(wav, plan, 3, async (_, token) =>
        {
            await Task.Delay(300, token);
            return new WhisperTranscriptionResult("x", "en", []);
        }, CancellationToken.None);

        var finished = logger.Entries.Where(e => e.Values.ContainsKey("WhisperMs")).ToList();
        Assert.That(finished, Has.Count.EqualTo(3));
        Assert.That(finished.Select(e => (long)e.Values["WhisperMs"]!), Has.All.InRange(250L, 5000L), "whisper time excludes the queue");
        Assert.That(finished.Max(e => (long)e.Values["QueuedMs"]!), Is.GreaterThanOrEqualTo(500L), "the last chunk waited for two others");
    }

    [Test]
    public async Task PlanLine_ListsAtMostFiftyChunks()
    {
        // 60 one-second chunks over a small buffer; only the plan matters here
        var wav = new byte[44 + SyntheticWav.Rate * 2];
        var plan = new WavChunkPlan(new WavFormat(SyntheticWav.Rate, 1),
            Enumerable.Range(0, 60).Select(i => new WavChunk(44, SyntheticWav.Rate * 2, TimeSpan.FromSeconds(i * 28))).ToList());
        var logger = new ListLogger<ChunkedWhisperTranscriber>();
        using var transcriber = new ChunkedWhisperTranscriber(logger, 64, TimeSpan.FromSeconds(30), timeoutPerAudioSecond: 0);

        await transcriber.TranscribeAsync(wav, plan, 16, (_, _) => Task.FromResult(new WhisperTranscriptionResult("x", "en", [])), CancellationToken.None);

        var planLine = logger.Lines.Single(l => l.StartsWith("Planned ", StringComparison.Ordinal));
        var more = plan.Chunks.Count - ChunkedWhisperTranscriber.MaxLoggedPlanEntries;
        Assert.That(more, Is.GreaterThan(0));
        Assert.That(planLine, Does.Contain("#50 ").And.Not.Contain("#51 ").And.EndWith($", … {more} more"));
        Assert.That(planLine.Length, Is.LessThan(16 * 1024));
    }

    [Test]
    public async Task ChunkBody_IsIdenticalToAStandaloneWav_WithoutACopy()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.PausedPattern);
        var layout = WavSilenceChunker.ParseLayout(wav)!;
        var plan = WavSilenceChunker.TryPlan(wav, layout)!;

        foreach (var chunk in plan.Chunks)
        {
            using var content = new WavChunkContent(wav, plan.Format, chunk);
            Assert.That(await content.ReadAsByteArrayAsync(), Is.EqualTo(WavSilenceChunker.ToWav(wav, plan.Format, chunk)));
            Assert.That(content.Headers.ContentLength, Is.EqualTo(44 + chunk.ByteLength));
        }
    }

    [Test]
    public void WholeFileTimeout_ThrowsWhisperTimeout_ButUserCancellationStaysCancellation()
    {
        Assert.ThrowsAsync<WhisperTimeoutException>(async () =>
            await ChunkedWhisperTranscriber.WithTimeoutAsync(TimeSpan.FromMilliseconds(100), async token =>
            {
                await Task.Delay(Timeout.Infinite, token);
                return 0;
            }, CancellationToken.None));

        using var cts = new CancellationTokenSource(100);
        Assert.CatchAsync<OperationCanceledException>(async () =>
            await ChunkedWhisperTranscriber.WithTimeoutAsync(TimeSpan.FromMinutes(5), async token =>
            {
                await Task.Delay(Timeout.Infinite, token);
                return 0;
            }, cts.Token));
        Assert.That(cts.IsCancellationRequested, Is.True);
    }

    [Test]
    public async Task LongChunk_GetsALongerTimeoutThanTheBase()
    {
        var wav = SyntheticWav.Build(60, t => true);
        var plan = new WavChunkPlan(new WavFormat(SyntheticWav.Rate, 1), [new WavChunk(44, 60 * SyntheticWav.Rate * 2, TimeSpan.Zero)]);
        using var transcriber = new ChunkedWhisperTranscriber(NullLogger<ChunkedWhisperTranscriber>.Instance, 1, TimeSpan.FromSeconds(0.1), timeoutPerAudioSecond: 0.02);

        // base 0.1 s would time out; 60 s * 0.02 = 1.2 s lets the 0.4 s request finish.
        var result = await transcriber.TranscribeAsync(wav, plan, 1, async (_, token) =>
        {
            await Task.Delay(400, token);
            return new WhisperTranscriptionResult("done", "en", []);
        }, CancellationToken.None);

        Assert.That(result.Text, Is.EqualTo("done"));
    }

    [Test]
    public async Task QueueWaitOnGlobalLimit_DoesNotCountTowardsChunkTimeout()
    {
        var wav = SyntheticWav.Build(240, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        using var transcriber = NewTranscriber(maxConcurrent: 1, timeoutSeconds: 1);

        // 100 ms per request, one at a time: the last chunks queue for several seconds but must not time out.
        var result = await transcriber.TranscribeAsync(wav, plan, maxParallel: 16, async (_, token) =>
        {
            await Task.Delay(100, token);
            return new WhisperTranscriptionResult("ok", "en", []);
        }, CancellationToken.None);

        Assert.That(plan.Chunks.Count, Is.GreaterThan(15));
        Assert.That(result.Text.Split(' '), Has.Length.EqualTo(plan.Chunks.Count));
    }

    [Test]
    public async Task WholeFileRequests_AreAlsoLimitedByTheGlobalGate()
    {
        var wav = SyntheticWav.Build(10, SyntheticWav.PausedPattern);
        await using var whisper = new ConcurrentWhisper(wav, new WavChunkPlan(new WavFormat(16000, 1), []), (_, _) => ConcurrentWhisper.Ok, acceptAny: true);
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = whisper.Url,
            ["Whisper:MaxConcurrentRequests"] = "1",
            ["Whisper:TailRecoverySeconds"] = "0",
            ["Imports:MaxConcurrentAudioImportsPerUser"] = "10"
        });
        using var client = await AuthenticatedClientAsync(factory, "whole-gate@example.test");

        await Task.WhenAll(ImportAsync(client, wav), ImportAsync(client, wav), ImportAsync(client, wav));

        Assert.That(whisper.Calls.Count, Is.EqualTo(3));
        Assert.That(whisper.MaxConcurrency, Is.EqualTo(1));
    }

    [Test]
    public void Merge_PicksMostFrequentLanguage_AndJoinsText()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        var n = plan.Chunks.Count;
        var results = Enumerable.Range(0, n)
            .Select(i => new WhisperTranscriptionResult($" t{i} ", i == 0 ? "de" : "en", [new WhisperSegment(1, 2, $"t{i}")])).ToArray();

        var merged = ChunkedWhisperTranscriber.Merge(plan, results);

        Assert.That(merged.Language, Is.EqualTo("en"));
        Assert.That(merged.Text, Is.EqualTo(string.Join(" ", Enumerable.Range(0, n).Select(i => $"t{i}"))));
        Assert.That(merged.Segments[1].Start, Is.EqualTo(plan.Chunks[1].Start.TotalSeconds + 1).Within(1e-9));
    }

    private static ChunkedWhisperTranscriber NewTranscriber(int maxConcurrent = 4, double timeoutSeconds = 180) =>
        new(NullLogger<ChunkedWhisperTranscriber>.Instance, maxConcurrent, TimeSpan.FromSeconds(timeoutSeconds), timeoutPerAudioSecond: 0);

    private static ImportRequest Request(byte[] wav) =>
        new(OriginalFileName: "long.wav", MimeType: "audio/wav", PayloadBase64: Convert.ToBase64String(wav));

    /// <summary>Tail recovery is off: the fake answers every chunk with a 0.5-1.0 s segment and cannot identify tail requests.</summary>
    internal static LifenizerApiFactory FactoryFor(ConcurrentWhisper whisper, int maxParallel, int? maxConcurrent = null) => new(new Dictionary<string, string?>
    {
        ["Whisper:BaseUrl"] = whisper.Url,
        ["Whisper:MaxParallelChunks"] = maxParallel.ToString(),
        ["Whisper:MaxConcurrentRequests"] = (maxConcurrent ?? 4).ToString(),
        ["Whisper:TailRecoverySeconds"] = "0"
    });

    internal static async Task<NormalizedImportResponse> ImportAsync(HttpClient client, byte[] wav)
    {
        var response = await client.PostAsJsonAsync("/api/imports/audio", Request(wav), JsonOptions);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<NormalizedImportResponse>(JsonOptions)
            ?? throw new InvalidOperationException("Import response was empty.");
    }

    internal static async Task<HttpClient> AuthenticatedClientAsync(LifenizerApiFactory factory, string email)
    {
        var client = factory.CreateClient();
        var response = await client.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest(email, email.Split('@')[0]), JsonOptions);
        response.EnsureSuccessStatusCode();
        var auth = await response.Content.ReadFromJsonAsync<AuthResponse>(JsonOptions)
            ?? throw new InvalidOperationException("Auth response was empty.");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);
        return client;
    }

    /// <summary>
    /// Fake whisper that serves requests concurrently. It identifies which plan chunk a request
    /// carries by comparing the uploaded WAV, then answers with one segment "chunk N" at 0.5-1.0 s.
    /// </summary>
    internal sealed class ConcurrentWhisper : IAsyncDisposable
    {
        public static readonly MockHttpResponse Ok = new("", "");

        private readonly HttpListener listener = new();
        private readonly Func<int, int, MockHttpResponse> respond;
        private readonly byte[][] chunkWavs;
        private readonly Dictionary<int, int> attempts = [];
        private readonly object gate = new();
        private int current;

        private readonly bool acceptAny;

        public ConcurrentWhisper(byte[] wav, WavChunkPlan plan, Func<int, int, MockHttpResponse> respond, bool acceptAny = false)
        {
            this.respond = respond;
            this.acceptAny = acceptAny;
            chunkWavs = plan.Chunks.Select(c => WavSilenceChunker.ToWav(wav, plan.Format, c)).ToArray();
            var port = FreePort();
            Url = $"http://127.0.0.1:{port}/";
            listener.Prefixes.Add(Url);
            listener.Start();
            _ = Task.Run(AcceptLoopAsync);
        }

        public string Url { get; }
        public int MaxConcurrency { get; private set; }
        public List<int> Calls { get; } = [];

        public ValueTask DisposeAsync()
        {
            listener.Close();
            return ValueTask.CompletedTask;
        }

        private async Task AcceptLoopAsync()
        {
            while (listener.IsListening)
            {
                HttpListenerContext context;
                try { context = await listener.GetContextAsync(); }
                catch (Exception) { return; }
                _ = Task.Run(() => HandleAsync(context));
            }
        }

        private async Task HandleAsync(HttpListenerContext context)
        {
            var bytes = await ReadUploadAsync(context.Request);
            var index = acceptAny ? 0 : Array.FindIndex(chunkWavs, c => c.AsSpan().SequenceEqual(bytes));
            int attempt;
            lock (gate)
            {
                attempt = attempts[index] = attempts.GetValueOrDefault(index) + 1;
                Calls.Add(index);
                MaxConcurrency = Math.Max(MaxConcurrency, ++current);
            }
            await Task.Delay(150);
            var reply = index < 0 ? new MockHttpResponse("text/plain", "unexpected upload bytes", 422) : respond(index, attempt);
            lock (gate) current--;
            await WriteAsync(context, reply.Body.Length == 0 && reply.StatusCode == 200 ? Success(index) : reply);
        }

        private static MockHttpResponse Success(int index) => new("application/json", JsonSerializer.Serialize(new
        {
            text = $"chunk {index}",
            language = "en",
            segments = new[] { new { start = 0.5, end = 1.0, text = $"chunk {index}" } }
        }, JsonOptions));

        private static async Task WriteAsync(HttpListenerContext context, MockHttpResponse reply)
        {
            var body = Encoding.UTF8.GetBytes(reply.Body);
            context.Response.StatusCode = reply.StatusCode;
            context.Response.ContentType = reply.ContentType;
            context.Response.ContentLength64 = body.Length;
            await context.Response.OutputStream.WriteAsync(body);
            context.Response.Close();
        }

        private static async Task<byte[]> ReadUploadAsync(HttpListenerRequest request)
        {
            var boundary = new System.Net.Mime.ContentType(request.ContentType!).Boundary!;
            var section = await new MultipartReader(boundary, request.InputStream).ReadNextSectionAsync();
            using var memory = new MemoryStream();
            await section!.Body.CopyToAsync(memory);
            return memory.ToArray();
        }

        private static int FreePort()
        {
            var tcp = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
            tcp.Start();
            var port = ((IPEndPoint)tcp.LocalEndpoint).Port;
            tcp.Stop();
            return port;
        }
    }
}
