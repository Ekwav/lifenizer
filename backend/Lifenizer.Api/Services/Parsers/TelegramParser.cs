using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Api.Services.Utilities;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Parser for Telegram chat exports (JSON or text format).
/// </summary>
public sealed partial class TelegramParser : IImportParser
{
    public string Source => "telegram";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        if (!FormatDetector.IsJson(text))
        {
            return CommonParsing.ParseTextLines(Source, request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        var chats = root.ValueKind == JsonValueKind.Object &&
            root.TryGetProperty("chats", out var exportedChats) &&
            exportedChats.ValueKind == JsonValueKind.Object
            ? CommonParsing.EnumerateArray(exportedChats, "list")
            : [root];
        var conversations = new List<NormalizedConversation>();
        var explicitTitle = root.ValueKind == JsonValueKind.Object && root.TryGetProperty("chats", out _)
            ? null : CommonParsing.Clean(request.Title);
        foreach (var chat in chats)
        {
            var messages = chat.ValueKind == JsonValueKind.Array
                ? chat.EnumerateArray()
                : CommonParsing.EnumerateArray(chat, "messages");
            var participants = ParticipantRegistry.FromRequest(request);
            var segments = new List<NormalizedSegment>();
            foreach (var message in messages)
            {
                if (message.ValueKind != JsonValueKind.Object) continue;
                var content = TelegramText(message);
                if (string.IsNullOrWhiteSpace(content)) continue;
                var speaker = JsonFieldExtractor.GetString(message, "from", "actor") ?? "Unknown";
                participants.TryAdd(speaker);
                segments.Add(new SegmentBuilder()
                    .WithText(content.Trim())
                    .WithSpeaker(speaker)
                    .WithAutoOffset(segments.Count)
                    .WithTimestamp(CommonParsing.TryParseDate(JsonFieldExtractor.GetString(message, "date")))
                    .Build());
            }
            if (segments.Count == 0) continue;
            var title = explicitTitle ?? JsonFieldExtractor.GetString(chat, "name") ?? "Telegram export";
            conversations.Add(new NormalizedConversation(title, Source, participants.ToList(), segments));
        }
        return CommonParsing.Response(Source,
            $"Normalized {conversations.Count} Telegram chat(s), {conversations.Sum(c => c.Segments.Count)} message(s).", conversations);
    }

    private static string? TelegramText(JsonElement message)
    {
        if (!message.TryGetProperty("text", out var text)) return JsonFieldExtractor.GetString(message, "content");
        if (text.ValueKind == JsonValueKind.String) return text.GetString();
        if (text.ValueKind != JsonValueKind.Array) return null;

        var builder = new System.Text.StringBuilder();
        foreach (var item in text.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
            {
                builder.Append(item.GetString());
            }
            else if (item.ValueKind == JsonValueKind.Object && item.TryGetProperty("text", out var nested))
            {
                builder.Append(nested.GetString());
            }
        }
        return builder.ToString();
    }

    [GeneratedRegex(@"^(?<speaker>[^:]+):\s*(?<text>.*)$")]
    private static partial Regex SimpleSpeakerLineRegex();
}
