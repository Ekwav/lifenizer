using System.Net;
using Amazon.Runtime;
using Amazon.S3;
using Amazon.S3.Model;

namespace Lifenizer.Api.Services;

/// <summary>Private objects; API endpoints retain authorization and encrypted-envelope validation.</summary>
public sealed class ObjectStore : IDisposable
{
    private readonly string root;
    private readonly string? bucket;
    private readonly string prefix;
    private readonly IAmazonS3? s3;
    private readonly ILogger<ObjectStore> logger;

    public ObjectStore(IConfiguration config, ILogger<ObjectStore> logger, IAmazonS3? client = null)
    {
        this.logger = logger;
        root = Path.GetFullPath(config["Artifacts:StorePath"] ?? "/tmp/lifenizer-artifacts");
        prefix = config["ObjectStorage:Prefix"]?.Trim('/') ?? "";
        var section = config.GetSection("ObjectStorage");
        if (!section.GetChildren().Any()) return;
        bucket = section["Bucket"];
        if (string.IsNullOrWhiteSpace(bucket) || string.IsNullOrWhiteSpace(section["AccessKeyId"]) || string.IsNullOrWhiteSpace(section["SecretAccessKey"]) ||
            !Uri.TryCreate(section["ServiceUrl"], UriKind.Absolute, out var url) || url.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("ObjectStorage requires an HTTPS ServiceUrl, Bucket, AccessKeyId and SecretAccessKey.");
        s3 = client ?? new AmazonS3Client(new BasicAWSCredentials(section["AccessKeyId"], section["SecretAccessKey"]), new AmazonS3Config
        {
            ServiceURL = url.AbsoluteUri, AuthenticationRegion = section["Region"] ?? "auto", ForcePathStyle = true
        });
    }

    private string LocalPath(string key)
    {
        if (string.IsNullOrWhiteSpace(key) || key.Contains('\\') || key.Split('/').Any(part => part is "" or "." or ".."))
            throw new ArgumentException("Invalid object key.", nameof(key));
        return Path.Combine(root, key.Replace('/', Path.DirectorySeparatorChar));
    }
    private string RemoteKey(string key) => prefix.Length == 0 ? key : $"{prefix}/{key}";

    public async Task PutAsync(string key, Stream content, string contentType, CancellationToken token)
    {
        var path = LocalPath(key);
        if (s3 is not null)
        {
            // R2 does not support the SDK's streaming SigV4/default upload checksum mode.
            await s3.PutObjectAsync(new PutObjectRequest
            {
                BucketName = bucket, Key = RemoteKey(key), InputStream = content, ContentType = contentType,
                AutoCloseStream = false, DisablePayloadSigning = true, DisableDefaultChecksumValidation = true, UseChunkEncoding = false
            }, token);
            return;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true);
        await content.CopyToAsync(output, token);
    }

    public async Task<Stream?> OpenReadAsync(string key, CancellationToken token)
    {
        var path = LocalPath(key);
        if (s3 is not null)
        {
            try { return (await s3.GetObjectAsync(bucket, RemoteKey(key), token)).ResponseStream; }
            catch (AmazonS3Exception error) when (error.StatusCode == HttpStatusCode.NotFound && error.ErrorCode != "NoSuchBucket") { }
        }
        // Only an absent remote object falls back to pre-R2 local files; outages remain visible.
        try { return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 81920, true); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    public async Task DeleteAsync(string key, CancellationToken token)
    {
        var path = LocalPath(key);
        if (s3 is not null) await s3.DeleteObjectAsync(bucket, RemoteKey(key), token);
        if (File.Exists(path)) File.Delete(path);
    }

    /// <summary>Cleanup after a transaction must survive a disconnected request and cannot mask its outcome.</summary>
    public async Task CleanupAsync(string key)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try { await DeleteAsync(key, deadline.Token); }
        catch (Exception error) { logger.LogWarning(error, "Object cleanup failed for {ObjectKey}; an unreferenced object may remain", key); }
    }

    public void Dispose() => s3?.Dispose();
}
