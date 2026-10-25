using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>Reads Paperless exporter manifests or bulk document ZIPs without extracting paths to disk.</summary>
public sealed class PaperlessExportParser : IImportParser
{
    public string Source => "paperless-export";
    private const int MaxTextChars = 8 * 1024 * 1024;

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.PayloadBase64)) throw new InvalidOperationException("Choose a Paperless ZIP export.");
        if (request.PayloadBase64.Length > (BoundedImportArchive.MaxBytes + 2L) / 3 * 4)
            throw new InvalidOperationException("Paperless ZIP exceeds 25 MiB. Export a smaller selection and retry.");
        try
        {
            using var archive = BoundedImportArchive.Open(Convert.FromBase64String(request.PayloadBase64));
            var clock = Stopwatch.StartNew();
            var conversations = new List<NormalizedConversation>();
            var textChars = 0;
            var manifests = archive.Entries.Where(entry => Path.GetFileName(entry.FullName) == "manifest.json" ||
                entry.FullName.EndsWith("-manifest.json", StringComparison.OrdinalIgnoreCase)).ToArray();
            if (manifests.Length > 0)
            {
                // Only document metadata is retained; exported accounts, passwords and settings are ignored.
                var records = new List<JsonElement>();
                foreach (var manifest in manifests)
                {
                    using var json = JsonDocument.Parse(BoundedImportArchive.Read(manifest));
                    if (json.RootElement.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Invalid Paperless manifest.");
                    foreach (var record in json.RootElement.EnumerateArray())
                    {
                        if (String(record, "model") is not ("documents.document" or "documents.correspondent" or "documents.tag")) continue;
                        if (records.Count >= 10000) throw new InvalidDataException("Paperless manifest contains too many records.");
                        records.Add(record.Clone());
                    }
                }
                var correspondents = Names(records, "documents.correspondent");
                var tags = Names(records, "documents.tag");
                var ids = new HashSet<string>(StringComparer.Ordinal);
                foreach (var record in records.Where(record => String(record, "model") == "documents.document"))
                {
                    CheckBudget();
                    var fields = record.GetProperty("fields");
                    var pk = record.GetProperty("pk").ToString();
                    if (!ids.Add(pk)) throw new InvalidDataException("Duplicate Paperless document.");
                    var fileName = String(record, "__exported_file_name__");
                    var title = String(fields, "title") ?? fileName ?? "Paperless document";
                    var content = String(fields, "content") ?? "";
                    // An export may contain encrypted account fields; document content itself is plaintext.
                    var correspondent = fields.TryGetProperty("correspondent", out var owner)
                        ? correspondents.GetValueOrDefault(owner.ToString()) : null;
                    var metadata = new Dictionary<string, string> { ["paperless-id"] = pk };
                    if (fields.TryGetProperty("tags", out var tagIds) && tagIds.ValueKind == JsonValueKind.Array)
                        metadata["paperless-tags"] = string.Join(", ", tagIds.EnumerateArray().Select(id => tags.GetValueOrDefault(id.ToString())).Where(name => name is not null));
                    var identity = "paperless-export:" + (String(fields, "checksum") ?? pk);
                    Add(title, content, identity, correspondent, fileName, metadata, CommonParsing.TryParseDate(String(fields, "created")));
                }
                if (conversations.Count == 0) throw new InvalidOperationException("No Paperless documents were found in the manifest. Export documents with their metadata and retry.");
            }
            else
            {
                foreach (var entry in archive.Entries.Where(entry => IsDocument(entry.FullName)))
                {
                    CheckBudget();
                    var bytes = BoundedImportArchive.Read(entry);
                    var text = PdfTextExtractor.Extract(bytes, image: !entry.FullName.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase),
                        allowEmpty: true, timeout: TimeSpan.FromMinutes(2) - clock.Elapsed);
                    Add(Path.GetFileNameWithoutExtension(entry.FullName), text, "paperless-export:" + Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
                        null, entry.FullName, new Dictionary<string, string>(), null);
                }
                if (conversations.Count == 0) throw new InvalidOperationException("No PDF, PNG or JPEG documents were found. Choose a Paperless export ZIP; nested archives are not opened.");
            }
            var withoutText = conversations.Count(conversation => conversation.Segments[0].Text.Length == 0);
            return CommonParsing.Response(Source, $"Imported {conversations.Count} Paperless document(s)." +
                (withoutText > 0 ? $" {withoutText} without extracted text; their titles are searchable." : ""), conversations,
                new Dictionary<string, string> { ["documentsWithoutText"] = withoutText.ToString() });

            void CheckBudget()
            {
                if (clock.Elapsed >= TimeSpan.FromMinutes(2) || conversations.Count >= 1000)
                    throw new InvalidOperationException("Paperless import exceeds its two-minute or 1000-document limit. Export a smaller selection and retry.");
            }

            void Add(string title, string content, string identity, string? correspondent, string? fileName, Dictionary<string, string> metadata, DateTimeOffset? created)
            {
                textChars += title.Length + content.Length + metadata.Values.Sum(value => value.Length);
                if (textChars > MaxTextChars) throw new InvalidOperationException("Paperless extracted text exceeds 8 MiB. Export a smaller selection and retry.");
                conversations.Add(new NormalizedConversation(title, "paperless", correspondent is null ? [] : [correspondent],
                    [new NormalizedSegment(content, correspondent, CreatedAt: created, SourceMessageId: identity)],
                    fileName is null ? [] : [fileName], metadata, SourceThreadId: identity));
            }
        }
        catch (Exception exception) when (exception is InvalidDataException or FormatException or NotSupportedException or KeyNotFoundException)
        {
            throw new InvalidOperationException("Paperless ZIP is invalid or exceeds safe extraction limits. Use an unencrypted ZIP with standard Deflate compression and a smaller document selection.");
        }
    }

    private static bool IsDocument(string name) => new[] { ".pdf", ".png", ".jpg", ".jpeg" }
        .Contains(Path.GetExtension(name).ToLowerInvariant()) && !name.Contains("thumbnail", StringComparison.OrdinalIgnoreCase);

    private static string? String(JsonElement value, string key) => value.TryGetProperty(key, out var field) && field.ValueKind == JsonValueKind.String ? field.GetString() : null;

    private static Dictionary<string, string> Names(IEnumerable<JsonElement> records, string model) => records
        .Where(record => String(record, "model") == model && record.TryGetProperty("fields", out _))
        .GroupBy(record => record.GetProperty("pk").ToString())
        .ToDictionary(group => group.Key, group => String(group.First().GetProperty("fields"), "name") ?? "");
}
