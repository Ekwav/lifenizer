using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Lifenizer.Api.Services.Parsers;
using Lifenizer.Core;

namespace Lifenizer.Tests;

public sealed class PhotoAndWatchHistoryTests
{
    private static byte[] Fixture(string name) => File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "MockData", "documents", name));

    // ---- helpers: hand-built EXIF APP1 segment injected after the JPEG SOI marker ----
    private static byte[] JpegWithExif(byte[] jpeg, string dateTimeOriginal, bool gps)
    {
        var ms = new MemoryStream();
        var w = new BinaryWriter(ms);
        void Ifd(params (ushort Tag, ushort Type, uint Count, uint Value)[] entries)
        {
            w.Write((ushort)entries.Length);
            foreach (var e in entries) { w.Write(e.Tag); w.Write(e.Type); w.Write(e.Count); w.Write(e.Value); }
            w.Write(0u);
        }
        w.Write("II"u8); w.Write((ushort)42); w.Write(8u);
        var entryCount = gps ? 4 : 3;
        var ifd0End = 8u + 2 + (uint)entryCount * 12 + 4;
        var make = Encoding.ASCII.GetBytes("Acme\0");
        var model = Encoding.ASCII.GetBytes("Cam 1\0");
        var makeOff = ifd0End; var modelOff = makeOff + 5;
        var exifOff = (modelOff + 6 + 1) & ~1u;
        var dateOff = exifOff + 2 + 12 + 4;
        var gpsOff = dateOff + 20;
        var latOff = gpsOff + 2 + 4 * 12 + 4; var lonOff = latOff + 24;
        var ifd0 = new List<(ushort, ushort, uint, uint)> { (0x010F, 2, 5, makeOff), (0x0110, 2, 6, modelOff), (0x8769, 4, 1, exifOff) };
        if (gps) ifd0.Add((0x8825, 4, 1, gpsOff));
        Ifd(ifd0.ToArray());
        w.Write(make); w.Write(model);
        while (ms.Position < exifOff) w.Write((byte)0);
        Ifd((0x9003, 2, 20, dateOff));
        w.Write(Encoding.ASCII.GetBytes(dateTimeOriginal + "\0"));
        if (gps)
        {
            Ifd((1, 2, 2, (uint)'N'), (2, 5, 3, latOff), (3, 2, 2, (uint)'E'), (4, 5, 3, lonOff));
            foreach (var (n, d) in new[] { (52u, 1u), (30u, 1u), (0u, 1u), (13u, 1u), (24u, 1u), (0u, 1u) }) { w.Write(n); w.Write(d); }
        }
        var tiff = ms.ToArray();
        var app1 = new MemoryStream();
        app1.Write([0xff, 0xe1]);
        var length = 2 + 6 + tiff.Length;
        app1.WriteByte((byte)(length >> 8)); app1.WriteByte((byte)length);
        app1.Write("Exif\0\0"u8); app1.Write(tiff);
        return [.. jpeg[..2], .. app1.ToArray(), .. jpeg[2..]];
    }

    private static ImportRequest PhotoRequest(byte[] bytes, Dictionary<string, string>? metadata = null, string mime = "image/jpeg") =>
        new(OriginalFileName: "IMG_0001.jpg", MimeType: mime, PayloadBase64: Convert.ToBase64String(bytes), Metadata: metadata);

    private static bool TesseractAvailable() => ToolOnPath("tesseract");
    private static bool ToolOnPath(string name) => (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator).Any(dir => File.Exists(Path.Combine(dir, name)));

    [Test]
    public void PhotoReadsExifDateCameraAndGpsFlagWithoutStoringCoordinates()
    {
        if (!TesseractAvailable()) Assert.Ignore("tesseract is not installed; OCR-dependent photo test skipped.");
        var jpeg = JpegWithExif(Fixture("scan.jpg"), "2023:07:04 12:30:15", gps: true);
        var result = new PhotoParser().Parse(PhotoRequest(jpeg, new() { ["capturedAt"] = "2020-01-01T00:00:00Z" }));
        var conversation = result.Conversations.Single();
        var meta = conversation.Metadata!;
        Assert.Multiple(() =>
        {
            Assert.That(conversation.Source, Is.EqualTo("photo"));
            Assert.That(meta["capturedAt"], Does.StartWith("2023-07-04T12:30:15"));
            Assert.That(meta["capturedAtSource"], Is.EqualTo("exif"));
            Assert.That(meta["cameraMake"], Is.EqualTo("Acme"));
            Assert.That(meta["cameraModel"], Is.EqualTo("Cam 1"));
            Assert.That(meta["hasGps"], Is.EqualTo("true"));
            Assert.That(meta["ocr"], Is.EqualTo("tesseract"));
            Assert.That(meta["fileName"], Is.EqualTo("IMG_0001.jpg"));
            Assert.That(meta["mimeType"], Is.EqualTo("image/jpeg"));
            Assert.That(int.Parse(meta["width"]), Is.GreaterThan(0));
            Assert.That(meta.Values.Concat(conversation.Segments.Select(s => s.Text)), Has.None.Contain("52.5").And.None.Contain("13.4"));
            Assert.That(conversation.Title, Does.Contain("SCANNED RECHNUNG 7391").And.Length.LessThanOrEqualTo(80));
            Assert.That(conversation.Segments[0].Text, Does.Contain("7391"));
            Assert.That(conversation.Segments[0].CreatedAt!.Value.UtcDateTime, Is.EqualTo(new DateTime(2023, 7, 4, 12, 30, 15, DateTimeKind.Utc)));
        });
    }

    [Test]
    public void PhotoWithoutOcrFallsBackToClientCapturedAtAndFileNameSegment()
    {
        // HEIC has no OCR decoder: unreadable metadata + no OCR must still produce a findable photo.
        var heic = new byte[] { 0, 0, 0, 24, (byte)'f', (byte)'t', (byte)'y', (byte)'p', (byte)'h', (byte)'e', (byte)'i', (byte)'c', 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8 };
        var result = new PhotoParser().Parse(PhotoRequest(heic, new() { ["capturedAt"] = "2024-05-06T07:08:09Z" }, "image/heic"));
        var conversation = result.Conversations.Single();
        Assert.Multiple(() =>
        {
            Assert.That(conversation.Title, Is.EqualTo("Photo 2024-05-06 07:08"));
            Assert.That(conversation.Segments.Single().Text, Is.EqualTo("IMG_0001.jpg"));
            Assert.That(conversation.Metadata!["ocr"], Is.EqualTo("none"));
            Assert.That(conversation.Metadata["capturedAtSource"], Is.EqualTo("client"));
            Assert.That(conversation.Metadata["hasGps"], Is.EqualTo("false"));
        });
    }

    [Test]
    public void PhotoThreadIdIsContentHashSoReimportIsIdempotent()
    {
        var heic = new byte[] { 0, 0, 0, 24, (byte)'f', (byte)'t', (byte)'y', (byte)'p', (byte)'m', (byte)'i', (byte)'f', (byte)'1', 9, 9, 9, 9 };
        var other = (byte[])heic.Clone(); other[^1] = 7;
        var a = new PhotoParser().Parse(PhotoRequest(heic)).Conversations.Single();
        var b = new PhotoParser().Parse(PhotoRequest(heic, new() { ["capturedAt"] = "2024-01-01T00:00:00Z" })).Conversations.Single();
        var c = new PhotoParser().Parse(PhotoRequest(other)).Conversations.Single();
        Assert.Multiple(() =>
        {
            Assert.That(a.SourceThreadId, Is.EqualTo(b.SourceThreadId).And.StartWith("photo:"));
            Assert.That(a.SourceThreadId, Is.Not.EqualTo(c.SourceThreadId));
            Assert.That(a.Segments[0].SourceMessageId, Is.EqualTo(b.Segments[0].SourceMessageId));
        });
    }

    [Test]
    public void PhotoRejectsNonImagesMissingPayloadsAndOversizedBodies()
    {
        Assert.Throws<InvalidOperationException>(() => new PhotoParser().Parse(new ImportRequest()));
        Assert.Throws<InvalidOperationException>(() => new PhotoParser().Parse(PhotoRequest(Encoding.UTF8.GetBytes("not an image"))));
        Assert.Throws<InvalidOperationException>(() => new PhotoParser().Parse(new ImportRequest(PayloadBase64: new string('A', 40_000_000))));
    }

    // ---- YouTube ----
    private const string YouTubeJson = """
    [
      {"header":"YouTube","title":"Watched Cool Video","titleUrl":"https://www.youtube.com/watch?v=abc123DEF45","subtitles":[{"name":"Chan One","url":"https://www.youtube.com/channel/UC111"}],"time":"2024-01-02T15:04:05.123Z","products":["YouTube"],"activityControls":["YouTube watch history"]},
      {"header":"YouTube","title":"Watched https://www.youtube.com/watch?v=gone1234567","titleUrl":"https://www.youtube.com/watch?v=gone1234567","time":"2024-01-03T10:00:00+02:00"},
      {"header":"YouTube","title":"Watched a post that was removed","time":"2024-01-04T10:00:00Z"},
      {"header":"YouTube","title":"Angesehen: Cool Video","titleUrl":"https://www.youtube.com/watch?v=abc123DEF45","subtitles":[{"name":"Chan One","url":"https://www.youtube.com/channel/UC111"}],"time":"2024-02-01T08:00:00Z"}
    ]
    """;

    [Test]
    public void YouTubeJsonGroupsRepeatedWatchesSkipsEntriesWithoutUrlAndKeepsRemovedVideos()
    {
        var result = new YouTubeWatchHistoryParser().Parse(new ImportRequest(Text: YouTubeJson));
        var cool = result.Conversations.Single(c => c.SourceThreadId == "youtube:abc123DEF45");
        var gone = result.Conversations.Single(c => c.SourceThreadId == "youtube:gone1234567");
        Assert.Multiple(() =>
        {
            Assert.That(result.Conversations, Has.Count.EqualTo(2));
            Assert.That(result.Diagnostics!["skippedWithoutVideoUrl"], Is.EqualTo("1"));
            Assert.That(cool.Source, Is.EqualTo("youtube-watch-history"));
            Assert.That(cool.Title, Is.EqualTo("Cool Video"));
            Assert.That(cool.SourceUrl, Is.EqualTo("https://www.youtube.com/watch?v=abc123DEF45"));
            Assert.That(cool.Segments, Has.Count.EqualTo(2));
            Assert.That(cool.Segments[0].Text, Does.Contain("Cool Video").And.Contain("Chan One"));
            Assert.That(cool.Segments[0].CreatedAt, Is.EqualTo(new DateTimeOffset(2024, 1, 2, 15, 4, 5, 123, TimeSpan.Zero)));
            Assert.That(cool.Segments[0].SourceMessageId, Is.Not.EqualTo(cool.Segments[1].SourceMessageId));
            Assert.That(cool.ParticipantIdentifiers, Is.EqualTo(new[] { "youtube:https://www.youtube.com/channel/UC111" }));
            Assert.That(cool.Metadata!["watchCount"], Is.EqualTo("2"));
            Assert.That(cool.Metadata["platform"], Is.EqualTo("youtube"));
            Assert.That(cool.Metadata["channel"], Is.EqualTo("Chan One"));
            Assert.That(cool.Metadata["transcript"], Is.EqualTo("none"));
            Assert.That(cool.Metadata["lastWatchedAt"], Does.StartWith("2024-02-01T08:00:00"));
            Assert.That(gone.Title, Is.EqualTo("YouTube video gone1234567"));
            Assert.That(gone.Segments.Single().CreatedAt!.Value.UtcDateTime, Is.EqualTo(new DateTime(2024, 1, 3, 8, 0, 0, DateTimeKind.Utc)));
            Assert.That(result.Participants.Single().DisplayName, Is.EqualTo("Chan One"));
        });
    }

    [Test]
    public void YouTubeReimportProducesIdenticalThreadAndMessageIds()
    {
        var a = new YouTubeWatchHistoryParser().Parse(new ImportRequest(Text: YouTubeJson));
        var b = new YouTubeWatchHistoryParser().Parse(new ImportRequest(PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes(YouTubeJson))));
        Assert.That(b.Conversations.SelectMany(c => c.Segments).Select(s => s.SourceMessageId),
            Is.EquivalentTo(a.Conversations.SelectMany(c => c.Segments).Select(s => s.SourceMessageId)));
    }

    [Test]
    public void YouTubeHtmlParsesCellsWithTimeZones()
    {
        const string html = """
        <html><body><div class="mdl-grid">
        <div class="outer-cell mdl-cell"><div class="mdl-grid">
        <div class="header-cell mdl-cell"><p class="mdl-typography--title">YouTube<br></p></div>
        <div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1">Watched&nbsp;<a href="https://www.youtube.com/watch?v=abc123DEF45">Cool &amp; Video</a><br><a href="https://www.youtube.com/channel/UC111">Chan One</a><br>Jan 2, 2024, 3:04:05&#8239;PM CET</div>
        <div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1 mdl-typography--text-right"></div>
        </div></div>
        <div class="outer-cell mdl-cell"><div class="mdl-grid">
        <div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1">Watched&nbsp;<a href="https://www.youtube.com/watch?v=gone1234567">https://www.youtube.com/watch?v=gone1234567</a><br>Mar 5, 2024, 11:00:00 PM UTC</div>
        </div></div></div></body></html>
        """;
        var result = new YouTubeWatchHistoryParser().Parse(new ImportRequest(Text: html));
        var cool = result.Conversations.Single(c => c.SourceThreadId == "youtube:abc123DEF45");
        var gone = result.Conversations.Single(c => c.SourceThreadId == "youtube:gone1234567");
        Assert.Multiple(() =>
        {
            Assert.That(cool.Title, Is.EqualTo("Cool & Video"));
            Assert.That(cool.Metadata!["channel"], Is.EqualTo("Chan One"));
            Assert.That(cool.Segments.Single().CreatedAt!.Value.UtcDateTime, Is.EqualTo(new DateTime(2024, 1, 2, 14, 4, 5, DateTimeKind.Utc)));
            Assert.That(gone.Title, Is.EqualTo("YouTube video gone1234567"));
            Assert.That(gone.Segments.Single().CreatedAt!.Value.UtcDateTime, Is.EqualTo(new DateTime(2024, 3, 5, 23, 0, 0, DateTimeKind.Utc)));
        });
    }

    [TestCase("Jan 2, 2024, 3:04:05 PM CEST", "2024-01-02T13:04:05")]
    [TestCase("Jan 2, 2024, 3:04:05 AM PST", "2024-01-02T11:04:05")]
    [TestCase("2 Jan 2024, 15:04:05 GMT+01:00", "2024-01-02T14:04:05")]
    [TestCase("02.01.2024, 15:04:05 MEZ", "2024-01-02T14:04:05")]
    public void TakeoutDatesAreConvertedToUtc(string input, string expectedUtc)
    {
        var parsed = YouTubeWatchHistoryParser.ParseTakeoutDate(input, out var known);
        Assert.Multiple(() =>
        {
            Assert.That(known, Is.True);
            Assert.That(parsed!.Value.UtcDateTime, Is.EqualTo(DateTime.Parse(expectedUtc, null, System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal)));
        });
    }

    // ---- TikTok ----
    [Test]
    public void TikTokJsonExportParsesVideoBrowsingHistory()
    {
        const string json = """
        {"Activity":{"Video Browsing History":{"VideoList":[
          {"Date":"2024-03-01 10:00:00","Link":"https://www.tiktokv.com/share/video/7300000000000000001/"},
          {"Date":"2024-03-02 11:30:00","Link":"https://www.tiktokv.com/share/video/7300000000000000002/"},
          {"Date":"2024-03-03 12:00:00","Link":"https://www.tiktokv.com/share/video/7300000000000000001/"},
          {"Date":"2024-03-04 12:00:00","Link":""}
        ]},"Like List":{"ItemFavoriteList":[{"Date":"2024-01-01 00:00:00","Link":"https://www.tiktokv.com/share/video/7399999999999999999/"}]}}}
        """;
        var result = new TikTokWatchHistoryParser().Parse(new ImportRequest(Text: json));
        AssertTikTok(result);
    }

    [Test]
    public void TikTokTxtExportParsesDateLinkBlocksAndMatchesJson()
    {
        const string txt = "Date: 2024-03-01 10:00:00\nLink: https://www.tiktokv.com/share/video/7300000000000000001/\n\nDate: 2024-03-02 11:30:00\r\nLink: https://www.tiktokv.com/share/video/7300000000000000002/\r\n\r\nDate: 2024-03-03 12:00:00\nLink: https://www.tiktokv.com/share/video/7300000000000000001/\n";
        AssertTikTok(new TikTokWatchHistoryParser().Parse(new ImportRequest(Text: txt)));
    }

    private static void AssertTikTok(NormalizedImportResponse result)
    {
        var one = result.Conversations.Single(c => c.SourceThreadId == "tiktok:7300000000000000001");
        Assert.Multiple(() =>
        {
            Assert.That(result.Conversations, Has.Count.EqualTo(2));
            Assert.That(one.Source, Is.EqualTo("tiktok-watch-history"));
            Assert.That(one.Title, Is.EqualTo("TikTok video 7300000000000000001"));
            Assert.That(one.Segments, Has.Count.EqualTo(2));
            Assert.That(one.Metadata!["videoId"], Is.EqualTo("7300000000000000001"));
            Assert.That(one.Metadata["videoUrl"], Does.Contain("7300000000000000001"));
            Assert.That(one.Metadata["watchCount"], Is.EqualTo("2"));
            Assert.That(one.Metadata["lastWatchedAt"], Does.StartWith("2024-03-03T12:00:00"));
            Assert.That(one.Segments[0].CreatedAt!.Value.UtcDateTime, Is.EqualTo(new DateTime(2024, 3, 1, 10, 0, 0, DateTimeKind.Utc)));
            Assert.That(one.Segments[0].Text, Does.Contain("7300000000000000001"));
        });
    }

    // ---- capabilities ----
    [Test]
    public async Task CapabilitiesAdvertiseNewSourcesAndEndpointAcceptsThem()
    {
        await using var factory = new LifenizerApiFactory();
        using var anonymous = factory.CreateClient();
        var capabilities = await anonymous.GetFromJsonAsync<JsonElement>("/api/imports/capabilities");
        var sources = capabilities.EnumerateArray().ToDictionary(c => c.GetProperty("source").GetString()!);
        Assert.Multiple(() =>
        {
            Assert.That(sources.Keys, Is.SupersetOf(new[] { "photo", "youtube-watch-history", "tiktok-watch-history" }));
            Assert.That(sources["photo"].GetProperty("availableNow").GetBoolean(), Is.True);
            Assert.That(sources["youtube-watch-history"].GetProperty("fileNameHints").EnumerateArray().Select(e => e.GetString()), Does.Contain("watch-history.json"));
        });
    }
}
