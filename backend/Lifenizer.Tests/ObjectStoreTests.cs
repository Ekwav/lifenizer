using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Amazon.Runtime;
using Amazon.S3;
using Amazon.S3.Model;
using Lifenizer.Api.Data;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.AspNetCore.Hosting;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;

namespace Lifenizer.Tests;

public sealed class ObjectStoreTests
{
    internal static Dictionary<string, string?> Config(string root) => new()
    {
        ["Artifacts:StorePath"] = root, ["ObjectStorage:ServiceUrl"] = "https://storage.example.test",
        ["ObjectStorage:Bucket"] = "private-test", ["ObjectStorage:AccessKeyId"] = "test-access",
        ["ObjectStorage:SecretAccessKey"] = "test-secret", ["ObjectStorage:Prefix"] = "lifenizer"
    };

    [Test]
    public async Task S3PreservesOpaqueBytesAndFallsBackOnlyForAbsentObjects()
    {
        var root = Path.Combine(Path.GetTempPath(), $"lifenizer-store-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var client = new FakeS3();
            using var store = new ObjectStore(new ConfigurationBuilder().AddInMemoryCollection(Config(root)).Build(), NullLogger<ObjectStore>.Instance, client);
            await File.WriteAllTextAsync(Path.Combine(root, "legacy.bin"), "legacy");
            await using (var stream = (await store.OpenReadAsync("legacy.bin", default))!)
                Assert.That(await new StreamReader(stream).ReadToEndAsync(), Is.EqualTo("legacy"));
            using var bytes = new MemoryStream(Encoding.UTF8.GetBytes("opaque ciphertext"));
            await store.PutAsync("legacy.bin", bytes, "application/json", default);
            Assert.That(client.Objects.Keys, Is.EquivalentTo(new[] { "lifenizer/legacy.bin" }));
            await using (var stream = (await store.OpenReadAsync("legacy.bin", default))!)
                Assert.That(await new StreamReader(stream).ReadToEndAsync(), Is.EqualTo("opaque ciphertext"));
            client.Failure = HttpStatusCode.ServiceUnavailable;
            Assert.ThrowsAsync<AmazonS3Exception>(async () => await store.OpenReadAsync("legacy.bin", default));
            client.Failure = HttpStatusCode.Forbidden;
            Assert.ThrowsAsync<AmazonS3Exception>(async () => await store.OpenReadAsync("legacy.bin", default));
            client.Failure = null;
            await store.DeleteAsync("legacy.bin", default);
            Assert.That(client.Objects, Is.Empty);
            Assert.That(File.Exists(Path.Combine(root, "legacy.bin")), Is.False);
        }
        finally { Directory.Delete(root, true); }
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task BulkDeletionBatchesExactKeysAndRemovesLegacyLocalCopies(bool remote)
    {
        var root = Path.Combine(Path.GetTempPath(), $"lifenizer-bulk-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var client = new FakeS3();
            var config = remote ? Config(root) : new Dictionary<string, string?> { ["Artifacts:StorePath"] = root };
            using var store = new ObjectStore(new ConfigurationBuilder().AddInMemoryCollection(config).Build(), NullLogger<ObjectStore>.Instance, remote ? client : null);
            var keys = Enumerable.Range(0, 1001).Select(index => $"{index}.bin").ToArray();
            foreach (var key in keys) client.Objects[$"lifenizer/{key}"] = [];
            client.Objects["lifenizer/keep.bin"] = [];
            await File.WriteAllTextAsync(Path.Combine(root, keys[0]), "legacy");
            await File.WriteAllTextAsync(Path.Combine(root, "keep.bin"), "keep");
            await store.DeleteManyAsync(keys.Concat([keys[0]]), default);
            Assert.That(File.Exists(Path.Combine(root, keys[0])), Is.False);
            Assert.That(File.Exists(Path.Combine(root, "keep.bin")), Is.True);
            if (remote)
            {
                Assert.That(client.BatchSizes, Is.EqualTo(new[] { 1000, 1 }));
                Assert.That(client.Objects.Keys, Is.EqualTo(new[] { "lifenizer/keep.bin" }));
            }
        }
        finally { Directory.Delete(root, true); }
    }

    [Test]
    public async Task RecordingS3UploadReplaceDownloadDeleteAndFailureRetainQuotaAndIsolation()
    {
        var root = Path.Combine(Path.GetTempPath(), $"lifenizer-store-{Guid.NewGuid():N}");
        var s3 = new FakeS3();
        await using var factory = new LifenizerApiFactory(Config(root)).WithWebHostBuilder(builder =>
            builder.ConfigureServices(services => services.AddSingleton<IAmazonS3>(s3)));
        using var owner = factory.CreateClient();
        using var other = factory.CreateClient();
        foreach (var (client, email) in new[] { (owner, "s3-owner@example.test"), (other, "s3-other@example.test") })
        {
            var response = await client.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest(email, email));
            var auth = await response.Content.ReadFromJsonAsync<AuthResponse>();
            client.DefaultRequestHeaders.Authorization = new("Bearer", auth!.AuthToken);
        }
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new { cipherText = "YWJj", nonce = Convert.ToBase64String(new byte[12]), keyId = "key" });
        (await owner.PutAsync("/api/recordings/chat", new ByteArrayContent(bytes))).EnsureSuccessStatusCode();
        (await owner.PutAsync("/api/recordings/chat", new ByteArrayContent(bytes))).EnsureSuccessStatusCode();
        Assert.That(s3.Objects.Count, Is.EqualTo(1));
        Assert.That(Directory.Exists(root), Is.False);
        Assert.That(await owner.GetByteArrayAsync("/api/recordings/chat"), Is.EqualTo(bytes));
        Assert.That((await other.GetAsync("/api/recordings/chat")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        s3.Failure = HttpStatusCode.ServiceUnavailable;
        Assert.That((await owner.PutAsync("/api/recordings/failed", new ByteArrayContent(bytes))).StatusCode, Is.EqualTo(HttpStatusCode.InternalServerError));
        Assert.That((await owner.DeleteAsync("/api/recordings/chat")).StatusCode, Is.EqualTo(HttpStatusCode.InternalServerError));
        s3.Failure = null;
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        Assert.That(await db.Recordings.CountAsync(), Is.EqualTo(1));
        Assert.That((await db.Users.SingleAsync(user => user.Email == "s3-owner@example.test")).StorageUsedBytes, Is.EqualTo(bytes.Length));
        (await owner.DeleteAsync("/api/recordings/chat")).EnsureSuccessStatusCode();
        Assert.That(s3.Objects, Is.Empty);
        db.ChangeTracker.Clear();
        Assert.That((await db.Users.SingleAsync(user => user.Email == "s3-owner@example.test")).StorageUsedBytes, Is.Zero);
    }

    [TestCase("../secret")]
    [TestCase("/absolute")]
    [TestCase("a\\b")]
    public void RejectsUnsafeObjectKeys(string key)
    {
        using var store = new ObjectStore(new ConfigurationBuilder().Build(), NullLogger<ObjectStore>.Instance);
        Assert.ThrowsAsync<ArgumentException>(async () => await store.OpenReadAsync(key, default));
    }

    internal sealed class FakeS3() : AmazonS3Client(new BasicAWSCredentials("test", "test"), new AmazonS3Config { ServiceURL = "https://storage.example.test" })
    {
        public Dictionary<string, byte[]> Objects { get; } = new();
        public HttpStatusCode? Failure { get; set; }
        public int Writes { get; private set; }
        public int Reads { get; private set; }
        public List<int> BatchSizes { get; } = [];
        private void Check() { if (Failure is { } status) throw new AmazonS3Exception("synthetic storage failure") { StatusCode = status }; }
        public override async Task<PutObjectResponse> PutObjectAsync(PutObjectRequest request, CancellationToken cancellationToken = default)
        {
            Check();
            Writes++;
            Assert.That(request.BucketName, Is.EqualTo("private-test"));
            Assert.That(request.DisablePayloadSigning, Is.True);
            Assert.That(request.DisableDefaultChecksumValidation, Is.True);
            Assert.That(request.UseChunkEncoding, Is.False);
            using var output = new MemoryStream();
            await request.InputStream.CopyToAsync(output, cancellationToken);
            Objects[request.Key] = output.ToArray();
            return new PutObjectResponse();
        }
        public override Task<GetObjectResponse> GetObjectAsync(string bucketName, string key, CancellationToken cancellationToken = default)
        {
            Check();
            Reads++;
            if (!Objects.TryGetValue(key, out var bytes)) throw new AmazonS3Exception("missing") { StatusCode = HttpStatusCode.NotFound, ErrorCode = "NoSuchKey" };
            return Task.FromResult(new GetObjectResponse { ResponseStream = new MemoryStream(bytes) });
        }
        public override Task<DeleteObjectsResponse> DeleteObjectsAsync(DeleteObjectsRequest request, CancellationToken cancellationToken = default)
        {
            Check();
            BatchSizes.Add(request.Objects.Count);
            foreach (var item in request.Objects) Objects.Remove(item.Key);
            return Task.FromResult(new DeleteObjectsResponse());
        }
        public override Task<DeleteObjectResponse> DeleteObjectAsync(string bucketName, string key, CancellationToken cancellationToken = default)
        {
            Check(); Objects.Remove(key); return Task.FromResult(new DeleteObjectResponse());
        }
    }
}
