using System.Text.Json;

namespace Lifenizer.Api.Services.Utilities;

/// <summary>
/// Utility for extracting string values from JSON elements with fallback field names.
/// Eliminates repetitive null coalescing chains (a ?? b ?? c ?? d) across multiple parsers.
/// </summary>
public static class JsonFieldExtractor
{
    /// <summary>
    /// Extracts a string value from a JsonElement, trying multiple field names in order.
    /// Returns the first non-null, non-empty value found.
    /// </summary>
    /// <param name="element">The JSON element to extract from.</param>
    /// <param name="fallbackNames">Property names to try in order of preference.</param>
    /// <returns>The extracted string value, or null if no field found or all are empty.</returns>
    public static string? GetString(JsonElement element, params string[] fallbackNames)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        foreach (var propertyName in fallbackNames)
        {
            if (element.TryGetProperty(propertyName, out var value))
            {
                var result = ToStringValue(value);
                if (!string.IsNullOrWhiteSpace(result))
                {
                    return result.Trim();
                }
            }
        }

        return null;
    }

    /// <summary>
    /// Extracts a string value from nested JSON object path (e.g., "author.name").
    /// </summary>
    /// <param name="element">The root JSON element.</param>
    /// <param name="path">Dot-separated path like "author.displayName".</param>
    /// <returns>The extracted string value, or null if path not found.</returns>
    public static string? GetStringByPath(JsonElement element, string path)
    {
        var parts = path.Split('.', StringSplitOptions.RemoveEmptyEntries);
        var current = element;

        foreach (var part in parts)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(part, out current))
            {
                return null;
            }
        }

        return ToStringValue(current)?.Trim();
    }

    /// <summary>
    /// Extracts a string value from a nested object by first field name.
    /// Tries multiple property names on the nested object.
    /// </summary>
    /// <example>
    /// GetNestedString(messageElement, "author", "name", "displayName", "username")
    /// will look for message.author.name, message.author.displayName, message.author.username
    /// </example>
    public static string? GetNestedString(JsonElement element, string parentProperty, params string[] childProperties)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(parentProperty, out var parent))
        {
            return null;
        }

        return GetString(parent, childProperties);
    }

    /// <summary>
    /// Extracts a chat message author's display name. Checks a nested "author" object/string
    /// first (username/name/global_name), then falls back to message-level from/sender/username
    /// fields. Shared by the Discord, Slack, Facebook Messenger, and Instagram parsers, which all
    /// use this same author shape.
    /// </summary>
    public static string? GetAuthorName(JsonElement message)
    {
        if (message.ValueKind == JsonValueKind.Object && message.TryGetProperty("author", out var author))
        {
            if (author.ValueKind == JsonValueKind.String) return author.GetString();
            if (author.ValueKind == JsonValueKind.Object)
            {
                return GetString(author, "username", "name", "global_name");
            }
        }
        return GetString(message, "from", "sender", "username");
    }

    /// <summary>
    /// Converts a JsonElement to its string representation, handling all JSON types.
    /// </summary>
    private static string? ToStringValue(JsonElement element)
    {
        return element.ValueKind switch
        {
            JsonValueKind.String => element.GetString(),
            JsonValueKind.Number => element.ToString(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            JsonValueKind.Null => null,
            _ => null
        };
    }
}
