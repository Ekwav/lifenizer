using System.Diagnostics;

namespace Lifenizer.Api.Services;

/// <summary>
/// Transcribes the chunks of a <see cref="WavChunkPlan"/> in parallel and merges the results.
/// A process-wide semaphore bounds whisper requests across all imports.
/// </summary>
public sealed class ChunkedWhisperTranscriber : IDisposable
{
    private const int DefaultMaxConcurrentRequests = 4;
    private const int DefaultChunkTimeoutSeconds = 180;
    private static readonly TimeSpan RetryDelay = TimeSpan.FromMilliseconds(500);

    private readonly ILogger<ChunkedWhisperTranscriber> logger;
    private readonly SemaphoreSlim gate;
    private readonly TimeSpan chunkTimeout;

    public delegate Task<WhisperTranscriptionResult> TranscribeChunk(byte[] wav, CancellationToken cancellationToken);

    public ChunkedWhisperTranscriber(ILogger<ChunkedWhisperTranscriber> logger, IConfiguration configuration)
        : this(logger, MaxConcurrentRequests(configuration), ChunkTimeout(configuration))
    {
    }

    public static int MaxConcurrentRequests(IConfiguration configuration) =>
        Math.Clamp(configuration.GetValue("Whisper:MaxConcurrentRequests", DefaultMaxConcurrentRequests), 1, 64);

    public static TimeSpan ChunkTimeout(IConfiguration configuration) =>
        TimeSpan.FromSeconds(Math.Max(1, configuration.GetValue("Whisper:ChunkTimeoutSeconds", DefaultChunkTimeoutSeconds)));

    public ChunkedWhisperTranscriber(ILogger<ChunkedWhisperTranscriber> logger, int maxConcurrentRequests, TimeSpan chunkTimeout)
    {
        this.logger = logger;
        gate = new SemaphoreSlim(maxConcurrentRequests, maxConcurrentRequests);
        this.chunkTimeout = chunkTimeout;
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
            var wav = WavSilenceChunker.ToWav(source, plan.Format, plan.Chunks[index]);
            results[index] = await WithRetryAsync(wav, transcribe, token);
        });

        logger.LogInformation("Transcribed {ChunkCount} audio chunks with concurrency {Concurrency} in {ElapsedMs} ms",
            plan.Chunks.Count, options.MaxDegreeOfParallelism, stopwatch.ElapsedMilliseconds);
        return Merge(plan, results);
    }

    private async Task<WhisperTranscriptionResult> WithRetryAsync(byte[] wav, TranscribeChunk transcribe, CancellationToken token)
    {
        try
        {
            return await AttemptAsync(wav, transcribe, token);
        }
        catch (Exception exception) when (IsRetryable(exception) && !token.IsCancellationRequested)
        {
            logger.LogWarning(exception, "Audio chunk transcription failed transiently; retrying once");
            await Task.Delay(RetryDelay, token);
            return await AttemptAsync(wav, transcribe, token);
        }
    }

    /// <summary>One chunk request: waits for a global slot (not counted against the timeout), then runs under the chunk timeout.</summary>
    private async Task<WhisperTranscriptionResult> AttemptAsync(byte[] wav, TranscribeChunk transcribe, CancellationToken token)
    {
        return await RunGatedAsync(async slotToken =>
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(slotToken);
            timeout.CancelAfter(chunkTimeout);
            try
            {
                return await transcribe(wav, timeout.Token);
            }
            catch (OperationCanceledException) when (!slotToken.IsCancellationRequested)
            {
                throw new WhisperTimeoutException($"Whisper transcription of an audio chunk timed out after {chunkTimeout.TotalSeconds:0} s.");
            }
        }, token);
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
