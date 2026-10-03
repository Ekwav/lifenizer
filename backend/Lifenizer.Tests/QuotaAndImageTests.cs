using System.Security.Cryptography;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Lifenizer.Core;
using Lifenizer.Api.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Lifenizer.Tests;

/// <summary>
/// Integration tests for storage quota and image upload endpoints.
/// </summary>
public sealed class QuotaAndImageTests
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    // -----------------------------------------------------------------------
    // Quota tests
    // -----------------------------------------------------------------------

    [Test]
    public async Task PremiumStatusReturnsFreePlanByDefault()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();

        var auth = await LoginAsync(client, "quota-user@example.test");
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        var response = await client.GetAsync("/api/premium/status");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));

        var body = await response.Content.ReadFromJsonAsync<JsonElement>(JsonOptions);
        Assert.Multiple(() =>
        {
            Assert.That(body.GetProperty("plan").GetString(), Does.Contain("Free").Or.Contain("Personal"));
            Assert.That(body.GetProperty("limitBytes").GetInt64(), Is.EqualTo(StorageQuota.FreeLimitBytes));
            Assert.That(body.GetProperty("usedBytes").GetInt64(), Is.EqualTo(0));
        });
    }

    [Test]
    public async Task QuotaStatusRequiresAuthentication()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/api/premium/status");
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    // -----------------------------------------------------------------------
    // Image upload / download / delete
    // -----------------------------------------------------------------------

    [Test]
    public async Task UploadAndDownloadImage()
    {
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Artifacts:StorePath"] = Path.Combine(Path.GetTempPath(), "lifenizer-test-blobs", Guid.NewGuid().ToString("N"))
        });
        using var client = factory.CreateClient();

        var auth = await LoginAsync(client, "img-user@example.test");
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        // Upload a minimal JPEG (1×1 pixel).
        var jpegBytes = MinimalJpeg();
        using var content = new MultipartFormDataContent();
        content.Add(new ByteArrayContent(jpegBytes)
        {
            Headers = { ContentType = new MediaTypeHeaderValue("image/jpeg") }
        }, "file", "test.jpg");

        var upload = await client.PostAsync("/api/images", content);
        Assert.That(upload.StatusCode, Is.EqualTo(HttpStatusCode.Created));

        var uploadBody = await upload.Content.ReadFromJsonAsync<JsonElement>(JsonOptions);
        var id = uploadBody.GetProperty("id").GetString()!;

        // Download.
        var download = await client.GetAsync($"/api/images/{id}");
        Assert.That(download.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(download.Content.Headers.ContentType!.MediaType, Is.EqualTo("image/jpeg"));

        var downloadedBytes = await download.Content.ReadAsByteArrayAsync();
        Assert.That(downloadedBytes, Is.EqualTo(jpegBytes));
    }

    [Test]
    public async Task DeleteImageRemovesBlob()
    {
        var blobRoot = Path.Combine(
            Path.GetTempPath(), "lifenizer-test-blobs", Guid.NewGuid().ToString("N"));

        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Artifacts:StorePath"] = blobRoot
        });
        using var client = factory.CreateClient();

        var auth = await LoginAsync(client, "del-user@example.test");
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        var jpegBytes = MinimalJpeg();
        using var content = new MultipartFormDataContent();
        content.Add(new ByteArrayContent(jpegBytes)
        {
            Headers = { ContentType = new MediaTypeHeaderValue("image/jpeg") }
        }, "file", "delete-me.jpg");

        var upload = await client.PostAsync("/api/images", content);
        upload.EnsureSuccessStatusCode();
        var uploadBody = await upload.Content.ReadFromJsonAsync<JsonElement>(JsonOptions);
        var id = uploadBody.GetProperty("id").GetString()!;

        // Check quota increased.
        var status = await client.GetFromJsonAsync<JsonElement>("/api/premium/status", JsonOptions);
        Assert.That(status.GetProperty("usedBytes").GetInt64(), Is.GreaterThan(0));

        // Delete.
        var delete = await client.DeleteAsync($"/api/images/{id}");
        Assert.That(delete.StatusCode, Is.EqualTo(HttpStatusCode.NoContent));

        // Download should now 404.
        var download = await client.GetAsync($"/api/images/{id}");
        Assert.That(download.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));

        // Quota should have been decremented.
        var status2 = await client.GetFromJsonAsync<JsonElement>("/api/premium/status", JsonOptions);
        Assert.That(status2.GetProperty("usedBytes").GetInt64(), Is.EqualTo(0));
    }

    [Test]
    public async Task EncryptedImageStoresOpaqueEnvelopeAndFileName()
    {
        var blobRoot = Path.Combine(Path.GetTempPath(), "lifenizer-test-blobs", Guid.NewGuid().ToString("N"));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Artifacts:StorePath"] = blobRoot });
        using var client = factory.CreateClient();
        var auth = await LoginAsync(client, "encrypted-img@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);
        var plain = JsonSerializer.SerializeToUtf8Bytes(new { bytes = Convert.ToBase64String(MinimalJpeg()), fileName = "private-family-photo.jpg", contentType = "image/jpeg" });
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new byte[plain.Length];
        var mac = new byte[16];
        using (var aes = new AesGcm(RandomNumberGenerator.GetBytes(32), 16)) aes.Encrypt(nonce, plain, cipher, mac);
        var packed = JsonSerializer.SerializeToUtf8Bytes(new { c = Convert.ToBase64String(cipher), m = Convert.ToBase64String(mac) });
        var envelope = JsonSerializer.SerializeToUtf8Bytes(new { cipherText = Convert.ToBase64String(packed), nonce = Convert.ToBase64String(nonce), keyId = "pbkdf2-sha256-aesgcm-v1" });
        using var content = new MultipartFormDataContent();
        content.Add(new ByteArrayContent(envelope) { Headers = { ContentType = new MediaTypeHeaderValue("application/octet-stream") } }, "file", "accidental-sensitive-name.jpg");
        var upload = await client.PostAsync("/api/images", content);
        upload.EnsureSuccessStatusCode();
        var record = await upload.Content.ReadFromJsonAsync<JsonElement>(JsonOptions);
        var id = record.GetProperty("id").GetString();
        Assert.That(record.GetProperty("fileName").GetString(), Is.EqualTo($"{id}.bin"));
        var download = await client.GetAsync($"/api/images/{id}");
        Assert.That(download.Content.Headers.ContentType!.MediaType, Is.EqualTo("application/octet-stream"));
        Assert.That(download.Content.Headers.ContentDisposition!.DispositionType, Is.EqualTo("attachment"));
        Assert.That(await download.Content.ReadAsByteArrayAsync(), Is.EqualTo(envelope));
        var stored = await File.ReadAllTextAsync(Directory.GetFiles(blobRoot, "*.bin", SearchOption.AllDirectories).Single());
        Assert.That(stored, Does.Not.Contain("private-family-photo").And.Not.Contain("image/jpeg"));
        (await client.DeleteAsync($"/api/images/{id}")).EnsureSuccessStatusCode();
        Assert.That((await client.GetFromJsonAsync<JsonElement>("/api/premium/status", JsonOptions)).GetProperty("usedBytes").GetInt64(), Is.Zero);
    }

    [TestCase("arbitrary blob")]
    [TestCase("{\"cipherText\":\"YQ==\",\"nonce\":\"YQ==\",\"keyId\":\"v1\"}")]
    [TestCase("{\"cipherText\":42,\"nonce\":null,\"keyId\":\"v1\"}")]
    public async Task InvalidEncryptedImageEnvelopeIsRejected(string payload)
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await LoginAsync(client, "invalid-img@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);
        using var content = new MultipartFormDataContent();
        content.Add(new ByteArrayContent(Encoding.UTF8.GetBytes(payload)) { Headers = { ContentType = new MediaTypeHeaderValue("application/octet-stream") } }, "file", "opaque.bin");
        Assert.That((await client.PostAsync("/api/images", content)).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    [Test]
    public async Task ConcurrentUploadsAndDeletesKeepStorageCountCorrect()
    {
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Artifacts:StorePath"] = Path.Combine(Path.GetTempPath(), "lifenizer-test-blobs", Guid.NewGuid().ToString("N"))
        });
        using var client = factory.CreateClient();
        var auth = await LoginAsync(client, "concurrent-img@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);
        (await client.GetAsync("/api/premium/status")).EnsureSuccessStatusCode();
        var ids = await Task.WhenAll(Enumerable.Range(0, 8).Select(async index =>
        {
            using var content = ImageForm();
            using var upload = await client.PostAsync("/api/images", content);
            upload.EnsureSuccessStatusCode();
            return (await upload.Content.ReadFromJsonAsync<JsonElement>(JsonOptions)).GetProperty("id").GetString();
        }));
        var status = await client.GetFromJsonAsync<JsonElement>("/api/premium/status", JsonOptions);
        Assert.That(status.GetProperty("usedBytes").GetInt64(), Is.EqualTo(8 * MinimalJpeg().Length));
        var deletes = await Task.WhenAll(ids.Select(id => client.DeleteAsync($"/api/images/{id}")));
        Assert.That(deletes.Select(response => response.StatusCode), Is.All.EqualTo(HttpStatusCode.NoContent));
        Assert.That((await client.GetFromJsonAsync<JsonElement>("/api/premium/status", JsonOptions)).GetProperty("usedBytes").GetInt64(), Is.Zero);
    }

    [Test]
    public async Task ConcurrentUploadsCannotExceedQuota()
    {
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Artifacts:StorePath"] = Path.Combine(Path.GetTempPath(), "lifenizer-test-blobs", Guid.NewGuid().ToString("N"))
        });
        using var client = factory.CreateClient();
        var auth = await LoginAsync(client, "full-img@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);
        (await client.GetAsync("/api/premium/status")).EnsureSuccessStatusCode();
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
            var account = await db.Users.SingleAsync();
            account.StorageUsedBytes = StorageQuota.FreeLimitBytes - MinimalJpeg().Length;
            await db.SaveChangesAsync();
        }
        using var first = ImageForm();
        using var second = ImageForm();
        var uploads = await Task.WhenAll(client.PostAsync("/api/images", first), client.PostAsync("/api/images", second));
        Assert.That(uploads.Select(response => response.StatusCode), Is.EquivalentTo(new[] { HttpStatusCode.Created, HttpStatusCode.PaymentRequired }));
        Assert.That((await client.GetFromJsonAsync<JsonElement>("/api/premium/status", JsonOptions)).GetProperty("usedBytes").GetInt64(), Is.EqualTo(StorageQuota.FreeLimitBytes));
        using var verify = factory.Services.CreateScope();
        Assert.That(await verify.ServiceProvider.GetRequiredService<LifenizerDbContext>().Images.CountAsync(), Is.EqualTo(1));
    }

    private static MultipartFormDataContent ImageForm()
    {
        var content = new MultipartFormDataContent();
        content.Add(new ByteArrayContent(MinimalJpeg()) { Headers = { ContentType = new MediaTypeHeaderValue("image/jpeg") } }, "file", "image.jpg");
        return content;
    }

    [Test]
    public async Task UploadUnsupportedContentTypeIsRejected()
    {
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Artifacts:StorePath"] = Path.Combine(Path.GetTempPath(), "lifenizer-test-blobs", Guid.NewGuid().ToString("N"))
        });
        using var client = factory.CreateClient();

        var auth = await LoginAsync(client, "ct-user@example.test");
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        using var content = new MultipartFormDataContent();
        content.Add(new ByteArrayContent(Encoding.UTF8.GetBytes("not an image"))
        {
            Headers = { ContentType = new MediaTypeHeaderValue("text/plain") }
        }, "file", "evil.txt");

        var response = await client.PostAsync("/api/images", content);
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private static async Task<AuthResponse> LoginAsync(HttpClient client, string email)
    {
        var response = await client.PostAsJsonAsync(
            "/api/auth/dev-login",
            new DevLoginRequest(email, email.Split('@')[0]),
            JsonOptions);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<AuthResponse>(JsonOptions)
               ?? throw new InvalidOperationException("Auth response was empty.");
    }

    /// <summary>Returns the bytes of a minimal valid JFIF JPEG (SOI + APP0 + EOI).</summary>
    private static byte[] MinimalJpeg() =>
    [
        // SOI
        0xFF, 0xD8,
        // APP0 JFIF marker
        0xFF, 0xE0, 0x00, 0x10,
        0x4A, 0x46, 0x49, 0x46, 0x00, // "JFIF\0"
        0x01, 0x01,                     // version 1.1
        0x00,                           // aspect ratio units = 0
        0x00, 0x01, 0x00, 0x01,         // 1x1 density
        0x00, 0x00,                     // no thumbnail
        // EOI
        0xFF, 0xD9,
    ];
}
