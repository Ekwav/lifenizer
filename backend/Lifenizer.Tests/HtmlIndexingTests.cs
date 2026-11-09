using System.Diagnostics;
using Lifenizer.Api.Services.Parsers;
using Lifenizer.Core;

namespace Lifenizer.Tests;

public sealed class HtmlIndexingTests
{
    [Test]
    public void HtmlEmailIndexesVisibleTextWithoutScriptsOrStyles()
    {
        var result = new MboxParser().Parse(new ImportRequest(Text: "Content-Type: text/html; charset=utf-8\r\n\r\n" +
            "<style>body { color:red }</style><p>Invoice &amp; receipt</p><script>privateScriptToken()</script>"));
        Assert.That(result.Conversations.Single().Segments.Single().Text, Is.EqualTo("Invoice & receipt"));
    }

    [Test]
    public void MalformedHtmlCannotCauseQuadraticTagMatching()
    {
        var malformed = ">" + new string('<', 1024 * 1024);
        var clock = Stopwatch.StartNew();
        var text = CommonParsing.StripHtml(malformed);
        Assert.Multiple(() =>
        {
            Assert.That(text, Is.EqualTo(malformed));
            Assert.That(clock.Elapsed, Is.LessThan(TimeSpan.FromSeconds(5)));
        });
    }
}
