using System.Buffers.Binary;

namespace Lifenizer.Api.Services;

/// <summary>One Ogg page located inside a byte array (checksums are not verified).</summary>
public sealed class OggPage
{
    private const int FixedHeaderLength = 27;
    private const byte FirstPageFlag = 0x02;

    private static readonly uint[] CrcTable = BuildCrcTable();

    private OggPage(int headerOffset, byte flags, long granule, uint serial, int segmentTableOffset, int segmentCount, int bodyOffset, int bodyLength)
    {
        HeaderOffset = headerOffset;
        Flags = flags;
        Granule = granule;
        Serial = serial;
        SegmentTableOffset = segmentTableOffset;
        SegmentCount = segmentCount;
        BodyOffset = bodyOffset;
        BodyLength = bodyLength;
    }

    public int HeaderOffset { get; }
    public byte Flags { get; }
    /// <summary>-1 (no packet ends on this page) is reported as 0.</summary>
    public long Granule { get; }
    public uint Serial { get; }
    public int SegmentTableOffset { get; }
    public int SegmentCount { get; }
    public int BodyOffset { get; }
    public int BodyLength { get; }
    public int End => BodyOffset + BodyLength;
    public bool IsFirstPage => (Flags & FirstPageFlag) != 0;

    public static OggPage? TryRead(byte[] data, int position)
    {
        if (position < 0 || position + FixedHeaderLength > data.Length) return null;
        var header = data.AsSpan(position);
        if (!header[..4].SequenceEqual("OggS"u8) || header[4] != 0) return null;

        var segmentCount = header[26];
        var bodyOffset = position + FixedHeaderLength + segmentCount;
        if (bodyOffset > data.Length) return null;

        var bodyLength = 0;
        for (var i = 0; i < segmentCount; i++) bodyLength += data[position + FixedHeaderLength + i];
        if (bodyOffset + bodyLength > data.Length) return null;

        var granule = BinaryPrimitives.ReadInt64LittleEndian(header[6..]);
        return new OggPage(position, header[5], Math.Max(0, granule), BinaryPrimitives.ReadUInt32LittleEndian(header[14..]),
            position + FixedHeaderLength, segmentCount, bodyOffset, bodyLength);
    }

    /// <summary>Verifies the page checksum (CRC-32, polynomial 0x04C11DB7, with the CRC field read as zero).</summary>
    public bool HasValidCrc(byte[] data)
    {
        var stored = BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(HeaderOffset + 22));
        var crc = Crc(0, data.AsSpan(HeaderOffset, 22));
        crc = Crc(crc, stackalloc byte[4]);
        return Crc(crc, data.AsSpan(HeaderOffset + 26, End - HeaderOffset - 26)) == stored;
    }

    private static uint Crc(uint crc, ReadOnlySpan<byte> bytes)
    {
        foreach (var b in bytes) crc = (crc << 8) ^ CrcTable[(byte)(crc >> 24) ^ b];
        return crc;
    }

    private static uint[] BuildCrcTable()
    {
        var table = new uint[256];
        for (uint i = 0; i < 256; i++)
        {
            var r = i << 24;
            for (var bit = 0; bit < 8; bit++) r = (r & 0x80000000) != 0 ? (r << 1) ^ 0x04C11DB7 : r << 1;
            table[i] = r;
        }
        return table;
    }

    /// <summary>Number of packets that end on this page.</summary>
    public int CompletedPackets(byte[] data)
    {
        var count = 0;
        for (var i = 0; i < SegmentCount; i++)
        {
            if (data[SegmentTableOffset + i] < 255) count++;
        }
        return count;
    }

    /// <summary>
    /// Reassembles the packets of all consecutive pages from the start of <paramref name="data"/>.
    /// Each packet is only valid until the next iteration (one reused buffer).
    /// </summary>
    /// <exception cref="InvalidOpusStreamException">A packet is larger than <see cref="OpusStreamScanner.MaxPacketBytes"/>.</exception>
    public static IEnumerable<ReadOnlyMemory<byte>> Packets(byte[] data)
    {
        var buffer = new byte[4096];
        var length = 0;
        for (var page = TryRead(data, 0); page is not null; page = TryRead(data, page.End))
        {
            var offset = page.BodyOffset;
            for (var i = 0; i < page.SegmentCount; i++)
            {
                var size = data[page.SegmentTableOffset + i];
                Append(ref buffer, ref length, data.AsSpan(offset, size));
                offset += size;
                if (size == 255) continue;
                yield return buffer.AsMemory(0, length);
                length = 0;
            }
        }
    }

    private static void Append(ref byte[] buffer, ref int length, ReadOnlySpan<byte> bytes)
    {
        if (length + bytes.Length > OpusStreamScanner.MaxPacketBytes)
        {
            throw new InvalidOpusStreamException("Ogg Opus packet is larger than any valid Opus packet.");
        }
        if (length + bytes.Length > buffer.Length) Array.Resize(ref buffer, Math.Min(buffer.Length * 2, OpusStreamScanner.MaxPacketBytes));
        bytes.CopyTo(buffer.AsSpan(length));
        length += bytes.Length;
    }
}
