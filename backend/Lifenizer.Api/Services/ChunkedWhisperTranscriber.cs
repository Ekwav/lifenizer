using System.Diagnostics;
using System.Globalization;

namespace Lifenizer.Api.Services;

/// <summary>
/// Transcribes the chunks of a <see cref="WavChunkPlan"/> in parallel and merges the results.
/// A process-wide semaphore bounds whisper requests across all imports.
/// </summary>
public sealed class ChunkedWhisperTranscriber : IDisposable
{
    private const int DefaultMaxConcurrentRequests = 4;

    /// <summary>The tail is re-sent from this long before the last segment's end, so a word cut at the join is heard whole.</summary>
    public const double TailOverlapSeconds = 0.5;

    /// <summary>Non-silent audio the part after the last segment needs before it is re-sent; a blip or a breath is not worth a request.</summary>
    public const double MinTailSpeechSeconds = 0.5;

    private static readonly TimeSpan RetryDelay = TimeSpan.FromMilliseconds(500);

    private readonly ILogger<ChunkedWhisperTranscriber> logger;
    private readonly SemaphoreSlim gate;
    private readonly TimeSpan chunkTimeout;
    private readonly double timeoutPerAudioSecond;
    private readonly int maxConcurrentRequests;
    private readonly double tailRecoverySeconds;

    /// <summary>One chunk's audio and where it sits in the plan (Number is 1-based, for logs).</summary>
    private sealed record ChunkAudio(byte[] Source, WavFormat Format, WavChunk Chunk, WavSpeechMap? Speech, int Number, int Count);

    /// <summary>A tail recovery: whether a request was made, and the (possibly unchanged) transcript.</summary>
    private sealed record TailRecovery(WhisperTranscriptionResult Result, bool Attempted, int WordsAdded);

    /// <summary>Sends one chunk; the audio body is created per attempt and disposed by the request.</summary>
    public delegate Task<WhisperTranscriptionResult> TranscribeChunk(WavChunkContent audio, CancellationToken cancellationToken);

    public ChunkedWhisperTranscriber(ILogger<ChunkedWhisperTranscriber> logger, IConfiguration configuration)
        : this(logger, MaxConcurrentRequests(configuration), WhisperSettings.ChunkTimeout(configuration), WhisperSettings.TimeoutPerAudioSecond(configuration),
            WhisperSettings.TailRecoverySeconds(configuration))
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

    public ChunkedWhisperTranscriber(ILogger<ChunkedWhisperTranscriber> logger, int maxConcurrentRequests, TimeSpan chunkTimeout,
        double timeoutPerAudioSecond = WhisperSettings.DefaultTimeoutPerAudioSecond, double tailRecoverySeconds = WhisperSettings.DefaultTailRecoverySeconds)
    {
        this.logger = logger;
        gate = new SemaphoreSlim(maxConcurrentRequests, maxConcurrentRequests);
        this.chunkTimeout = chunkTimeout;
        this.timeoutPerAudioSecond = double.IsFinite(timeoutPerAudioSecond) ? Math.Clamp(timeoutPerAudioSecond, 0, 20) : 0;
        this.maxConcurrentRequests = maxConcurrentRequests;
        this.tailRecoverySeconds = WhisperSettings.ClampTailRecovery(tailRecoverySeconds);
    }

    public void Dispose() => gate.Dispose();

    public async Task<WhisperTranscriptionResult> TranscribeAsync(
        byte[] source, WavChunkPlan plan, int maxParallel, TranscribeChunk transcribe, CancellationToken cancellationToken)
    {
        var results = new WhisperTranscriptionResult[plan.Chunks.Count];
        var tailAttempts = 0;
        var recoveredTails = 0;
        var stopwatch = Stopwatch.StartNew();
        var options = new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, maxParallel), CancellationToken = cancellationToken };
        LogPlan(plan);

        // Parallel.ForEachAsync links a token internally: the first failure cancels the other
        // chunks and no new chunk starts afterwards.
        await Parallel.ForEachAsync(Enumerable.Range(0, plan.Chunks.Count), options, async (index, token) =>
        {
            var audio = new ChunkAudio(source, plan.Format, plan.Chunks[index], plan.Speech, index + 1, plan.Chunks.Count);
            var timing = new ChunkTiming();
            var result = await SendAsync(audio, audio.Chunk, transcribe, timing, token);
            logger.LogInformation("Transcribed audio chunk {ChunkNumber}/{ChunkCount} (start {StartSeconds:0.0} s, length {LengthSeconds:0.0} s): whisper {WhisperMs} ms, queued {QueuedMs} ms, {Attempts} attempt(s)",
                audio.Number, audio.Count, audio.Chunk.Start.TotalSeconds, ChunkSeconds(plan, audio.Chunk), timing.WhisperMs, timing.QueuedMs, timing.Attempts);
            var recovery = await RecoverTailAsync(audio, result, transcribe, token);
            if (recovery.Attempted) Interlocked.Increment(ref tailAttempts);
            if (recovery.WordsAdded > 0) Interlocked.Increment(ref recoveredTails);
            results[index] = recovery.Result;
        });

        logger.LogInformation("Transcribed {ChunkCount} audio chunks with concurrency {Concurrency} in {ElapsedMs} ms, recovered {RecoveredTails}/{TailAttempts} cut-off tail(s)",
            plan.Chunks.Count, options.MaxDegreeOfParallelism, stopwatch.ElapsedMilliseconds, recoveredTails, tailAttempts);
        return Merge(plan, results);
    }

    /// <summary>
    /// Tail recovery for a file sent whole. <paramref name="durationSeconds"/> is a cheap duration lookup (no decoding);
    /// only when the transcript ends more than the threshold before it does, <paramref name="loadPcm"/> gives the audio
    /// as one PCM chunk (null when the format cannot be sliced). The tail goes out as a WAV slice. Best effort: a failing
    /// load or recovery leaves <paramref name="result"/> as it is.
    /// </summary>
    public async Task<WhisperTranscriptionResult> RecoverWholeFileTailAsync(
        WhisperTranscriptionResult result, Func<double?> durationSeconds, Func<CancellationToken, Task<AudioChunkSource?>> loadPcm,
        TranscribeChunk transcribe, CancellationToken cancellationToken)
    {
        if (tailRecoverySeconds <= 0 || LastSegmentEnd(result) is not { } lastEnd) return result;

        try
        {
            if (durationSeconds() is not { } duration || duration - lastEnd <= tailRecoverySeconds) return result;

            using var source = await loadPcm(cancellationToken);
            if (source is null || source.Plan.Chunks.Count != 1) return result;

            var audio = new ChunkAudio(source.Bytes, source.Plan.Format, source.Plan.Chunks[0], source.Plan.Speech, 1, 1);
            return (await RecoverTailAsync(audio, result, transcribe, cancellationToken)).Result;
        }
        catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
        {
            logger.LogWarning(exception, "Could not read the duration or load the audio to recover the cut-off tail of the whole file ({ExceptionType}: {Message}); keeping the transcript as is",
                exception.GetType().Name, exception.Message);
            return result;
        }
    }

    private static double ChunkSeconds(WavChunkPlan plan, WavChunk chunk) => ChunkSeconds(plan.Format, chunk);

    private static double ChunkSeconds(WavFormat format, WavChunk chunk) =>
        (double)chunk.ByteLength / format.BlockAlign / format.SampleRate;

    /// <summary>Sends <paramref name="range"/> of the source through the gate, timeout and retry policy of a chunk.</summary>
    private Task<WhisperTranscriptionResult> SendAsync(ChunkAudio audio, WavChunk range, TranscribeChunk transcribe, ChunkTiming timing, CancellationToken token, string? language = null)
    {
        var timeout = TimeoutFor(chunkTimeout, ChunkSeconds(audio.Format, range), timeoutPerAudioSecond, maxConcurrentRequests);
        return WithRetryAsync(() => new WavChunkContent(audio.Source, audio.Format, range) { Language = language }, timeout, transcribe, timing, token);
    }

    /// <summary>
    /// The trained whisper sometimes stops early. When the transcript ends well before the chunk does and speech
    /// follows, the tail is sent once more (never recursively) and its text appended. Best effort: when the tail request
    /// fails the transcript is returned unchanged; only cancellation propagates.
    /// </summary>
    private async Task<TailRecovery> RecoverTailAsync(ChunkAudio audio, WhisperTranscriptionResult result, TranscribeChunk transcribe, CancellationToken token)
    {
        if (TailToRecover(audio, result) is not { } tail) return new TailRecovery(result, false, 0);

        try
        {
            return await SendAndMergeTailAsync(audio, tail, result, transcribe, token);
        }
        catch (Exception exception) when (!token.IsCancellationRequested)
        {
            logger.LogWarning(exception, "Could not recover the tail of audio chunk {ChunkNumber}/{ChunkCount} (tail start {TailStartSeconds:0.0} s): {ExceptionType}: {Message}; keeping the chunk's transcript",
                audio.Number, audio.Count, tail.Start.TotalSeconds, exception.GetType().Name, exception.Message);
            return new TailRecovery(result, true, 0);
        }
    }

    private async Task<TailRecovery> SendAndMergeTailAsync(ChunkAudio audio, WavChunk tail, WhisperTranscriptionResult result, TranscribeChunk transcribe, CancellationToken token)
    {
        var timing = new ChunkTiming();
        var tailResult = await SendAsync(audio, tail, transcribe, timing, token, result.Language);
        var recovery = WhisperTailMerge.Append(result, tailResult, (tail.Start - audio.Chunk.Start).TotalSeconds);
        var level = recovery.WordsAdded > 0 ? LogLevel.Information : LogLevel.Debug;
        logger.Log(level, "Tail of audio chunk {ChunkNumber}/{ChunkCount} re-sent (tail start {TailStartSeconds:0.0} s, length {TailLengthSeconds:0.0} s): added {RecoveredWords} word(s), whisper {WhisperMs} ms",
            audio.Number, audio.Count, tail.Start.TotalSeconds, ChunkSeconds(audio.Format, tail), recovery.WordsAdded, timing.WhisperMs);
        return new TailRecovery(recovery.Result, true, recovery.WordsAdded);
    }

    /// <summary>
    /// The range to re-send, or null: recovery off, no end time to judge, a gap below the threshold, no speech
    /// after the last segment, or a tail that would be the whole chunk again (whisper would answer the same).
    /// </summary>
    private WavChunk? TailToRecover(ChunkAudio audio, WhisperTranscriptionResult result)
    {
        if (tailRecoverySeconds <= 0 || audio.Speech is null || LastSegmentEnd(result) is not { } lastEnd) return null;
        if (ChunkSeconds(audio.Format, audio.Chunk) - lastEnd <= tailRecoverySeconds) return null;

        var unheard = TailFrom(audio, lastEnd);
        if (!audio.Speech.HasSpeech(unheard.ByteOffset, unheard.ByteLength, MinTailSpeechSeconds)) return null;
        var tail = TailFrom(audio, lastEnd - TailOverlapSeconds);
        return tail.ByteOffset > audio.Chunk.ByteOffset ? tail : null;
    }

    /// <summary>End of the last segment in chunk seconds; null when whisper returned none or gave no end time.</summary>
    private static double? LastSegmentEnd(WhisperTranscriptionResult result) =>
        result.Segments.Count > 0 && result.Segments[^1].End is { } end && double.IsFinite(end) ? Math.Max(0, end) : null;

    /// <summary>The chunk from <paramref name="seconds"/> (chunk time, clamped to the chunk) to its end, cut on a sample boundary.</summary>
    private static WavChunk TailFrom(ChunkAudio audio, double seconds)
    {
        var chunkSamples = audio.Chunk.ByteLength / audio.Format.BlockAlign;
        var sample = (int)Math.Clamp(Math.Floor(seconds * audio.Format.SampleRate), 0, chunkSamples);
        var bytes = sample * audio.Format.BlockAlign;
        var start = audio.Chunk.Start + TimeSpan.FromSeconds((double)sample / audio.Format.SampleRate);
        return new WavChunk(audio.Chunk.ByteOffset + bytes, audio.Chunk.ByteLength - bytes, start);
    }

    /// <summary>The plan line lists at most this many chunks, so it stays below the 16 KiB container log line limit.</summary>
    public const int MaxLoggedPlanEntries = 50;

    /// <summary>One line per file: the chunks' start and length in seconds, in send order (the first MaxLoggedPlanEntries).</summary>
    private void LogPlan(WavChunkPlan plan)
    {
        if (!logger.IsEnabled(LogLevel.Information)) return;
        logger.LogInformation("Planned {ChunkCount} audio chunks (start+length in s): {ChunkPlan}", plan.Chunks.Count, DescribePlan(plan));
    }

    private static string DescribePlan(WavChunkPlan plan)
    {
        var pieces = plan.Chunks.Take(MaxLoggedPlanEntries).Select((chunk, i) =>
            string.Create(CultureInfo.InvariantCulture, $"#{i + 1} {chunk.Start.TotalSeconds:0.0}+{ChunkSeconds(plan, chunk):0.0}"));
        var text = string.Join(", ", pieces);
        var more = plan.Chunks.Count - MaxLoggedPlanEntries;
        return more > 0 ? $"{text}, … {more} more" : text;
    }

    /// <summary>Per chunk: time spent waiting for a global slot and time spent in whisper, summed over attempts.</summary>
    private sealed class ChunkTiming
    {
        private TimeSpan queued;
        private TimeSpan whisper;

        public int Attempts { get; private set; }
        public long QueuedMs => (long)queued.TotalMilliseconds;
        public long WhisperMs => (long)whisper.TotalMilliseconds;

        public void AddQueued(long waitStarted) => queued += Stopwatch.GetElapsedTime(waitStarted);

        public async Task<T> TimeWhisperAsync<T>(Func<Task<T>> request)
        {
            Attempts++;
            var started = Stopwatch.GetTimestamp();
            try
            {
                return await request();
            }
            finally
            {
                whisper += Stopwatch.GetElapsedTime(started);
            }
        }
    }

    private async Task<WhisperTranscriptionResult> WithRetryAsync(Func<WavChunkContent> audio, TimeSpan timeout, TranscribeChunk transcribe, ChunkTiming timing, CancellationToken token)
    {
        try
        {
            return await AttemptAsync(audio, timeout, transcribe, timing, token);
        }
        catch (Exception exception) when (IsRetryable(exception) && !token.IsCancellationRequested)
        {
            logger.LogWarning(exception, "Audio chunk transcription failed transiently; retrying once");
            await Task.Delay(RetryDelay, token);
            return await AttemptAsync(audio, timeout, transcribe, timing, token);
        }
    }

    /// <summary>One chunk request: waits for a global slot (not counted against the timeout), then runs under the chunk's timeout.</summary>
    private async Task<WhisperTranscriptionResult> AttemptAsync(Func<WavChunkContent> audio, TimeSpan chunkTimeout, TranscribeChunk transcribe, ChunkTiming timing, CancellationToken token)
    {
        var waitStarted = Stopwatch.GetTimestamp();
        return await RunGatedAsync(slotToken =>
        {
            timing.AddQueued(waitStarted);
            return timing.TimeWhisperAsync(() => WithTimeoutAsync(chunkTimeout, timed => transcribe(audio(), timed), slotToken));
        }, token);
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
