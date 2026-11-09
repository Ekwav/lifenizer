using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Api.Services.Utilities;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Parser for git commit history exports (JSON or text format).
/// </summary>
public sealed partial class GitParser : IImportParser
{
    public string Source => "git";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        var participants = ParticipantRegistry.FromRequest(request);
        var segments = new List<NormalizedSegment>();

        if (FormatDetector.IsJson(text))
        {
            ParseJson(text, participants, segments);
        }
        else
        {
            ParseText(text, participants, segments);
        }

        if (segments.Count == 0)
        {
            return CommonParsing.SingleConversation(Source, request, text, "Git import");
        }

        var title = CommonParsing.Clean(request.Title)
            ?? CommonParsing.Metadata(request, "repository")
            ?? CommonParsing.Metadata(request, "repoUrl")
            ?? CommonParsing.Clean(request.OriginalFileName)
            ?? "Git history";
        var metadata = new Dictionary<string, string>();
        if (CommonParsing.Metadata(request, "repoUrl") is { } repoUrl) metadata["repoUrl"] = repoUrl;
        return CommonParsing.Response(Source, $"Normalized {segments.Count} git commit(s).", [new NormalizedConversation(title, Source, participants.ToList(), segments, null, metadata.Count > 0 ? metadata : null)]);
    }

    private static void ParseJson(string json, ParticipantRegistry participants, List<NormalizedSegment> segments)
    {
        using var doc = JsonDocument.Parse(json);
        var commits = CommonParsing.EnumerateArray(doc.RootElement, "commits", "items", "history");
        foreach (var commit in commits)
        {
            var message = JsonFieldExtractor.GetString(commit, "message", "subject") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(message)) continue;
            var hash = JsonFieldExtractor.GetString(commit, "hash", "sha", "id") ?? string.Empty;
            var shortHash = hash.Length > 7 ? hash[..7] : hash;
            var author = JsonFieldExtractor.GetString(commit, "author")
                ?? JsonFieldExtractor.GetNestedString(commit, "author", "name", "email")
                ?? "Unknown";
            participants.TryAdd(author);
            var files = commit.TryGetProperty("files", out var filesArray) && filesArray.ValueKind == JsonValueKind.Array
                ? string.Join(", ", filesArray.EnumerateArray().Select(file => file.ValueKind == JsonValueKind.String ? file.GetString() : JsonFieldExtractor.GetString(file, "path")).Where(path => !string.IsNullOrWhiteSpace(path)))
                : string.Empty;
            var body = shortHash.Length > 0 ? $"{shortHash} {message}" : message;
            if (files.Length > 0) body += $"\nFiles: {files}";
            segments.Add(new SegmentBuilder()
                .WithText(body)
                .WithSpeaker(author)
                .WithAutoOffset(segments.Count)
                .WithTimestamp(CommonParsing.TryParseDate(JsonFieldExtractor.GetString(commit, "date", "authoredDate")))
                .Build());
        }
    }

    private static void ParseText(string text, ParticipantRegistry participants, List<NormalizedSegment> segments)
    {
        foreach (var block in GitCommitRegex().Split(text).Where(item => item.Trim().Length > 0))
        {
            var trimmed = block.Trim();
            var lines = trimmed.Split('\n').Select(line => line.TrimEnd('\r')).ToArray();
            if (lines.Length == 0) continue;
            var hash = lines[0].Trim();
            var shortHash = hash.Length > 7 ? hash[..7] : hash;
            var author = lines.FirstOrDefault(line => line.StartsWith("Author:", StringComparison.OrdinalIgnoreCase))?.Split(':', 2).ElementAtOrDefault(1)?.Trim() ?? "Unknown";
            participants.TryAdd(author);
            var date = lines.FirstOrDefault(line => line.StartsWith("Date:", StringComparison.OrdinalIgnoreCase))?.Split(':', 2).ElementAtOrDefault(1)?.Trim();
            var bodyLines = lines.SkipWhile(line => !string.IsNullOrWhiteSpace(line)).Skip(1).Where(line => line.Length > 0).ToArray();
            var message = bodyLines.Length > 0 ? string.Join("\n", bodyLines) : trimmed;
            segments.Add(new SegmentBuilder()
                .WithText($"{shortHash} {message}".Trim())
                .WithSpeaker(author)
                .WithAutoOffset(segments.Count)
                .WithTimestamp(CommonParsing.TryParseDate(date))
                .Build());
        }
    }

    [GeneratedRegex(@"(?:^|\n)commit\s+", RegexOptions.Multiline)]
    private static partial Regex GitCommitRegex();
}
