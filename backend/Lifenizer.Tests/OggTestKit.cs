using System.Buffers.Binary;
using Lifenizer.Api.Services;

namespace Lifenizer.Tests;

/// <summary>Builds and patches Ogg Opus bytes (with valid page checksums) for decoder tests.</summary>
internal static class OggTestKit
{
    private static readonly uint[] CrcTable = BuildCrcTable();

    /// <summary>A 16 kHz mono stream of tiny code-3 packets (two zero-length 60 ms frames each): ~1900x expansion.</summary>
    public static byte[] DtxBomb(int packets, long granule, int preSkip = 0)
    {
        using var stream = new MemoryStream();
        WritePage(stream, 0x02, 0, 0, [Head(preSkip)]);
        WritePage(stream, 0, 0, 1, [Tags()]);
        var sequence = 2u;
        for (var done = 0; done < packets; done += 200)
        {
            var count = Math.Min(200, packets - done);
            var last = done + count == packets;
            WritePage(stream, last ? (byte)0x04 : (byte)0, last ? granule : 0, sequence++, Enumerable.Repeat(new byte[] { 0x1B, 0x02 }, count).ToArray());
        }
        return stream.ToArray();
    }

    /// <summary>Thousands of empty packets (one lacing byte each); a naive decoder would conceal 120 ms for every one.</summary>
    public static byte[] ZeroLengthBomb(int packets, long granule)
    {
        using var stream = new MemoryStream();
        WritePage(stream, 0x02, 0, 0, [Head(0)]);
        WritePage(stream, 0, 0, 1, [Tags()]);
        var sequence = 2u;
        for (var done = 0; done < packets; done += 255)
        {
            var count = Math.Min(255, packets - done);
            var last = done + count == packets;
            WritePage(stream, last ? (byte)0x04 : (byte)0, last ? granule : 0, sequence++, Enumerable.Repeat(Array.Empty<byte>(), count).ToArray());
        }
        return stream.ToArray();
    }

    /// <summary>One audio packet of the given size, spread over continuation pages.</summary>
    public static byte[] HugePacket(int size)
    {
        using var stream = new MemoryStream();
        WritePage(stream, 0x02, 0, 0, [Head(0)]);
        WritePage(stream, 0, 0, 1, [Tags()]);
        var body = new byte[size];
        body[0] = 0x1B;
        var segments = new List<byte>();
        for (var left = size; ; left -= 255)
        {
            segments.Add((byte)Math.Min(left, 255));
            if (left < 255) break;
        }
        var sequence = 2u;
        for (var offset = 0; offset < segments.Count; offset += 255)
        {
            var table = segments.Skip(offset).Take(255).ToArray();
            var bytes = body.Skip(segments.Take(offset).Sum(x => x)).Take(table.Sum(x => x)).ToArray();
            WriteRawPage(stream, offset == 0 ? (byte)0 : (byte)0x01, 0, sequence++, table, bytes);
        }
        return stream.ToArray();
    }

    public static byte[] PatchPreSkip(byte[] ogg, ushort preSkip)
    {
        var copy = (byte[])ogg.Clone();
        var head = copy.AsSpan().IndexOf("OpusHead"u8);
        BinaryPrimitives.WriteUInt16LittleEndian(copy.AsSpan(head + 10), preSkip);
        return FixCrc(copy);
    }

    /// <summary>Overwrites the start of the Nth page body with a packet header the decoder rejects.</summary>
    public static byte[] CorruptPacket(byte[] ogg, int pageIndex)
    {
        var copy = (byte[])ogg.Clone();
        var page = Pages(copy).ElementAt(pageIndex);
        copy[page.BodyOffset] = 0x02;
        copy[page.BodyOffset + 1] = 0xFF;
        return FixCrc(copy);
    }

    /// <summary>Gives one page a different stream serial (valid checksum), as in an interleaved or chained file.</summary>
    public static byte[] PatchSerial(byte[] ogg, int pageIndex, uint serial)
    {
        var copy = (byte[])ogg.Clone();
        var page = Pages(copy).ElementAt(pageIndex);
        BinaryPrimitives.WriteUInt32LittleEndian(copy.AsSpan(page.SegmentTableOffset - 27 + 14), serial);
        return FixCrc(copy);
    }

    /// <summary>Changes a body byte without fixing the checksum.</summary>
    public static byte[] BreakCrc(byte[] ogg, int pageIndex)
    {
        var copy = (byte[])ogg.Clone();
        copy[Pages(copy).ElementAt(pageIndex).BodyOffset + 3] ^= 0xFF;
        return copy;
    }

    public static byte[] FixCrc(byte[] ogg)
    {
        foreach (var page in Pages(ogg).ToList())
        {
            var start = page.SegmentTableOffset - 27;
            BinaryPrimitives.WriteUInt32LittleEndian(ogg.AsSpan(start + 22), 0);
            BinaryPrimitives.WriteUInt32LittleEndian(ogg.AsSpan(start + 22), Crc(ogg.AsSpan(start, page.End - start)));
        }
        return ogg;
    }

    private static IEnumerable<OggPage> Pages(byte[] ogg)
    {
        for (var page = OggPage.TryRead(ogg, 0); page is not null; page = OggPage.TryRead(ogg, page.End)) yield return page;
    }

    private static byte[] Head(int preSkip)
    {
        var head = new byte[19];
        "OpusHead"u8.CopyTo(head);
        head[8] = 1;
        head[9] = 1;
        BinaryPrimitives.WriteUInt16LittleEndian(head.AsSpan(10), (ushort)preSkip);
        BinaryPrimitives.WriteUInt32LittleEndian(head.AsSpan(12), 16000);
        return head;
    }

    private static byte[] Tags()
    {
        var tags = new byte[16];
        "OpusTags"u8.CopyTo(tags);
        return tags;
    }

    private static void WritePage(Stream stream, byte flags, long granule, uint sequence, byte[][] packets) =>
        WriteRawPage(stream, flags, granule, sequence, packets.Select(p => (byte)p.Length).ToArray(), packets.SelectMany(p => p).ToArray());

    private static void WriteRawPage(Stream stream, byte flags, long granule, uint sequence, byte[] segmentTable, byte[] body)
    {
        var page = new List<byte>();
        page.AddRange("OggS"u8.ToArray());
        page.AddRange(new byte[] { 0, flags });
        page.AddRange(BitConverter.GetBytes(granule));
        page.AddRange(BitConverter.GetBytes(1u));
        page.AddRange(BitConverter.GetBytes(sequence));
        page.AddRange(new byte[4]);
        page.Add((byte)segmentTable.Length);
        page.AddRange(segmentTable);
        page.AddRange(body);
        var bytes = page.ToArray();
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(22), Crc(bytes));
        stream.Write(bytes);
    }

    private static uint Crc(ReadOnlySpan<byte> data)
    {
        uint crc = 0;
        foreach (var b in data) crc = (crc << 8) ^ CrcTable[(byte)(crc >> 24) ^ b];
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
}
