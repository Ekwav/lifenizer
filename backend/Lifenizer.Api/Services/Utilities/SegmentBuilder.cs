using Lifenizer.Core;

namespace Lifenizer.Api.Services.Utilities;

/// <summary>
/// Fluent builder for constructing NormalizedSegment instances with optional fields and validation.
/// Reduces repetitive segment creation boilerplate across multiple parsers.
/// </summary>
public sealed class SegmentBuilder
{
    private string? _text;
    private string? _speaker;
    private int _offsetMs;
    private DateTimeOffset? _createdAt;

    /// <summary>
    /// Sets the segment text content. Required field.
    /// </summary>
    /// <exception cref="ArgumentException">Thrown when text is null or whitespace.</exception>
    public SegmentBuilder WithText(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            throw new ArgumentException("Segment text cannot be empty or whitespace", nameof(text));
        }
        _text = text.Trim();
        return this;
    }

    /// <summary>
    /// Sets the speaker/author of the segment. Optional.
    /// </summary>
    public SegmentBuilder WithSpeaker(string? speaker)
    {
        _speaker = string.IsNullOrWhiteSpace(speaker) ? null : speaker.Trim();
        return this;
    }

    /// <summary>
    /// Sets the absolute offset in milliseconds from segment start. Defaults to 0.
    /// </summary>
    public SegmentBuilder WithTimestamp(DateTimeOffset? createdAt)
    {
        _createdAt = createdAt;
        return this;
    }

    /// <summary>
    /// Sets the offset in milliseconds, typically based on segment index. Use for auto-sequencing when actual timestamps unavailable.
    /// </summary>
    public SegmentBuilder WithAutoOffset(int segmentIndex, int msPerSegment = 1000)
    {
        _offsetMs = segmentIndex * msPerSegment;
        return this;
    }

    /// <summary>
    /// Sets the offset explicitly in milliseconds.
    /// </summary>
    public SegmentBuilder WithOffset(int offsetMs)
    {
        _offsetMs = offsetMs;
        return this;
    }

    /// <summary>
    /// Builds the NormalizedSegment with validated fields.
    /// </summary>
    /// <returns>A new NormalizedSegment instance.</returns>
    /// <exception cref="InvalidOperationException">Thrown when required fields (text) are not set.</exception>
    public NormalizedSegment Build()
    {
        if (string.IsNullOrWhiteSpace(_text))
        {
            throw new InvalidOperationException("Cannot build segment without text. Use WithText() to set content");
        }

        return new NormalizedSegment(_text, _speaker, _offsetMs, _createdAt ?? DateTimeOffset.UtcNow);
    }

    /// <summary>
    /// Resets the builder for reuse. Useful when building multiple segments in a loop.
    /// </summary>
    public SegmentBuilder Reset()
    {
        _text = null;
        _speaker = null;
        _offsetMs = 0;
        _createdAt = null;
        return this;
    }
}
