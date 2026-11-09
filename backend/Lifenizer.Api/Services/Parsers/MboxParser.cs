using System.Text;
using Lifenizer.Core;
using MimeKit;

namespace Lifenizer.Api.Services.Parsers;

public sealed class MboxParser : IImportParser
{
    public string Source => "mbox";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        // Preserve original bytes so MIME charset decoding also works for unencoded legacy mail.
        var bytes = request.Text is null && request.PayloadBase64 is not null && !string.Equals(request.MimeType, "application/zip", StringComparison.OrdinalIgnoreCase)
            ? Convert.FromBase64String(request.PayloadBase64) : Encoding.UTF8.GetBytes(text);
        using var stream = new MemoryStream(bytes);
        var parser = new MimeParser(stream, text.StartsWith("From ", StringComparison.Ordinal) ? MimeFormat.Mbox : MimeFormat.Entity);
        var messages = new List<(MimeMessage Message, Dictionary<string, string>? Metadata)>();
        try
        {
            while (!parser.IsEndOfStream) messages.Add((parser.ParseMessage(), null));
            return EmailNormalization.Response(Source, request, messages);
        }
        finally { foreach (var (message, _) in messages) message.Dispose(); }
    }
}
