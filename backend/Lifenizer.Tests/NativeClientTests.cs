using System.Net;
using System.Net.Http.Headers;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;

namespace Lifenizer.Tests;

public sealed class NativeClientTests
{
    [Test]
    public async Task ApkDownloadIsAnonymousFixedAndSupportsRanges()
    {
        var root = Path.Combine(Path.GetTempPath(), $"lifenizer-download-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(Path.Combine(root, "downloads"));
        try
        {
            await using var factory = new LifenizerApiFactory();
            using var client = factory.CreateClient();
            factory.Services.GetRequiredService<IWebHostEnvironment>().ContentRootPath = root;
            using var missing = await client.GetAsync("/downloads/lifenizer.apk");
            Assert.That(missing.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));

            byte[] apk = [0, 1, 2, 3, 4, 5];
            await File.WriteAllBytesAsync(Path.Combine(root, "downloads", "lifenizer.apk"), apk);
            using var download = await client.GetAsync("/downloads/lifenizer.apk");
            Assert.Multiple(() =>
            {
                Assert.That(download.StatusCode, Is.EqualTo(HttpStatusCode.OK));
                Assert.That(download.Headers.CacheControl?.NoStore, Is.True);
                Assert.That(download.Content.Headers.ContentType?.MediaType, Is.EqualTo("application/vnd.android.package-archive"));
                Assert.That(download.Content.Headers.ContentDisposition?.DispositionType, Is.EqualTo("attachment"));
                Assert.That(download.Content.Headers.ContentDisposition?.FileName?.Trim('"'), Is.EqualTo("lifenizer.apk"));
            });
            Assert.That(await download.Content.ReadAsByteArrayAsync(), Is.EqualTo(apk));

            using var request = new HttpRequestMessage(HttpMethod.Get, "/downloads/lifenizer.apk");
            request.Headers.Range = new RangeHeaderValue(1, 3);
            using var range = await client.SendAsync(request);
            Assert.That(range.StatusCode, Is.EqualTo(HttpStatusCode.PartialContent));
            Assert.That(range.Content.Headers.ContentRange?.ToString(), Is.EqualTo("bytes 1-3/6"));
            Assert.That(await range.Content.ReadAsByteArrayAsync(), Is.EqualTo(new byte[] { 1, 2, 3 }));

            await File.WriteAllTextAsync(Path.Combine(root, "downloads", "private.txt"), "private");
            using var other = await client.GetAsync("/downloads/private.txt");
            Assert.That(other.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
