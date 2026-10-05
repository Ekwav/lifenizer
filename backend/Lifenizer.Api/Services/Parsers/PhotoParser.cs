using System.Globalization;
using System.Security.Cryptography;
using MetadataExtractor;
using MetadataExtractor.Formats.Exif;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Imports one camera image: EXIF capture date, camera make/model, a GPS-present flag (never coordinates),
/// image size and Tesseract OCR text. The thread id is derived from the SHA-256 of the bytes so the client
/// updates the same conversation when the same image is imported again.
/// </summary>
public sealed class PhotoParser : IImportParser
{
    public string Source => "photo";
    private const int MaxSegments = 200;
    private const int MaxTitleLength = 80;

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.PayloadBase64)) throw new InvalidOperationException("Photo import requires an image in payloadBase64.");
        if (request.PayloadBase64.Length > (PdfTextExtractor.MaxBytes + 2L) / 3 * 4) throw new InvalidOperationException("Photo exceeds 25 MiB.");
        byte[] bytes;
        try { bytes = Convert.FromBase64String(request.PayloadBase64); }
        catch (FormatException) { throw new InvalidOperationException("Photo payloadBase64 is invalid."); }
        if (bytes.Length is 0 or > PdfTextExtractor.MaxBytes) throw new InvalidOperationException("Photo must be between 1 byte and 25 MiB.");
        var kind = DetectKind(bytes) ?? throw new InvalidOperationException("Photo must be a JPEG, PNG, WebP or HEIC image.");

        var info = ReadMetadata(bytes);
        if (info.Width is { } w && info.Height is { } h && (w > 10000 || h > 10000 || (long)w * h > 25_000_000))
            throw new InvalidOperationException("Photo must be at most 25 megapixels and 10,000 pixels per side. Resize it and retry.");

        var utcOffset = TimeSpan.Zero;
        if (int.TryParse(CommonParsing.Metadata(request, "utcOffsetMinutes"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var offsetMinutes) && Math.Abs(offsetMinutes) <= 14 * 60)
            utcOffset = TimeSpan.FromMinutes(offsetMinutes);

        DateTimeOffset capturedAt;
        string capturedSource;
        if (info.Taken is { } taken)
        {
            capturedAt = new DateTimeOffset(DateTime.SpecifyKind(taken, DateTimeKind.Unspecified), info.TakenOffset ?? utcOffset);
            capturedSource = "exif";
        }
        else if (CommonParsing.TryParseDate(CommonParsing.Metadata(request, "capturedAt")) is { } client)
        {
            capturedAt = client;
            capturedSource = "client";
        }
        else
        {
            capturedAt = DateTimeOffset.UtcNow;
            capturedSource = "import";
        }

        var fileName = CommonParsing.Clean(request.OriginalFileName) ?? CommonParsing.Metadata(request, "fileName") ?? "photo";
        var mimeType = CommonParsing.Clean(request.MimeType) ?? kind.Mime;
        var sha = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

        var ocrText = "";
        if (kind.Ocr)
        {
            try { ocrText = PdfTextExtractor.Extract(bytes, image: true, allowEmpty: true, validateSize: kind.Name is "jpeg" or "png"); }
            catch (InvalidOperationException) { ocrText = ""; }
        }

        var paragraphs = SplitParagraphs(ocrText);
        var ocrUsed = paragraphs.Count > 0;
        var fallbackTitle = $"Photo {capturedAt:yyyy-MM-dd HH:mm}";
        var title = CommonParsing.Clean(request.Title) ?? FirstMeaningfulLine(ocrText) ?? fallbackTitle;

        var segments = (ocrUsed ? paragraphs : [fileName])
            .Select((text, index) => new NormalizedSegment(text, null, 0, capturedAt, null, $"{sha}:{index}"))
            .ToArray();

        var metadata = new Dictionary<string, string>
        {
            ["capturedAt"] = capturedAt.ToString("o", CultureInfo.InvariantCulture),
            ["capturedAtSource"] = capturedSource,
            ["fileName"] = fileName,
            ["mimeType"] = mimeType,
            ["ocr"] = ocrUsed ? "tesseract" : "none",
            ["hasGps"] = info.HasGps ? "true" : "false",
            ["contentSha256"] = sha,
        };
        if (info.Make is not null) metadata["cameraMake"] = info.Make;
        if (info.Model is not null) metadata["cameraModel"] = info.Model;
        if (info.Width is { } width) metadata["width"] = width.ToString(CultureInfo.InvariantCulture);
        if (info.Height is { } height) metadata["height"] = height.ToString(CultureInfo.InvariantCulture);

        var conversation = new NormalizedConversation(title, Source, [], segments, [fileName], metadata, null, $"photo:{sha}");
        return CommonParsing.Response(Source, "Normalized 1 photo.", [conversation]);
    }

    private sealed record ImageKind(string Name, string Mime, bool Ocr);

    private static ImageKind? DetectKind(byte[] b)
    {
        if (b.Length >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) return new("jpeg", "image/jpeg", true);
        if (b.Length >= 8 && b.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) return new("png", "image/png", true);
        if (b.Length >= 12 && b.AsSpan(0, 4).SequenceEqual("RIFF"u8) && b.AsSpan(8, 4).SequenceEqual("WEBP"u8)) return new("webp", "image/webp", true);
        if (b.Length >= 12 && b.AsSpan(4, 4).SequenceEqual("ftyp"u8))
        {
            var brand = System.Text.Encoding.ASCII.GetString(b, 8, 4);
            if (brand is "heic" or "heix" or "hevc" or "hevx" or "heim" or "heis" or "mif1" or "msf1" or "heif")
                return new("heic", "image/heic", false); // no decoder available for OCR
        }
        return null;
    }

    private sealed record PhotoInfo(DateTime? Taken, TimeSpan? TakenOffset, string? Make, string? Model, bool HasGps, int? Width, int? Height);

    private static PhotoInfo ReadMetadata(byte[] bytes)
    {
        IReadOnlyList<MetadataExtractor.Directory> directories;
        try
        {
            using var stream = new MemoryStream(bytes, writable: false);
            directories = ImageMetadataReader.ReadMetadata(stream);
        }
        catch (Exception exception) when (exception is ImageProcessingException or IOException or MetadataException)
        {
            return new PhotoInfo(null, null, null, null, false, null, null);
        }

        DateTime? taken = null;
        TimeSpan? offset = null;
        var sub = directories.OfType<ExifSubIfdDirectory>().FirstOrDefault();
        if (sub is not null)
        {
            if (sub.TryGetDateTime(ExifDirectoryBase.TagDateTimeOriginal, out var original)) taken = original;
            else if (sub.TryGetDateTime(ExifDirectoryBase.TagDateTimeDigitized, out var digitized)) taken = digitized;
            if (sub.GetString(0x9011) is { } offsetText && TimeSpan.TryParse(offsetText.Trim().TrimStart('+'), CultureInfo.InvariantCulture, out var parsed) && offsetText.Trim().Length >= 5)
                offset = offsetText.Trim().StartsWith('-') ? -parsed.Duration() : parsed;
        }
        taken ??= directories.OfType<ExifIfd0Directory>().FirstOrDefault() is { } ifd0 && ifd0.TryGetDateTime(ExifDirectoryBase.TagDateTime, out var modified) ? modified : null;
        if (taken is { Year: < 1990 }) taken = null;

        var ifd = directories.OfType<ExifIfd0Directory>().FirstOrDefault();
        var make = Clean(ifd?.GetString(ExifDirectoryBase.TagMake));
        var model = Clean(ifd?.GetString(ExifDirectoryBase.TagModel));
        var hasGps = directories.OfType<GpsDirectory>().Any(gps => gps.GetGeoLocation() is not null);

        int? width = null, height = null;
        foreach (var directory in directories)
        {
            var wTag = directory.Tags.FirstOrDefault(tag => tag.Name is "Image Width");
            var hTag = directory.Tags.FirstOrDefault(tag => tag.Name is "Image Height");
            if (wTag is not null && hTag is not null && directory.TryGetInt32(wTag.Type, out var iw) && directory.TryGetInt32(hTag.Type, out var ih) && iw > 0 && ih > 0)
            {
                width = iw; height = ih; break;
            }
        }
        if (width is null && sub is not null && sub.TryGetInt32(ExifDirectoryBase.TagExifImageWidth, out var ew) && sub.TryGetInt32(ExifDirectoryBase.TagExifImageHeight, out var eh))
        {
            width = ew; height = eh;
        }
        return new PhotoInfo(taken, offset, make, model, hasGps, width, height);
    }

    private static string? Clean(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim('\0', ' ');

    private static List<string> SplitParagraphs(string text)
    {
        var result = new List<string>();
        foreach (var block in System.Text.RegularExpressions.Regex.Split(text.Replace("\r", ""), @"\n\s*\n"))
        {
            var cleaned = block.Trim();
            if (cleaned.Length == 0 || !cleaned.Any(char.IsLetterOrDigit)) continue;
            result.Add(cleaned);
            if (result.Count >= MaxSegments) break;
        }
        return result;
    }

    private static string? FirstMeaningfulLine(string text)
    {
        foreach (var raw in text.Replace("\r", "").Split('\n'))
        {
            var line = System.Text.RegularExpressions.Regex.Replace(raw, @"\s+", " ").Trim();
            if (line.Count(char.IsLetterOrDigit) < 3) continue;
            return line.Length <= MaxTitleLength ? line : line[..(MaxTitleLength - 1)].TrimEnd() + "…";
        }
        return null;
    }
}
