using System.Collections.Concurrent;
using Microsoft.Extensions.Logging;

namespace Lifenizer.Tests;

/// <summary>Keeps every Information+ entry: its level, formatted message and structured values.</summary>
internal sealed class ListLogger<T> : ILogger<T>
{
    private readonly ConcurrentQueue<Entry> entries = new();

    public sealed record Entry(LogLevel Level, string Message, IReadOnlyDictionary<string, object?> Values);

    public IReadOnlyList<Entry> Entries => entries.ToList();

    public IReadOnlyList<string> Lines => entries.Select(e => e.Message).ToList();

    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

    public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Information;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        if (!IsEnabled(logLevel)) return;
        var values = state as IEnumerable<KeyValuePair<string, object?>> ?? [];
        entries.Enqueue(new Entry(logLevel, formatter(state, exception), values.ToDictionary(v => v.Key, v => v.Value)));
    }
}
