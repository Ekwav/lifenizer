using System.IO.Compression;

namespace Lifenizer.Api.Services;

/// <summary>Reads bounded ZIP containers in memory; never extracts files or follows nested archives.</summary>
public static class BoundedImportArchive
{
    private static readonly uint[] CrcTable = Enumerable.Range(0, 256).Select(value =>
    {
        var crc = (uint)value;
        for (var bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0u : 0xedb88320u);
        return crc;
    }).ToArray();

    public const int MaxBytes = 25 * 1024 * 1024;
    public const int MaxEntries = 2000;
    public const long MaxExpandedBytes = 100L * 1024 * 1024;

    public static ZipArchive Open(byte[] bytes)
    {
        if (bytes.Length is 0 or > MaxBytes) throw new InvalidDataException("Archive must be between 1 byte and 25 MiB.");
        var archive = new ZipArchive(new MemoryStream(bytes, writable: false), ZipArchiveMode.Read);
        try
        {
            if (archive.Entries.Count > MaxEntries) throw new InvalidDataException("Archive exceeds 2000 entries.");
            var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            long total = 0;
            foreach (var entry in archive.Entries)
            {
                var path = entry.FullName.Replace('\\', '/');
                if (path.Length == 0 || path.StartsWith('/') || path.Contains(':') || path.TrimEnd('/').Split('/').Any(part => part is "" or ".." or ".") ||
                    !paths.Add(path.TrimEnd('/')) || ((entry.ExternalAttributes >> 16) & 0xf000) == 0xa000)
                    throw new InvalidDataException("Archive contains an unsafe, duplicate or symbolic-link path.");
                if (entry.Length > MaxBytes || entry.Length < 0 || (total += entry.Length) > MaxExpandedBytes)
                    throw new InvalidDataException("Archive exceeds expanded size limits (25 MiB per entry, 100 MiB total).");
                if (entry.Length > 1024 * 1024 && entry.Length > Math.Max(1L, entry.CompressedLength) * 200)
                    throw new InvalidDataException("Archive compression ratio exceeds 200.");
            }
            return archive;
        }
        catch { archive.Dispose(); throw; }
    }

    public static byte[] Read(ZipArchiveEntry entry, int maxBytes = MaxBytes)
    {
        if (entry.Length > maxBytes) throw new InvalidDataException("Archive entry exceeds the extraction size limit.");
        using var input = entry.Open();
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        var crc = uint.MaxValue;
        int count;
        while ((count = input.Read(buffer)) > 0)
        {
            if (output.Length + count > maxBytes || output.Length + count > entry.Length)
                throw new InvalidDataException("Archive entry expanded beyond its declared size or extraction limit.");
            for (var i = 0; i < count; i++) crc = CrcTable[(crc ^ buffer[i]) & 255] ^ (crc >> 8);
            output.Write(buffer, 0, count);
        }
        if (output.Length != entry.Length) throw new InvalidDataException("Archive entry does not match its declared size.");
        if (~crc != entry.Crc32) throw new InvalidDataException("Archive entry checksum does not match its declared content.");
        return output.ToArray();
    }
}
