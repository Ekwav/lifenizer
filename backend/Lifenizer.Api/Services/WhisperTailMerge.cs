namespace Lifenizer.Api.Services;

/// <summary>
/// Appends the transcript of a re-sent chunk tail to the chunk's own transcript. The tail starts a little
/// before the chunk's last segment ends, so words whisper heard twice at the join are dropped once.
/// </summary>
public static class WhisperTailMerge
{
    /// <summary>The tail is compared with this many trailing words of what was kept so far (across segments).</summary>
    private const int HistoryWords = 8;

    /// <summary>
    /// The tail re-hears about 0.5 s before the head's last end, which holds at most this many words, so at most this many are stripped.
    /// Of the repeated prefixes the longest one that the kept text really ends with wins. That assumes the repeated words
    /// both fell inside the 0.5 s overlap; text-only matching cannot tell, which is why the strip is capped at this many
    /// words. A genuine stutter can therefore lose a word: "I said no no" + "no no no stop" may become "I said no no no stop".
    /// </summary>
    private const int MaxStrippedWords = 3;

    public sealed record Outcome(WhisperTranscriptionResult Result, int WordsAdded);

    /// <summary>
    /// Shifts the tail's segments by <paramref name="tailOffsetSeconds"/> (the tail start within the chunk) and
    /// appends them in order. A tail segment that starts before the last kept segment ends loses the (at most
    /// <see cref="MaxStrippedWords"/>) words that repeat the end of the kept text, even across segments; it is dropped when
    /// nothing else is left. Kept segments never start before the previous one ends, and Start never exceeds End.
    /// </summary>
    public static Outcome Append(WhisperTranscriptionResult head, WhisperTranscriptionResult tail, double tailOffsetSeconds)
    {
        var segments = head.Segments.ToList();
        var added = new List<WhisperSegment>();
        foreach (var segment in tail.Segments)
        {
            if (string.IsNullOrWhiteSpace(segment.Text)) continue;
            var shifted = new WhisperSegment(segment.Start + tailOffsetSeconds, segment.End + tailOffsetSeconds, segment.Text);
            if (WithoutRepeat(segments, shifted) is not { } kept) continue;
            segments.Add(kept);
            added.Add(kept);
        }

        if (added.Count == 0) return new Outcome(head, 0);
        var text = string.Join(" ", added.Select(s => s.Text.Trim()).Prepend(head.Text.Trim()).Where(t => t.Length > 0));
        return new Outcome(new WhisperTranscriptionResult(text, head.Language ?? tail.Language, segments), added.Sum(s => Words(s.Text).Count));
    }

    /// <summary>The segment without the words it repeats from the kept text; null when it only repeats them.</summary>
    private static WhisperSegment? WithoutRepeat(List<WhisperSegment> kept, WhisperSegment segment)
    {
        if (kept.LastOrDefault() is not { } last) return segment;
        var lastEnd = last.End ?? last.Start;
        if (segment.Start >= lastEnd) return segment;

        var words = Words(segment.Text);
        var repeated = RepeatedPrefix(TrailingWords(kept), words);
        if (repeated == words.Count) return null;
        if (repeated == 0) return Place(segment, lastEnd);

        var rest = string.Join(" ", words.Skip(repeated).Select(w => w.Original));
        return Place(segment with { Text = rest }, lastEnd);
    }

    /// <summary>The segment moved to start no earlier than <paramref name="previousEnd"/>; End is raised when needed so Start stays at or before it.</summary>
    private static WhisperSegment Place(WhisperSegment segment, double previousEnd)
    {
        var start = Math.Max(segment.Start, previousEnd);
        return segment with { Start = start, End = segment.End is { } end ? Math.Max(end, start) : null };
    }

    private static List<Word> TrailingWords(List<WhisperSegment> segments)
    {
        var words = new List<Word>();
        for (var i = segments.Count - 1; i >= 0 && words.Count < HistoryWords; i--)
        {
            words.InsertRange(0, Words(segments[i].Text));
        }
        return words;
    }

    /// <summary>Length (at most <see cref="MaxStrippedWords"/>) of the longest prefix of <paramref name="next"/> that equals a suffix of <paramref name="previous"/>.</summary>
    private static int RepeatedPrefix(IReadOnlyList<Word> previous, IReadOnlyList<Word> next)
    {
        for (var length = Math.Min(MaxStrippedWords, Math.Min(previous.Count, next.Count)); length > 0; length--)
        {
            if (SuffixMatches(previous, next, length)) return length;
        }
        return 0;
    }

    private static bool SuffixMatches(IReadOnlyList<Word> previous, IReadOnlyList<Word> next, int length)
    {
        var offset = previous.Count - length;
        for (var i = 0; i < length; i++)
        {
            if (previous[offset + i].Key != next[i].Key) return false;
        }
        return true;
    }

    private readonly record struct Word(string Original, string Key);

    /// <summary>Whitespace-separated words, compared case- and punctuation-insensitively; pure punctuation is skipped.</summary>
    private static List<Word> Words(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(token => new Word(token, Key(token)))
            .Where(word => word.Key.Length > 0)
            .ToList();

    private static string Key(string token) =>
        new(token.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());
}
