using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;

namespace Lifenizer.Tests;

public sealed class NativeClientTests
{
    [Test]
    public async Task LandingServesOnlyPublicAssets()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        foreach (var path in new[] { "/", "/index.html", "/security.html", "/privacy.html", "/imports.html", "/hosted.html", "/styles.css", "/landing.js" })
        {
            using var response = await client.GetAsync(path);
            Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK), path);
            Assert.That(response.Headers.GetValues("X-Content-Type-Options"), Contains.Item("nosniff"));
            var content = await response.Content.ReadAsStringAsync();
            Assert.That(content, Does.Not.Contain("unsplash.com"));
            if (path == "/")
            {
                Assert.That(content, Does.Contain("data-lifenizer-connect"));
                Assert.That(content, Does.Contain("lifenizer://connect-extension"));
                Assert.That(content, Does.Not.Contain("build/web"));
                Assert.That(response.Content.Headers.ContentType?.MediaType, Is.EqualTo("text/html"));
            }
        }
        foreach (var path in new[] { "/appsettings.json", "/Program.cs", "/landing/../appsettings.json", "/downloads/../appsettings.json", "/downloads/private.txt" })
        {
            using var response = await client.GetAsync(path);
            Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.NotFound), path);
        }
    }

    [Test]
    public async Task ManifestAndDownloadsUseConfiguredCurrentReleaseWithoutLeakingOtherFiles()
    {
        var root = Path.Combine(Path.GetTempPath(), $"lifenizer-release-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(Path.Combine(root, "current"));
        try
        {
            await using var factory = new LifenizerApiFactory();
            using var client = factory.CreateClient();
            factory.Services.GetRequiredService<IConfiguration>()["Downloads:Path"] = root;
            await File.WriteAllTextAsync(Path.Combine(root, "lifenizer.apk"), "old");
            await File.WriteAllTextAsync(Path.Combine(root, "current", "lifenizer-linux-x64.tar.gz"), "linux");
            await File.WriteAllTextAsync(Path.Combine(root, "current", "lifenizer-history-sync-chromium.zip"), "chromium");
            await File.WriteAllTextAsync(Path.Combine(root, "current", "lifenizer-history-sync-firefox.zip"), "firefox");
            await File.WriteAllTextAsync(Path.Combine(root, "current", "private.txt"), "private");
            using var response = await client.GetAsync("/api/downloads");
            Assert.That(response.Headers.CacheControl?.NoStore, Is.True);
            using var manifest = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            var files = manifest.RootElement.EnumerateArray().ToArray();
            Assert.That(files, Has.Length.EqualTo(4));
            Assert.That(files.Single(f => f.GetProperty("name").GetString() == "lifenizer.apk").GetProperty("available").GetBoolean(), Is.False);
            Assert.That(files.Count(f => f.GetProperty("available").GetBoolean()), Is.EqualTo(3));
            foreach (var file in files.Where(f => f.GetProperty("available").GetBoolean()))
            {
                using var download = await client.GetAsync(file.GetProperty("url").GetString());
                Assert.That(download.StatusCode, Is.EqualTo(HttpStatusCode.OK));
                Assert.That(download.Content.Headers.ContentType?.MediaType, Is.EqualTo(file.GetProperty("name").GetString()!.EndsWith(".zip") ? "application/zip" : "application/gzip"));
            }
            using var missing = await client.GetAsync("/downloads/lifenizer.apk");
            Assert.That(missing.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
            using var privateFile = await client.GetAsync("/downloads/private.txt");
            Assert.That(privateFile.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

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
