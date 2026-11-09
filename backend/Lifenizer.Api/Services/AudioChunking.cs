namespace Lifenizer.Api.Services;

/// <summary>Chooses how an uploaded audio file can be chunked (WAV directly, Ogg Opus after decoding).</summary>
public static class AudioChunking
{
    public const int DefaultMaxAudioSeconds = 4 * 60 * 60;
    private const int PlanningOverheadDivisor = 16;

    /// <summary>
    /// Null when the audio need not be chunked (short, or a format we pass through unchanged) and is sent whole.
    /// The returned source holds audio-memory budget until disposed. CPU-bound work runs on the thread pool.
    /// </summary>
    /// <exception cref="AudioTooLongException">WAV or Ogg audio exceeds the duration cap (never sent on).</exception>
    /// <exception cref="UnsupportedAudioException">Ogg that is not a clean single-stream Opus file, or an out-of-range WAV rate.</exception>
    /// <exception cref="InvalidOpusStreamException">An Ogg Opus packet is impossibly large.</exception>
    /// <exception cref="AudioMemoryBudgetExceededException">The audio needs more memory than the whole budget.</exception>
    public static Task<AudioChunkSource?> TryCreateSourceAsync(byte[] audio, AudioLimits limits, CancellationToken cancellationToken) =>
        OggOpusDecoder.IsOgg(audio) ? FromOggAsync(audio, limits, cancellationToken) : FromWavAsync(audio, limits, cancellationToken);

    /// <summary>
    /// A file that was sent whole, as one PCM chunk with its speech map, so its tail can be re-sent: PCM16 WAV as is,
    /// Ogg Opus decoded (under the memory budget). Null for formats that cannot be sliced or Opus that does not decode.
    /// </summary>
    public static async Task<AudioChunkSource?> TryLoadWholeAsync(byte[] audio, AudioLimits limits, CancellationToken cancellationToken)
    {
        if (OggOpusDecoder.IsOgg(audio)) return await WholeOggAsync(audio, limits, cancellationToken);
        var layout = WavSilenceChunker.ParseLayout(audio);
        if (layout is null) return null;
        return new AudioChunkSource(audio, WavSilenceChunker.WholePlan(audio, layout, limits.Chunking), null);
    }

    /// <summary>
    /// Duration of a file without decoding it: a PCM16 WAV from its header, an Ogg Opus from its pages. Null when unknown
    /// (other formats, or an Ogg that is not a clean Opus stream).
    /// </summary>
    public static double? WholeDurationSeconds(byte[] audio)
    {
        if (!OggOpusDecoder.IsOgg(audio)) return WavSeconds(WavSilenceChunker.ParseLayout(audio));
        try
        {
            return OpusStreamScanner.Scan(audio).DecodableSamples48k / 48000.0;
        }
        catch (Exception exception) when (exception is UnsupportedAudioException or InvalidOpusStreamException)
        {
            return null;
        }
    }

    private static double? WavSeconds(WavLayout? layout) =>
        layout is null ? null : (double)layout.DataLength / layout.Format.BlockAlign / layout.Format.SampleRate;

    private static async Task<AudioChunkSource?> WholeOggAsync(byte[] ogg, AudioLimits limits, CancellationToken cancellationToken)
    {
        var scan = await Task.Run(() => OpusStreamScanner.Scan(ogg), cancellationToken);
        if (scan.ExceedsSeconds(limits.MaxAudioSeconds)) return null;
        var lease = await limits.Budget.AcquireAsync(OggOpusDecoder.OutputBytes(scan), cancellationToken);
        return await ReleaseUnlessBuiltAsync(lease, () => DecodeWholeAsync(ogg, scan, limits, lease, cancellationToken));
    }

    private static async Task<AudioChunkSource?> DecodeWholeAsync(byte[] ogg, OpusScan scan, AudioLimits limits, IDisposable lease, CancellationToken cancellationToken)
    {
        try
        {
            var pcm = await Task.Run(() => OggOpusDecoder.DecodeToPcm16(ogg, scan, limits.MaxAudioSeconds, cancellationToken), cancellationToken);
            var layout = new WavLayout(OggOpusDecoder.Format, 0, pcm.Length - pcm.Length % 2);
            if (layout.DataLength == 0) return null;
            return new AudioChunkSource(pcm, WavSilenceChunker.WholePlan(pcm, layout, limits.Chunking), lease);
        }
        catch (OpusDecodeException)
        {
            return null;
        }
    }

    /// <summary>Runs <paramref name="build"/> (which hands the lease to the source it returns); releases the lease when nothing is built or building throws.</summary>
    private static async Task<AudioChunkSource?> ReleaseUnlessBuiltAsync(IDisposable lease, Func<Task<AudioChunkSource?>> build)
    {
        try
        {
            var built = await build();
            if (built is null) lease.Dispose();
            return built;
        }
        catch
        {
            lease.Dispose();
            throw;
        }
    }

    private static async Task<AudioChunkSource?> FromWavAsync(byte[] wav, AudioLimits limits, CancellationToken cancellationToken)
    {
        var layout = WavSilenceChunker.ParseLayout(wav);
        if (layout is null) return null;
        var seconds = (double)layout.DataLength / layout.Format.BlockAlign / layout.Format.SampleRate;
        if (seconds > limits.MaxAudioSeconds) throw new AudioTooLongException(limits.MaxAudioSeconds);
        if (seconds <= (limits.Chunking ?? WavSilenceChunker.DefaultOptions).NoChunkUpTo.TotalSeconds) return null;

        var lease = await limits.Budget.AcquireAsync(wav.Length + wav.Length / PlanningOverheadDivisor, cancellationToken);
        try
        {
            var plan = await Task.Run(() => WavSilenceChunker.TryPlan(wav, layout, limits.Chunking), cancellationToken);
            if (plan is null)
            {
                lease.Dispose();
                return null;
            }
            return new AudioChunkSource(wav, plan, lease);
        }
        catch
        {
            lease.Dispose();
            throw;
        }
    }

    private static async Task<AudioChunkSource?> FromOggAsync(byte[] ogg, AudioLimits limits, CancellationToken cancellationToken)
    {
        var scan = await Task.Run(() => OpusStreamScanner.Scan(ogg), cancellationToken);
        if (scan.ExceedsSeconds(limits.MaxAudioSeconds)) throw new AudioTooLongException(limits.MaxAudioSeconds);
        if (scan.DecodableSamples48k <= (limits.Chunking ?? WavSilenceChunker.DefaultOptions).NoChunkUpTo.TotalSeconds * 48000) return null;

        var lease = await limits.Budget.AcquireAsync(OggOpusDecoder.OutputBytes(scan), cancellationToken);
        return await ReleaseUnlessBuiltAsync(lease, () => DecodeAndPlanAsync(ogg, scan, limits, lease, cancellationToken));
    }

    private static async Task<AudioChunkSource?> DecodeAndPlanAsync(byte[] ogg, OpusScan scan, AudioLimits limits, IDisposable lease, CancellationToken cancellationToken)
    {
        var pcm = await Task.Run(() => Decode(ogg, scan, limits.MaxAudioSeconds, cancellationToken), cancellationToken);
        var plan = WavSilenceChunker.PlanPcm(pcm, new WavLayout(OggOpusDecoder.Format, 0, pcm.Length - pcm.Length % 2), limits.Chunking);
        return plan is null ? null : new AudioChunkSource(pcm, plan, lease);
    }

    private static byte[] Decode(byte[] ogg, OpusScan scan, int maxAudioSeconds, CancellationToken cancellationToken)
    {
        try
        {
            return OggOpusDecoder.DecodeToPcm16(ogg, scan, maxAudioSeconds, cancellationToken);
        }
        catch (OpusDecodeException exception)
        {
            throw UnsupportedAudioException.Ogg(exception);
        }
    }
}
