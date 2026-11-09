using System.Net;
using System.Net.Http.Headers;

namespace Lifenizer.Api.Services;

/// <summary>
/// HTTP body of one chunk as a standalone WAV: a generated header followed by a view of the source PCM.
/// Streams straight from the shared source buffer, so no per-chunk copy is held while requests wait.
/// </summary>
public sealed class WavChunkContent : HttpContent
{
    private readonly byte[] header;
    private readonly ReadOnlyMemory<byte> pcm;

    public WavChunkContent(byte[] source, WavFormat format, WavChunk chunk)
    {
        header = WavSilenceChunker.CreateHeader(format, chunk.ByteLength);
        pcm = source.AsMemory(chunk.ByteOffset, chunk.ByteLength);
        Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
    }

    protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
        SerializeToStreamAsync(stream, context, CancellationToken.None);

    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken cancellationToken)
    {
        await stream.WriteAsync(header, cancellationToken);
        await stream.WriteAsync(pcm, cancellationToken);
    }

    protected override bool TryComputeLength(out long length)
    {
        length = header.Length + pcm.Length;
        return true;
    }
}
