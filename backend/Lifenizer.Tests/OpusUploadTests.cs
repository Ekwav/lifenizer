using System.Buffers.Binary;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Concentus;
using Concentus.Enums;
using Concentus.Oggfile;
using Lifenizer.Api.Services;
using Lifenizer.Core;

namespace Lifenizer.Tests;

/// <summary>Ogg Opus decoding and the multipart POST /api/imports/audio/upload route.</summary>
public sealed class OpusUploadTests
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private const double Tolerance = 0.05;

    /// <summary>1 s lead-in silence, then 4 s speech / 11 s silence.</summary>
    private static bool Speech(double t) => t >= 1 && (t - 1) % 15 < 4;

    [Test]
    public void Decoder_RemovesPreSkip_SoTimingMatchesTheInput()
    {
        var ogg = OggTestKit.PatchPreSkip(EncodeOpus(10, Speech), 4800); // 100 ms at 48 kHz

        var pcm = Decode(ogg);

        Assert.That(pcm.Length / 2.0 / OggOpusDecoder.SampleRate, Is.EqualTo(9.9).Within(Tolerance));
        Assert.That(FirstLoudSecond(pcm), Is.EqualTo(0.9).Within(Tolerance));
    }

    [Test]
    public void IsOgg_DetectsMagicBytes()
    {
        Assert.Multiple(() =>
        {
            Assert.That(OggOpusDecoder.IsOgg(EncodeOpus(1, Speech)), Is.True);
            Assert.That(OggOpusDecoder.IsOgg(VorbisBytes()), Is.True);
            Assert.That(OggOpusDecoder.IsOgg(SyntheticWav.Build(1, Speech)), Is.False);
        });
    }

    [Test]
    public void Vorbis_IsRejected()
    {
        Assert.Throws<UnsupportedAudioException>(() => Source(VorbisBytes()));
    }

    [Test]
    public void ShortCleanOpus_IsSentWholeWithoutDecoding()
    {
        Assert.That(Source(EncodeOpus(10, Speech)), Is.Null);
    }

    [Test]
    public void TruncatedOpus_IsRejected()
    {
        Assert.Throws<UnsupportedAudioException>(() => Source(EncodeOpus(60, Speech)[..40]));
    }

    [Test]
    public void BadCrcPage_IsRejected()
    {
        var damaged = OggTestKit.BreakCrc(EncodeOpus(60, Speech), pageIndex: 5);

        Assert.Throws<UnsupportedAudioException>(() => Source(damaged));
    }

    [Test]
    public void SecondSerialInTheFile_IsRejected()
    {
        var interleaved = OggTestKit.PatchSerial(EncodeOpus(60, Speech), pageIndex: 5, serial: 99);

        Assert.Throws<UnsupportedAudioException>(() => Source(interleaved));
    }

    [Test]
    public void CorruptPacketWithValidCrc_IsRejected_AndNeverHangs()
    {
        var corrupt = OggTestKit.CorruptPacket(EncodeOpus(60, Speech), pageIndex: 10);

        var task = Task.Run(() => Source(corrupt));

        Assert.That(Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(20))).Result, Is.SameAs(task), "decoder did not finish");
        Assert.That(task.Exception!.GetBaseException(), Is.TypeOf<UnsupportedAudioException>());
    }

    [Test]
    public void ChainedStreams_AreRejected()
    {
        var chained = EncodeOpus(40, Speech).Concat(EncodeOpus(40, Speech)).ToArray();

        Assert.Throws<UnsupportedAudioException>(() => Source(chained));
    }

    [Test]
    public void DtxBomb_IsRejectedByTheDurationCap_BeforeDecoding()
    {
        var bomb = OggTestKit.DtxBomb(packets: 600, granule: 600L * 5760); // 72 s claimed and real

        var error = Assert.Throws<AudioTooLongException>(() => Source(bomb, max: 60));
        Assert.That(error!.Message, Does.Contain("60"));
    }

    [Test]
    public void LyingGranule_CannotMakeTheDecoderProduceMoreThanClaimed()
    {
        var bomb = OggTestKit.DtxBomb(packets: 600, granule: 40L * 48000); // claims 40 s, holds 72 s

        var pcm = OggOpusDecoder.DecodeToPcm16(bomb, OpusStreamScanner.Scan(bomb), 100, CancellationToken.None);
        Assert.That(pcm.Length, Is.EqualTo(40 * OggOpusDecoder.SampleRate * 2));
    }

    [Test]
    public void Decoding_HonoursCancellation()
    {
        var ogg = EncodeOpus(60, Speech);
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        Assert.Catch<OperationCanceledException>(() => Source(ogg, ct: cts.Token));
    }

    [Test]
    public async Task Upload_OpusLongRecording_IsChunkedTranscribedAndMergedWithCorrectOffsets()
    {
        var ogg = EncodeOpus(120, Speech);
        var source = Source(ogg)!;
        await using var whisper = new ChunkedAudioImportTests.ConcurrentWhisper(source.Bytes, source.Plan, (_, _) => ChunkedAudioImportTests.ConcurrentWhisper.Ok);
        await using var factory = ChunkedAudioImportTests.FactoryFor(whisper, maxParallel: 3);
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "opus-upload@example.test");

        var response = await client.PostAsync("/api/imports/audio/upload", Multipart(ogg, "audio/ogg", new ImportRequest(Title: "Opus note", OriginalFileName: "note.ogg")));

        response.EnsureSuccessStatusCode();
        var result = (await response.Content.ReadFromJsonAsync<NormalizedImportResponse>(JsonOptions))!;
        var segments = result.Conversations[0].Segments;
        Assert.Multiple(() =>
        {
            Assert.That(result.Conversations[0].Title, Is.EqualTo("Opus note"));
            Assert.That(whisper.Calls.Count, Is.EqualTo(source.Plan.Chunks.Count).And.GreaterThan(5));
            Assert.That(whisper.MaxConcurrency, Is.GreaterThan(1).And.LessThanOrEqualTo(3));
            Assert.That(segments.Select(s => s.OffsetMs), Is.Ordered.Ascending);
            for (var i = 0; i < segments.Count; i++)
            {
                Assert.That(segments[i].OffsetMs / 1000.0, Is.EqualTo(source.Plan.Chunks[i].Start.TotalSeconds + 0.5).Within(Tolerance));
            }
        });
        foreach (var chunk in source.Plan.Chunks.Skip(1))
        {
            Assert.That(Speech(chunk.Start.TotalSeconds), Is.False, $"cut at {chunk.Start} is inside speech");
        }
    }

    [Test]
    public async Task Upload_WavPart_WorksToo()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        await using var whisper = new ChunkedAudioImportTests.ConcurrentWhisper(wav, plan, (_, _) => ChunkedAudioImportTests.ConcurrentWhisper.Ok);
        await using var factory = ChunkedAudioImportTests.FactoryFor(whisper, maxParallel: 3);
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "wav-upload@example.test");

        var response = await client.PostAsync("/api/imports/audio/upload", Multipart(wav, "audio/wav", new ImportRequest()));

        response.EnsureSuccessStatusCode();
        var result = (await response.Content.ReadFromJsonAsync<NormalizedImportResponse>(JsonOptions))!;
        Assert.That(result.Conversations[0].Segments.Select(s => s.Text),
            Is.EqualTo(Enumerable.Range(0, plan.Chunks.Count).Select(i => $"chunk {i}")));
    }

    [Test]
    public async Task JsonEndpoint_StillWorksForBase64Wav()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        await using var whisper = new ChunkedAudioImportTests.ConcurrentWhisper(wav, plan, (_, _) => ChunkedAudioImportTests.ConcurrentWhisper.Ok);
        await using var factory = ChunkedAudioImportTests.FactoryFor(whisper, maxParallel: 3);
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "json-still@example.test");

        var result = await ChunkedAudioImportTests.ImportAsync(client, wav);

        Assert.That(result.Conversations[0].Segments, Has.Count.EqualTo(plan.Chunks.Count));
    }

    [Test]
    public async Task Upload_UndecodableOrDamagedOgg_IsRejectedAndNeverForwarded()
    {
        await AssertRejectedWithoutForwarding(OggTestKit.CorruptPacket(EncodeOpus(60, Speech), pageIndex: 10), "corrupt@example.test");
        await AssertRejectedWithoutForwarding(OggTestKit.BreakCrc(EncodeOpus(60, Speech), pageIndex: 5), "badcrc@example.test");
        await AssertRejectedWithoutForwarding(OggTestKit.PatchSerial(EncodeOpus(60, Speech), pageIndex: 5, serial: 99), "interleaved@example.test");
        await AssertRejectedWithoutForwarding(VorbisBytes(), "vorbis@example.test");
    }

    [Test]
    public void Wav_WithTinySampleRate_IsRejectedWithBoundedAllocation()
    {
        var wav = SyntheticWav.Build(50_000_000 / 2.0, _ => true, rate: 1); // 50 MB at 1 Hz
        var before = GC.GetTotalAllocatedBytes(precise: true);

        Assert.Throws<UnsupportedAudioException>(() => Source(wav));

        Assert.That(GC.GetTotalAllocatedBytes(precise: true) - before, Is.LessThan(5_000_000));
    }

    [Test]
    public void Wav_OverTheCap_IsRejectedBeforePlanning()
    {
        var wav = SyntheticWav.Build(120, SyntheticWav.PausedPattern);
        var before = GC.GetTotalAllocatedBytes(precise: true);

        Assert.Throws<AudioTooLongException>(() => Source(wav, max: 60));

        Assert.That(GC.GetTotalAllocatedBytes(precise: true) - before, Is.LessThan(1_000_000));
    }

    [Test]
    public void BufferGrowth_NeverExceedsContentLength_SoTheFinalBufferIsNotOversized()
    {
        const long contentLength = 150_000_000;
        var size = 8 * 1024 * 1024;
        var steps = new List<int>();
        while (AudioUploadReader.NextBufferSize(size, 200_000_000, contentLength) is var next && next > size)
        {
            steps.Add(size = next);
        }

        Assert.That(steps.Last(), Is.EqualTo(contentLength));
        Assert.That(steps, Is.All.LessThanOrEqualTo(contentLength));
    }

    [Test]
    public async Task Upload_GlobalAudioLimit_Gives429AcrossUsers()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        using var release = new ManualResetEventSlim();
        await using var whisper = new ChunkedAudioImportTests.ConcurrentWhisper(wav, plan, (_, _) =>
        {
            release.Wait(TimeSpan.FromSeconds(20));
            return ChunkedAudioImportTests.ConcurrentWhisper.Ok;
        });
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = whisper.Url,
            ["Imports:MaxConcurrentAudioImportsPerUser"] = "5",
            ["Imports:MaxConcurrentAudioImports"] = "1"
        });
        using var userA = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "global-a@example.test");
        using var userB = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "global-b@example.test");

        var first = userA.PostAsync("/api/imports/audio/upload", Multipart(wav, "audio/wav", new ImportRequest()));
        while (whisper.Calls.Count == 0) await Task.Delay(20);
        var other = await userB.PostAsync("/api/imports/audio/upload", Multipart(wav, "audio/wav", new ImportRequest()));
        var json = await userB.PostAsJsonAsync("/api/imports/audio", new ImportRequest(PayloadBase64: Convert.ToBase64String(wav)), JsonOptions);
        release.Set();

        Assert.That(other.StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
        Assert.That(json.StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
        Assert.That((await first).StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    [Test]
    public async Task Upload_TrailingSlashVariants_AreLimitedToo()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        using var release = new ManualResetEventSlim();
        await using var whisper = new ChunkedAudioImportTests.ConcurrentWhisper(wav, plan, (_, _) =>
        {
            release.Wait(TimeSpan.FromSeconds(20));
            return ChunkedAudioImportTests.ConcurrentWhisper.Ok;
        });
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = whisper.Url,
            ["Imports:MaxConcurrentAudioImportsPerUser"] = "1"
        });
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "slash@example.test");

        var first = client.PostAsync("/api/imports/audio/upload", Multipart(wav, "audio/wav", new ImportRequest()));
        while (whisper.Calls.Count == 0) await Task.Delay(20);
        var upload = await client.PostAsync("/api/imports/audio/upload/", Multipart(wav, "audio/wav", new ImportRequest()));
        var json = await client.PostAsJsonAsync("/api/imports/audio/", new ImportRequest(PayloadBase64: Convert.ToBase64String(wav)), JsonOptions);
        var upper = await client.PostAsJsonAsync("/api/imports/AUDIO", new ImportRequest(PayloadBase64: Convert.ToBase64String(wav)), JsonOptions);
        release.Set();

        Assert.That(new[] { upload.StatusCode, json.StatusCode, upper.StatusCode }, Is.All.EqualTo(HttpStatusCode.TooManyRequests));
        await first;
    }

    [Test]
    public async Task Upload_BeyondMaxAudioSeconds_IsRejectedAndNeverForwarded()
    {
        var bomb = OggTestKit.DtxBomb(packets: 600, granule: 600L * 5760);
        await using var whisper = new MockHttpServer(_ => new MockHttpResponse("application/json", "{}"));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = whisper.Url,
            ["Imports:MaxAudioSeconds"] = "60"
        });
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "opus-bomb@example.test");

        var response = await client.PostAsync("/api/imports/audio/upload", Multipart(bomb, "audio/ogg", new ImportRequest()));

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(await response.Content.ReadAsStringAsync(), Does.Contain("maximum"));
        Assert.That(whisper.RequestCount, Is.EqualTo(0));
    }

    [Test]
    public async Task Upload_MalformedMultipart_ReturnsBadRequest([Values("wrongBoundary", "truncated", "hugeHeader", "longBoundary")] string kind)
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, $"multipart-{kind}@example.test");
        var (body, boundary) = MalformedBody(kind);
        using var content = new ByteArrayContent(body);
        content.Headers.ContentType = MediaTypeHeaderValue.Parse($"multipart/form-data; boundary=\"{boundary}\"");

        var response = await client.PostAsync("/api/imports/audio/upload", content);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest), kind);
    }

    [Test]
    public async Task Upload_OversizedMetadata_NamesTheMetadataPart()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "opus-meta@example.test");
        var big = new ImportRequest(Title: new string('x', 1_100_000));

        var response = await client.PostAsync("/api/imports/audio/upload", Multipart(new byte[10], "audio/ogg", big));

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.RequestEntityTooLarge));
        Assert.That(await response.Content.ReadAsStringAsync(), Does.Contain("metadata"));
    }

    [Test]
    public async Task Upload_ChunkedBodyWithoutContentLength_OverTheLimit_IsRejected()
    {
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Imports:MaxRequestBytes"] = "20000" });
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "opus-chunked@example.test");
        using var form = new MultipartFormDataContent();
        var audio = new UnknownLengthContent(new byte[50_000]);
        audio.Headers.ContentType = new MediaTypeHeaderValue("audio/ogg");
        form.Add(audio, "audio", "big");

        var response = await client.PostAsync("/api/imports/audio/upload", form);

        Assert.That(form.Headers.ContentLength, Is.Null);
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.RequestEntityTooLarge));
    }

    [Test]
    public async Task Upload_WithoutAudioPart_ReturnsBadRequest()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "opus-missing@example.test");
        using var form = new MultipartFormDataContent { { new StringContent("{}", Encoding.UTF8, "application/json"), "metadata" } };

        var response = await client.PostAsync("/api/imports/audio/upload", form);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    [Test]
    public async Task Upload_RequiresAuthentication()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();

        var response = await client.PostAsync("/api/imports/audio/upload", Multipart(new byte[10], "audio/ogg", new ImportRequest()));

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    [Test]
    public async Task Upload_OverTheRequestLimit_IsRejected()
    {
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Imports:MaxRequestBytes"] = "2000" });
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "opus-big@example.test");

        var response = await client.PostAsync("/api/imports/audio/upload", Multipart(new byte[5000], "audio/ogg", new ImportRequest()));

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.RequestEntityTooLarge));
    }

    [Test]
    public async Task Upload_AnnouncedHugeBodyThatStalls_DoesNotPinTheAnnouncedMemory()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "trickle@example.test");
        var before = GC.GetTotalAllocatedBytes(precise: true);
        using var content = new AnnouncedLengthContent(announced: 199_000_000, actual: 75);
        content.Headers.ContentType = MediaTypeHeaderValue.Parse("multipart/form-data; boundary=abc");

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try { await client.PostAsync("/api/imports/audio/upload", content, cts.Token); }
        catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException) { }

        Assert.That(GC.GetTotalAllocatedBytes(precise: true) - before, Is.LessThan(40_000_000));
    }

    [Test]
    public async Task Upload_RepeatedAudioOrMetadataParts_AreRejected([Values("audio", "metadata")] string name)
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, $"repeat-{name}@example.test");
        using var form = new MultipartFormDataContent();
        for (var i = 0; i < 3; i++) form.Add(new ByteArrayContent(Encoding.ASCII.GetBytes("{}")), name, "x");
        var before = GC.GetTotalAllocatedBytes(precise: true);

        var response = await client.PostAsync("/api/imports/audio/upload", form);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(GC.GetTotalAllocatedBytes(precise: true) - before, Is.LessThan(40_000_000));
    }

    [Test]
    public void ZeroLengthPacketBomb_AllocatesAlmostNothing()
    {
        var bomb = OggTestKit.ZeroLengthBomb(packets: 100_000, granule: 20L * 48000);
        var before = GC.GetTotalAllocatedBytes(precise: true);

        var source = Source(bomb);

        Assert.That(source, Is.Null, "nothing audible: forwarded whole");
        Assert.That(GC.GetTotalAllocatedBytes(precise: true) - before, Is.LessThan(30_000_000));
    }

    [Test]
    public void TwoByteCode3Bomb_WithLyingGranule_IsCappedByTocDuration()
    {
        var bomb = OggTestKit.DtxBomb(packets: 20_000, granule: 20L * 48000); // TOC: 2400 s

        Assert.Throws<AudioTooLongException>(() => Source(bomb, max: 600));
    }

    [Test]
    public async Task ConcurrentLargeDecodes_RespectTheMemoryBudget()
    {
        var ogg = OggTestKit.DtxBomb(packets: 2084, granule: 2084L * 5760); // ~250 s -> ~8 MB of PCM
        var budget = new AudioMemoryBudget(20);

        var runs = Enumerable.Range(0, 3).Select(_ => Task.Run(async () =>
        {
            using var source = await AudioChunking.TryCreateSourceAsync(ogg, new AudioLimits(AudioChunking.DefaultMaxAudioSeconds, budget), CancellationToken.None);
            await Task.Delay(300);
            return source is not null;
        })).ToArray();

        await Task.WhenAll(runs);
        Assert.That(budget.PeakUsedMb, Is.GreaterThan(0).And.LessThanOrEqualTo(20));
    }

    [Test]
    public void AudioLargerThanTheWholeBudget_IsRejected()
    {
        var ogg = OggTestKit.DtxBomb(packets: 2084, granule: 2084L * 5760);

        Assert.Throws<AudioMemoryBudgetExceededException>(() => Source(ogg, budget: new AudioMemoryBudget(4)));
    }

    [Test]
    public async Task MemoryBudget_QueuesAndHonoursCancellation()
    {
        var budget = new AudioMemoryBudget(10);
        using var held = await budget.AcquireAsync(8 << 20, CancellationToken.None);
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));

        Assert.CatchAsync<OperationCanceledException>(async () => await budget.AcquireAsync(5 << 20, cts.Token));
        held.Dispose();
        using var next = await budget.AcquireAsync(5 << 20, CancellationToken.None);
        Assert.That(budget.PeakUsedMb, Is.LessThanOrEqualTo(10));
    }

    [Test]
    public void OversizedPacket_IsRejectedAsInvalidOpus()
    {
        var ogg = OggTestKit.HugePacket(200 * 1024);

        Assert.Throws<InvalidOpusStreamException>(() => Source(ogg));
    }

    [Test]
    public async Task Upload_LyingGranuleWithChainedStream_OverTheCap_IsRejectedAndNeverForwarded()
    {
        var chained = OggTestKit.DtxBomb(packets: 20_000, granule: 20L * 48000).Concat(EncodeOpus(40, Speech)).ToArray();

        await AssertRejectedWithoutForwarding(chained, "chained-lie@example.test");
    }

    [Test]
    public async Task Upload_GranuleLongMaxValue_IsRejectedAndNeverForwarded()
    {
        await AssertRejectedWithoutForwarding(OggTestKit.DtxBomb(packets: 10, granule: long.MaxValue), "granule-max@example.test");
    }

    [Test]
    public async Task Upload_SecondConcurrentAudioImportOfOneUser_Gets429_ButOtherRoutesAreUnaffected()
    {
        var wav = SyntheticWav.Build(60, SyntheticWav.PausedPattern);
        var plan = WavSilenceChunker.TryPlan(wav)!;
        using var release = new ManualResetEventSlim();
        await using var whisper = new ChunkedAudioImportTests.ConcurrentWhisper(wav, plan, (_, _) =>
        {
            release.Wait(TimeSpan.FromSeconds(20));
            return ChunkedAudioImportTests.ConcurrentWhisper.Ok;
        });
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = whisper.Url,
            ["Imports:MaxConcurrentAudioImportsPerUser"] = "1"
        });
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, "per-user@example.test");

        var first = client.PostAsync("/api/imports/audio/upload", Multipart(wav, "audio/wav", new ImportRequest()));
        while (whisper.Calls.Count == 0) await Task.Delay(20);
        var secondUpload = await client.PostAsync("/api/imports/audio/upload", Multipart(wav, "audio/wav", new ImportRequest()));
        var secondJson = await client.PostAsJsonAsync("/api/imports/audio", new ImportRequest(PayloadBase64: Convert.ToBase64String(wav)), JsonOptions);
        var otherRoute = await client.PostAsJsonAsync("/api/imports/manual-text", new ImportRequest(Text: "hello there"), JsonOptions);
        release.Set();

        Assert.Multiple(() =>
        {
            Assert.That(secondUpload.StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
            Assert.That(secondJson.StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
            Assert.That(otherRoute.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        });
        Assert.That((await first).StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    private static async Task AssertRejectedWithoutForwarding(byte[] ogg, string email)
    {
        await using var whisper = new MockHttpServer(_ => new MockHttpResponse("application/json", "{}"));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = whisper.Url,
            ["Imports:MaxAudioSeconds"] = "600"
        });
        using var client = await ChunkedAudioImportTests.AuthenticatedClientAsync(factory, email);

        var response = await client.PostAsync("/api/imports/audio/upload", Multipart(ogg, "audio/ogg", new ImportRequest()));

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(await response.Content.ReadAsStringAsync(), Does.Contain("maximum").Or.Contain("Unsupported or damaged"));
        Assert.That(whisper.RequestCount, Is.EqualTo(0));
    }

    private static AudioChunkSource? Source(byte[] audio, int max = AudioChunking.DefaultMaxAudioSeconds, AudioMemoryBudget? budget = null, CancellationToken ct = default) =>
        AudioChunking.TryCreateSourceAsync(audio, new AudioLimits(max, budget ?? new AudioMemoryBudget(600)), ct).GetAwaiter().GetResult();

    private static byte[] VorbisBytes() =>
        Encoding.ASCII.GetBytes("OggS").Concat(new byte[23]).Concat(new byte[] { 1 }).Concat(Encoding.ASCII.GetBytes("\u0001vorbis")).Concat(new byte[4000]).ToArray();

    private static byte[] Decode(byte[] ogg) =>
        OggOpusDecoder.DecodeToPcm16(ogg, OpusStreamScanner.Scan(ogg), AudioChunking.DefaultMaxAudioSeconds, CancellationToken.None);

    private static (byte[] Body, string Boundary) MalformedBody(string kind)
    {
        const string part = "Content-Disposition: form-data; name=\"audio\"; filename=\"a\"\r\n\r\nDATA";
        return kind switch
        {
            "wrongBoundary" => (Encoding.ASCII.GetBytes($"--other\r\n{part}\r\n--other--\r\n"), "abc"),
            "truncated" => (Encoding.ASCII.GetBytes($"--abc\r\n{part}"), "abc"),
            "hugeHeader" => (Encoding.ASCII.GetBytes($"--abc\r\nX-Pad: {new string('a', 40_000)}\r\n\r\nDATA\r\n--abc--\r\n"), "abc"),
            _ => (Encoding.ASCII.GetBytes("--x\r\n"), new string('b', 5000))
        };
    }

    /// <summary>Announces a large Content-Length but sends only a few bytes, then pauses before ending the body.</summary>
    private sealed class AnnouncedLengthContent(long announced, int actual) : HttpContent
    {
        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
        {
            await stream.WriteAsync(Encoding.ASCII.GetBytes("--abc\r\nContent-Disposition: form-data; name=\"audio\"\r\n\r\n"));
            await stream.WriteAsync(new byte[actual]);
            await stream.FlushAsync();
            await Task.Delay(1000); // the server is now blocked reading the rest of the announced body
        }

        protected override bool TryComputeLength(out long length)
        {
            length = announced;
            return true;
        }
    }

    /// <summary>Content that cannot report its length, so the request goes out chunked.</summary>
    private sealed class UnknownLengthContent(byte[] bytes) : HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => stream.WriteAsync(bytes).AsTask();

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }
    }

    private static MultipartFormDataContent Multipart(byte[] audio, string contentType, ImportRequest metadata)
    {
        var form = new MultipartFormDataContent();
        form.Add(new StringContent(JsonSerializer.Serialize(metadata, JsonOptions), Encoding.UTF8, "application/json"), "metadata");
        var file = new ByteArrayContent(audio);
        file.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        form.Add(file, "audio", "recording");
        return form;
    }

    private static byte[] EncodeOpus(double seconds, Func<double, bool> isSpeech)
    {
        var encoder = OpusCodecFactory.CreateEncoder(SyntheticWav.Rate, 1, OpusApplication.OPUS_APPLICATION_VOIP);
        encoder.Bitrate = 32000;
        using var stream = new MemoryStream();
        var writer = new OpusOggWriteStream(encoder, stream, new OpusTags(), SyntheticWav.Rate);
        writer.WriteSamples(Samples(seconds, isSpeech), 0, (int)(seconds * SyntheticWav.Rate));
        writer.Finish();
        return stream.ToArray();
    }

    private static short[] Samples(double seconds, Func<double, bool> isSpeech)
    {
        var samples = new short[(int)(seconds * SyntheticWav.Rate)];
        for (var i = 0; i < samples.Length; i++)
        {
            var t = (double)i / SyntheticWav.Rate;
            samples[i] = isSpeech(t) ? (short)(8000 * Math.Sin(2 * Math.PI * (300 + 7 * Math.Floor(t / 5)) * t)) : (short)0;
        }
        return samples;
    }

    private static double FirstLoudSecond(byte[] pcm)
    {
        for (var i = 0; i + 1 < pcm.Length; i += 2)
        {
            if (Math.Abs(BinaryPrimitives.ReadInt16LittleEndian(pcm.AsSpan(i))) > 2000) return i / 2.0 / OggOpusDecoder.SampleRate;
        }
        return -1;
    }
}
