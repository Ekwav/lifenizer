using System.Globalization;

namespace Lifenizer.Api.Services.Utilities;

/// <summary>
/// Utilities for detecting import format types and handling format-specific fallback parsing.
/// </summary>
public static class FormatDetector
{
    /// <summary>
    /// Determines if a string looks like JSON (starts with { or [).
    /// </summary>
    public static bool IsJson(string value)
    {
        var trimmed = value.TrimStart();
        return trimmed.StartsWith('{') || trimmed.StartsWith('[');
    }

    /// <summary>
    /// Determines if a string looks like XML (starts with &lt;).
    /// </summary>
    public static bool IsXml(string value)
    {
        var trimmed = value.TrimStart();
        return trimmed.StartsWith('<');
    }

    /// <summary>
    /// Determines if a string looks like CSV (contains commas and newlines with headers).
    /// </summary>
    public static bool LooksLikeCsv(string value)
    {
        if (!value.Contains(','))
        {
            return false;
        }

        var firstLine = value.Split('\n').FirstOrDefault();
        return firstLine is not null && (
            firstLine.Contains("message", StringComparison.OrdinalIgnoreCase) ||
            firstLine.Contains("sender", StringComparison.OrdinalIgnoreCase) ||
            firstLine.Contains("from", StringComparison.OrdinalIgnoreCase) ||
            firstLine.Contains("text", StringComparison.OrdinalIgnoreCase)
        );
    }

    /// <summary>
    /// Checks if a string is likely a timestamp in common formats.
    /// </summary>
    public static bool IsTimestamp(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        // Try parsing as DateTimeOffset first
        if (DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out _))
        {
            return true;
        }

        // Check if it looks like Unix epoch (all digits, reasonable length)
        if (double.TryParse(value, System.Globalization.NumberStyles.Float, CultureInfo.InvariantCulture, out var epochSeconds))
        {
            // Unix epoch should be between 0 and ~40 years of seconds (~1.26 billion for 2010)
            // or milliseconds (13 digits max)
            return (epochSeconds >= 0 && epochSeconds <= 5000000000) || (epochSeconds >= 1000000000000 && epochSeconds <= 9999999999999);
        }

        return false;
    }

    /// <summary>
    /// Detects if a value is likely an email address.
    /// </summary>
    public static bool IsEmailLike(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        return value.Contains('@') && value.Contains('.');
    }
}
