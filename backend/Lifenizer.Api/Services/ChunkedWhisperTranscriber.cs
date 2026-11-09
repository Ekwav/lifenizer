using System.Diagnostics;

namespace Lifenizer.Api.Services;

/// <summary>
/// Transcribes the chunks of a <see cref="WavChunkPlan"/> in parallel and merges the results.
/// A process-wide semaphore bounds whisper requests across all imports.
/// </summary>
public sealed class ChunkedWhisperTranscriber : IDisposable
{
    private const int DefaultMaxConcurrentRequests = 4;
    private static readonly TimeSpan RetryDelay = TimeSpan.FromMilliseconds(500);

    private readonly ILogger<ChunkedWhisperTranscriber> logger;
    private readonly SemaphoreSlim gate;
    private readonly TimeSpan chunkTimeout;
    private readonly double timeoutPerAudioSecond;
    private readonly int maxConcurrentRequests;

    /// <summary>Sends one chunk; the audio body is created per attempt and disposed by the request.</summary>
    public delegate Task<WhisperTranscriptionResult> TranscribeChunk(WavChunkContent audio, CancellationToken cancellationToken);

    public ChunkedWhisperTranscriber(ILogger<ChunkedWhisperTranscriber> logger, IConfiguration configuration)
        : this(logger, MaxConcurrentRequests(configuration), WhisperSettings.ChunkTimeout(configuration), WhisperSettings.TimeoutPerAudioSecond(configuration))
    {
    }

    public static int MaxConcurrentRequests(IConfiguration configuration) =>
        Math.Clamp(configuration.GetValue("Whisper:MaxConcurrentRequests", DefaultMaxConcurrentRequests), 1, 64);

    /// <summary>
    /// Base timeout, or the chunk's audio length times <paramref name="perAudioSecond"/> times the number of
    /// requests that may queue inside whisper (it serves them one at a time per replica), whichever is longer.
    /// </summary>
    public static TimeSpan TimeoutFor(TimeSpan baseTimeout, double chunkSeconds, double perAudioSecond, int maxConcurrentRequests)
    {
        var scaled = chunkSeconds * perAudioSecond * Math.Max(1, maxConcurrentRequests);
        var seconds = Math.Max(baseTimeout.TotalSeconds, double.IsFinite(scaled) ? scaled : 0);
        return TimeSpan.FromSeconds(Math.Min(seconds, WhisperSettings.MaxTimeoutSeconds));
    }

    public ChunkedWhisperTranscriber(ILogger<ChunkedWhisperTranscriber> logger, int maxConcurrentRequests, TimeSpan chunkTimeout, double timeoutPerAudioSecond = WhisperSettings.DefaultTimeoutPerAudioSecond)
    {
        this.logger = logger;
        gate = new SemaphoreSlim(maxConcurrentRequests, maxConcurrentRequests);
        this.chunkTimeout = chunkTimeout;
        this.timeoutPerAudioSecond = double.IsFinite(timeoutPerAudioSecond) ? Math.Clamp(timeoutPerAudioSecond, 0, 20) : 0;
        this.maxConcurrentRequests = maxConcurrentRequests;
    }

    public void Dispose() => gate.Dispose();

    public async Task<WhisperTranscriptionResult> TranscribeAsync(
        byte[] source, WavChunkPlan plan, int maxParallel, TranscribeChunk transcribe, CancellationToken cancellationToken)
    {
        var results = new WhisperTranscriptionResult[plan.Chunks.Count];
        var stopwatch = Stopwatch.StartNew();
        var options = new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, maxParallel), CancellationToken = cancellationToken };

        // Parallel.ForEachAsync links a token internally: the first failure cancels the other
        // chunks and no new chunk starts afterwards.
        await Parallel.ForEachAsync(Enumerable.Range(0, plan.Chunks.Count), options, async (index, token) =>
        {
            var chunk = plan.Chunks[index];
            var seconds = (double)chunk.ByteLength / plan.Format.BlockAlign / plan.Format.SampleRate;
            results[index] = await WithRetryAsync(() => new WavChunkContent(source, plan.Format, chunk), TimeoutFor(chunkTimeout, seconds, timeoutPerAudioSecond, maxConcurrentRequests), transcribe, token);
        });

        logger.LogInformation("Transcribed {ChunkCount} audio chunks with concurrency {Concurrency} in {ElapsedMs} ms",
            plan.Chunks.Count, options.MaxDegreeOfParallelism, stopwatch.ElapsedMilliseconds);
        return Merge(plan, results);
    }

    private async Task<WhisperTranscriptionResult> WithRetryAsync(Func<WavChunkContent> audio, TimeSpan timeout, TranscribeChunk transcribe, CancellationToken token)
    {
        try
        {
            return await AttemptAsync(audio, timeout, transcribe, token);
        }
        catch (Exception exception) when (IsRetryable(exception) && !token.IsCancellationRequested)
        {
            logger.LogWarning(exception, "Audio chunk transcription failed transiently; retrying once");
            await Task.Delay(RetryDelay, token);
            return await AttemptAsync(audio, timeout, transcribe, token);
        }
    }

    /// <summary>One chunk request: waits for a global slot (not counted against the timeout), then runs under the chunk's timeout.</summary>
    private async Task<WhisperTranscriptionResult> AttemptAsync(Func<WavChunkContent> audio, TimeSpan chunkTimeout, TranscribeChunk transcribe, CancellationToken token)
    {
        return await RunGatedAsync(
            slotToken => WithTimeoutAsync(chunkTimeout, timed => transcribe(audio(), timed), slotToken), token);
    }

    /// <summary>Runs the request under a timeout; expiry is a <see cref="WhisperTimeoutException"/>, the caller's own cancellation stays an <see cref="OperationCanceledException"/>.</summary>
    public static async Task<T> WithTimeoutAsync<T>(TimeSpan timeout, Func<CancellationToken, Task<T>> request, CancellationToken token)
    {
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeoutSource.CancelAfter(timeout);
        try
        {
            return await request(timeoutSource.Token);
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            throw new WhisperTimeoutException($"Whisper transcription timed out after {timeout.TotalSeconds:0} s.");
        }
    }

    /// <summary>Runs any whisper request under the process-wide concurrency limit (no timeout beyond the caller's).</summary>
    public async Task<T> RunGatedAsync<T>(Func<CancellationToken, Task<T>> request, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            return await request(token);
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>Timeouts are not retried: whisper keeps working on abandoned requests, so a retry doubles the load.</summary>
    private static bool IsRetryable(Exception exception) =>
        exception is HttpRequestException or WhisperTransientException;

    /// <summary>
    /// Orders by chunk, shifts segment times by each chunk's offset and joins texts with a space.
    /// </summary>
    public static WhisperTranscriptionResult Merge(WavChunkPlan plan, WhisperTranscriptionResult[] results)
    {
        var segments = new List<WhisperSegment>();
        for (var i = 0; i < results.Length; i++)
        {
            var offset = plan.Chunks[i].Start.TotalSeconds;
            segments.AddRange(results[i].Segments.Select(s => new WhisperSegment(s.Start + offset, s.End + offset, s.Text)));
        }

        var text = string.Join(" ", results.Select(r => r.Text.Trim()).Where(t => t.Length > 0));
        return new WhisperTranscriptionResult(text, MajorityLanguage(results), segments);
    }

    /// <summary>Most frequent non-empty chunk language; ties go to the earliest chunk.</summary>
    private static string? MajorityLanguage(IEnumerable<WhisperTranscriptionResult> results) =>
        results.Select(r => r.Language).Where(l => !string.IsNullOrWhiteSpace(l))
            .GroupBy(l => l!, StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(g => g.Count())
            .FirstOrDefault()?.Key;
}
