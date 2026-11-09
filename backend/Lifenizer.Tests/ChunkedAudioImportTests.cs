using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.Extensions.Logging.Abstractions;

namespace Lifenizer.Tests;

/// <summary>Long WAV recordings are split on silence and transcribed in parallel chunks.</summary>
public sealed class ChunkedAudioImportTests
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    [Test]
    public async Task LongWav_IsTranscribedInBoundedParallelChunks_WithShiftedMonotonicSegments()
    {
        var wav = SyntheticWav.Build(120, SyntheticWav.SentencePattern);
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
        var wav = SyntheticWav.Build(120, SyntheticWav.SentencePattern);
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
        var wav = SyntheticWav.Build(120, SyntheticWav.SentencePattern);
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
        var wav = SyntheticWav.Build(120, SyntheticWav.SentencePattern);
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
        var wav = SyntheticWav.Build(120, SyntheticWav.SentencePattern);
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
        var wav = SyntheticWav.Build(120, SyntheticWav.SentencePattern);
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
        var wav = SyntheticWav.Build(120, SyntheticWav.SentencePattern);
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
        var wav = SyntheticWav.Build(120, SyntheticWav.SentencePattern);
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
    public async Task QueueWaitOnGlobalLimit_DoesNotCountTowardsChunkTimeout()
    {
        var wav = SyntheticWav.Build(240, SyntheticWav.SentencePattern);
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
        var wav = SyntheticWav.Build(10, SyntheticWav.SentencePattern);
        await using var whisper = new ConcurrentWhisper(wav, new WavChunkPlan(new WavFormat(16000, 1), []), (_, _) => ConcurrentWhisper.Ok, acceptAny: true);
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = whisper.Url,
            ["Whisper:MaxConcurrentRequests"] = "1",
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
        var wav = SyntheticWav.Build(60, SyntheticWav.SentencePattern);
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
        new(NullLogger<ChunkedWhisperTranscriber>.Instance, maxConcurrent, TimeSpan.FromSeconds(timeoutSeconds));

    private static ImportRequest Request(byte[] wav) =>
        new(OriginalFileName: "long.wav", MimeType: "audio/wav", PayloadBase64: Convert.ToBase64String(wav));

    internal static LifenizerApiFactory FactoryFor(ConcurrentWhisper whisper, int maxParallel, int? maxConcurrent = null) => new(new Dictionary<string, string?>
    {
        ["Whisper:BaseUrl"] = whisper.Url,
        ["Whisper:MaxParallelChunks"] = maxParallel.ToString(),
        ["Whisper:MaxConcurrentRequests"] = (maxConcurrent ?? 4).ToString()
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
