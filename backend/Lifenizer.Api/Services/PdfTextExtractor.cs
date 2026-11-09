using System.Diagnostics;
using System.Buffers.Binary;
using System.Text.RegularExpressions;

namespace Lifenizer.Api.Services;

/// <summary>Extracts local document text; temporary files are private and removed on every exit.</summary>
public static partial class PdfTextExtractor
{
    public const int MaxBytes = 25 * 1024 * 1024;
    private const int MaxTextBytes = 4 * 1024 * 1024;
    private static readonly SemaphoreSlim Slots = new(2);

    /// <param name="allowEmpty">Return an empty string instead of throwing when no text was found (photos without text).</param>
    /// <param name="validateSize">Skip the built-in PNG/JPEG dimension check when the caller validated the image itself (WebP).</param>
    public static string Extract(byte[] bytes, bool image = false, bool allowEmpty = false, bool validateSize = true, TimeSpan? timeout = null)
    {
        if (bytes.Length is 0 or > MaxBytes) throw new InvalidOperationException("Document must be between 1 byte and 25 MiB.");
        if (image && validateSize) ValidateImageSize(bytes);
        var budget = timeout is { } requested && requested < TimeSpan.FromMinutes(2) ? requested : TimeSpan.FromMinutes(2);
        if (budget <= TimeSpan.Zero) throw new InvalidOperationException("Document extraction time limit reached.");
        using var cancellation = new CancellationTokenSource(budget);
        try { return ExtractAsync(bytes, image, allowEmpty, cancellation.Token).GetAwaiter().GetResult(); }
        catch (OperationCanceledException) { throw new InvalidOperationException("Document extraction exceeded the two minute limit. Split the document and retry."); }
    }

    private static async Task<string> ExtractAsync(byte[] bytes, bool image, bool allowEmpty, CancellationToken cancellationToken)
    {
        await Slots.WaitAsync(cancellationToken);
        var directory = Path.Combine(Path.GetTempPath(), "lifenizer-document-" + Guid.NewGuid().ToString("N"));
        try
        {
            if (OperatingSystem.IsWindows()) Directory.CreateDirectory(directory);
            else Directory.CreateDirectory(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var input = Path.Combine(directory, image ? "input.image" : "input.pdf");
            await File.WriteAllBytesAsync(input, bytes, cancellationToken);
            var texts = new List<string>();
            if (image) texts.Add(await OcrAsync(input, directory, cancellationToken));
            else
            {
                if (bytes.AsSpan(0, Math.Min(bytes.Length, 1024)).IndexOf("%PDF-"u8) < 0)
                    throw new InvalidOperationException("Document is not a PDF.");
                var info = await RunAsync("pdfinfo", [input], cancellationToken);
                var match = PageCount().Match(info);
                if (!match.Success || !int.TryParse(match.Groups[1].Value, out var pages) || pages is < 1 or > 100)
                    throw new InvalidOperationException("PDF must contain between 1 and 100 pages; split larger documents before importing.");
                var extracted = (await RunAsync("pdftotext", ["-layout", "-enc", "UTF-8", input, "-"], cancellationToken)).Split('\f');
                for (var page = 1; page <= pages; page++)
                {
                    var text = page <= extracted.Length ? extracted[page - 1].Trim() : "";
                    if (string.IsNullOrWhiteSpace(text))
                    {
                        var prefix = Path.Combine(directory, "page");
                        await RunAsync("pdftoppm", ["-f", page.ToString(), "-l", page.ToString(), "-singlefile", "-scale-to", "2000", "-png", input, prefix], cancellationToken);
                        text = await OcrAsync(prefix + ".png", directory, cancellationToken);
                    }
                    texts.Add(text);
                    if (texts.Sum(value => value.Length) > MaxTextBytes) throw new InvalidOperationException("Extracted document text exceeds 4 MiB.");
                }
            }
            var result = string.Join("\n\n", texts).Trim();
            if (result.Length == 0 && !allowEmpty) throw new InvalidOperationException("No readable text was found in the document, including OCR.");
            return result;
        }
        finally
        {
            try { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
            finally { Slots.Release(); }
        }
    }

    private static async Task<string> OcrAsync(string input, string directory, CancellationToken cancellationToken)
    {
        var output = Path.Combine(directory, "ocr");
        var available = (await RunAsync("tesseract", ["--list-langs"], cancellationToken)).Split('\n').Select(line => line.Trim()).ToHashSet();
        var language = string.Join("+", new[] { "deu", "eng" }.Where(available.Contains));
        if (language.Length == 0) throw new InvalidOperationException("Install German or English Tesseract OCR language data on the API server.");
        await RunAsync("tesseract", [input, output, "-l", language], cancellationToken);
        return (await ReadTextAsync(output + ".txt", cancellationToken)).Trim();
    }

    private static void ValidateImageSize(byte[] bytes)
    {
        int width = 0, height = 0;
        if (bytes.Length >= 24 && bytes.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }))
        {
            width = BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(16, 4));
            height = BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(20, 4));
        }
        else if (bytes.Length >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8)
        {
            var position = 2;
            while (position + 4 <= bytes.Length && bytes[position++] == 0xff)
            {
                while (position < bytes.Length && bytes[position] == 0xff) position++;
                if (position >= bytes.Length) break;
                var marker = bytes[position++];
                if (marker is 0xda or 0xd9) break;
                if (marker is 0xd8 or 0x01 or >= 0xd0 and <= 0xd7) continue;
                if (position + 2 > bytes.Length) break;
                var length = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(position, 2));
                if (length < 2 || position + length > bytes.Length) break;
                if (marker is >= 0xc0 and <= 0xcf && marker is not (0xc4 or 0xc8 or 0xcc) && length >= 7)
                {
                    height = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(position + 3, 2));
                    width = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(position + 5, 2));
                    break;
                }
                position += length;
            }
        }
        if (width <= 0 || height <= 0 || width > 10000 || height > 10000 || (long)width * height > 25_000_000)
            throw new InvalidOperationException("Scan must be a valid PNG/JPEG image of at most 25 megapixels and 10,000 pixels per side. Resize it and retry.");
    }

    private static async Task<string> ReadTextAsync(string path, CancellationToken cancellationToken)
    {
        if (new FileInfo(path).Length > MaxTextBytes) throw new InvalidOperationException("Extracted document text exceeds 4 MiB.");
        return await File.ReadAllTextAsync(path, cancellationToken);
    }

    private static async Task<string> RunAsync(string executable, string[] arguments, CancellationToken cancellationToken)
    {
        using var process = new Process { StartInfo = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true } };
        foreach (var argument in arguments) process.StartInfo.ArgumentList.Add(argument);
        process.StartInfo.Environment["OMP_THREAD_LIMIT"] = "1";
        try { process.Start(); }
        catch (System.ComponentModel.Win32Exception) { throw new InvalidOperationException("PDF/OCR tools are unavailable. Install poppler-utils, tesseract and German OCR language data on the API server."); }
        using var bounded = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var stdout = ReadOutputAsync(process.StandardOutput);
        var stderr = ReadOutputAsync(process.StandardError);
        try
        {
            await Task.WhenAll(stdout, stderr, process.WaitForExitAsync(bounded.Token));
            if (process.ExitCode != 0) throw new InvalidOperationException($"Document extraction failed in {executable}; the document may be invalid, encrypted or unreadable.");
            return await stdout;
        }
        finally { if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); } }

        async Task<string> ReadOutputAsync(StreamReader reader)
        {
            var output = new System.Text.StringBuilder();
            var buffer = new char[8192];
            try
            {
                int count;
                while ((count = await reader.ReadAsync(buffer.AsMemory(), bounded.Token)) > 0)
                {
                    if (output.Length + count > MaxTextBytes) throw new InvalidOperationException("Document tool output exceeds 4 MiB.");
                    output.Append(buffer, 0, count);
                }
                return output.ToString();
            }
            catch { bounded.Cancel(); throw; }
        }
    }

    [GeneratedRegex(@"^Pages:\s+(\d+)", RegexOptions.Multiline)]
    private static partial Regex PageCount();
}
