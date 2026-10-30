using System.Diagnostics;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Lifenizer.Core;

namespace Lifenizer.Tests;

// Opt in: SYNC_BACKEND_SIZES=1000,10000,100000 dotnet test --filter SyncLoadBenchmarkTests
// Real API/SQLite/local object files through TestServer; excludes WAN and S3 latency.
public sealed class SyncLoadBenchmarkTests
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    [Test]
    public async Task EncryptedConversationsThroughRealBackend()
    {
        var sizes = Environment.GetEnvironmentVariable("SYNC_BACKEND_SIZES");
        if (sizes is null) Assert.Ignore("Set SYNC_BACKEND_SIZES to opt in.");
        var results = new List<object>();
        foreach (var count in sizes!.Split(',').Select(int.Parse))
        {
            var root = Path.Combine(Path.GetTempPath(), $"sync-backend-load-{Guid.NewGuid():N}");
            Directory.CreateDirectory(root);
            try
            {
                await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
                {
                    ["ConnectionStrings:Lifenizer"] = $"Data Source={root}/vault.db",
                    ["Artifacts:StorePath"] = $"{root}/objects",
                    ["Payments:BaseUrl"] = "", ["Payments:FreePremiumEnabled"] = "true",
                    ["Logging:LogLevel:Default"] = "Warning"
                });
                using var client = factory.CreateClient();
                using var authResponse = await client.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest("benchmark@example.test"));
                authResponse.EnsureSuccessStatusCode();
                var auth = (await authResponse.Content.ReadFromJsonAsync<AuthResponse>())!;
                client.DefaultRequestHeaders.Authorization = new("Bearer", auth.AuthToken);
                using var activation = await client.PostAsync("/api/premium/activate", null);
                activation.EnsureSuccessStatusCode(); // Synthetic local grant permits >50 MiB.

                var expected = new Dictionary<Guid, string>();
                var key = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
                using var aes = new AesGcm(key, 16);
                var words = "We discussed the project schedule with Alice and Bob before planning dinner groceries travel weather music books software testing deployment meetings family exercise coffee garden budget research".Split(' ');
                SyncEnvelopeDto Envelope(int i, int revision = 1)
                {
                    var clear = JsonSerializer.SerializeToUtf8Bytes(new
                    {
                        id = $"conversation-{i}", title = $"Synthetic discussion {i}", source = "manual-text",
                        participantIds = Array.Empty<string>(),
                        segments = Enumerable.Range(0, 8).Select(j => new
                        {
                            id = $"message-{i}-{j}",
                            text = string.Join(' ', Enumerable.Range(0, 25).Select(k => words[(i + j * 25 + k) % words.Length])),
                            createdAt = "2026-10-28T00:00:00.000Z"
                        }).ToArray()
                    }, Json);
                    var nonce = RandomNumberGenerator.GetBytes(12);
                    var cipher = new byte[clear.Length];
                    var tag = new byte[16];
                    aes.Encrypt(nonce, clear, cipher, tag);
                    // VaultCrypto packs base64 ciphertext and tag in base64 JSON.
                    var packed = JsonSerializer.SerializeToUtf8Bytes(new { c = Convert.ToBase64String(cipher), m = Convert.ToBase64String(tag) }, Json);
                    var envelope = new SyncEnvelopeDto(Guid.NewGuid(), "synthetic-device", "conversation", $"conversation-{i}", "upsert", revision,
                        Convert.ToBase64String(packed), Convert.ToBase64String(nonce), "pbkdf2-sha256-aesgcm-v1", DateTimeOffset.UtcNow);
                    expected.Add(envelope.Id, envelope.CipherText);
                    return envelope;
                }

                long requestBytes = 0, responseBytes = 0;
                var pushes = 0;
                var pulls = 0;
                async Task Push(SyncEnvelopeDto[] batch)
                {
                    var body = JsonSerializer.Serialize(new PushSyncRequest(batch), Json);
                    requestBytes += Encoding.UTF8.GetByteCount(body);
                    using var content = new StringContent(body, Encoding.UTF8, "application/json");
                    using var response = await client.PostAsync("/api/sync/push", content);
                    response.EnsureSuccessStatusCode();
                    var bytes = await response.Content.ReadAsByteArrayAsync();
                    responseBytes += bytes.Length;
                    Assert.That(JsonSerializer.Deserialize<PushSyncResponse>(bytes, Json)!.Accepted, Is.EqualTo(batch.Length));
                    pushes++;
                }

                async Task<long> Pull(long cursor, int expectedCount)
                {
                    var seen = new HashSet<Guid>();
                    while (true)
                    {
                        using var response = await client.GetAsync($"/api/sync/pull?since={cursor}");
                        response.EnsureSuccessStatusCode();
                        var bytes = await response.Content.ReadAsByteArrayAsync();
                        responseBytes += bytes.Length;
                        var page = JsonSerializer.Deserialize<PullSyncResponse>(bytes, Json)!;
                        pulls++;
                        foreach (var envelope in page.Envelopes)
                        {
                            Assert.That(seen.Add(envelope.Id), Is.True);
                            Assert.That(envelope.CipherText, Is.EqualTo(expected[envelope.Id]));
                        }
                        Assert.That(page.Cursor, Is.GreaterThanOrEqualTo(cursor));
                        cursor = page.Cursor;
                        if (page.Envelopes.Count < 500) break;
                    }
                    Assert.That(seen, Has.Count.EqualTo(expectedCount));
                    return cursor;
                }

                async Task Measure(string operation, Func<Task> action)
                {
                    var before = (requestBytes, responseBytes, pushes, pulls);
                    var clock = Stopwatch.StartNew();
                    await action();
                    var result = new
                    {
                        conversations = count, wordsPerConversation = 200, operation,
                        elapsedMs = clock.Elapsed.TotalMilliseconds,
                        requestBodyBytes = requestBytes - before.requestBytes,
                        responseBodyBytes = responseBytes - before.responseBytes,
                        pushRequests = pushes - before.pushes, pullRequests = pulls - before.pulls,
                        processRssBytes = Process.GetCurrentProcess().WorkingSet64
                    };
                    results.Add(result);
                    TestContext.Progress.WriteLine($"SYNC_BACKEND_LOAD {JsonSerializer.Serialize(result)}");
                }

                async Task RecordStorage(string operation)
                {
                    var quota = await client.GetFromJsonAsync<JsonElement>("/api/premium/status");
                    results.Add(new { conversations = count, operation, envelopes = expected.Count,
                        usedBytes = quota.GetProperty("usedBytes").GetInt64(),
                        limitBytes = quota.GetProperty("limitBytes").GetInt64() });
                }

                await Measure("generate-encrypt-and-upload", async () =>
                {
                    for (var i = 0; i < count; i += 100)
                        await Push(Enumerable.Range(i, Math.Min(100, count - i)).Select(j => Envelope(j)).ToArray());
                });
                await RecordStorage("initial-charged-storage");
                long cursor = 0;
                await Measure("initial-pull", async () => { cursor = await Pull(0, count); });
                await Measure("upload-601-updates", async () =>
                {
                    for (var i = 0; i < 601; i += 100)
                        await Push(Enumerable.Range(i, Math.Min(100, 601 - i)).Select(j => Envelope(j, 2)).ToArray());
                });
                await RecordStorage("after-updates-charged-storage");
                await Measure("incremental-pull-601-updates", async () => { cursor = await Pull(cursor, 601); });
                await Measure("no-op-pull", async () => { cursor = await Pull(cursor, 0); });
                results.Add(new { conversations = count, operation = "persisted-backend-size",
                    bytes = Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).Sum(file => new FileInfo(file).Length),
                    objectFiles = Directory.EnumerateFiles($"{root}/objects", "*", SearchOption.AllDirectories).Count() });
            }
            finally
            {
                Directory.Delete(root, recursive: true);
                if (Environment.GetEnvironmentVariable("SYNC_BACKEND_OUTPUT") is { } output)
                    await File.WriteAllTextAsync(output, JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true }) + "\n");
            }
        }
    }
}
