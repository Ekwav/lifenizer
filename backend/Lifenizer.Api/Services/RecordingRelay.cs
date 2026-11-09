using System.Threading.Channels;

namespace Lifenizer.Api.Services;

/// <summary>Single-instance, transient delivery between authenticated devices of a vault.</summary>
public sealed class RecordingRelay
{
    public sealed record Request(Guid RequestId, string ConversationId);
    private sealed record Pending(Guid VaultId, TaskCompletionSource<byte[]> Completion)
    {
        public bool Claimed { get; set; }
    }
    private readonly object gate = new();
    private readonly Dictionary<Guid, (Guid VaultId, Channel<Request> Channel)> providers = new();
    private readonly Dictionary<Guid, Pending> pending = new();
    public SemaphoreSlim Transfers { get; } = new(2);
    public SemaphoreSlim Downloads { get; } = new(2);

    public (Guid Id, ChannelReader<Request> Reader)? Subscribe(Guid vaultId)
    {
        lock (gate)
        {
            if (providers.Count >= 64 || providers.Values.Count(p => p.VaultId == vaultId) >= 4) return null;
            var id = Guid.NewGuid();
            var channel = Channel.CreateBounded<Request>(4);
            providers.Add(id, (vaultId, channel));
            return (id, channel.Reader);
        }
    }

    public void Unsubscribe(Guid id)
    {
        lock (gate)
        {
            if (!providers.Remove(id, out var provider)) return;
            provider.Channel.Writer.TryComplete();
            if (providers.Values.All(p => p.VaultId != provider.VaultId))
                foreach (var item in pending.Values.Where(p => p.VaultId == provider.VaultId))
                    item.Completion.TrySetException(new IOException("Recording provider disconnected"));
        }
    }

    public async Task<byte[]?> RequestAsync(Guid vaultId, string conversationId, TimeSpan timeout, CancellationToken token)
    {
        var request = new Request(Guid.NewGuid(), conversationId);
        var item = new Pending(vaultId, new(TaskCreationOptions.RunContinuationsAsynchronously));
        lock (gate)
        {
            var targets = providers.Values.Where(p => p.VaultId == vaultId).ToArray();
            if (targets.Length == 0) return null;
            if (pending.Count >= 2) throw new InvalidOperationException("Recording relay busy");
            pending.Add(request.RequestId, item);
            if (targets.Count(p => p.Channel.Writer.TryWrite(request)) == 0)
            {
                pending.Remove(request.RequestId);
                return null;
            }
        }
        try { return await item.Completion.Task.WaitAsync(timeout, token); }
        finally { lock (gate) pending.Remove(request.RequestId); }
    }

    public bool TryClaim(Guid vaultId, Guid requestId)
    {
        lock (gate)
        {
            if (!pending.TryGetValue(requestId, out var item) || item.VaultId != vaultId || item.Claimed || item.Completion.Task.IsCompleted) return false;
            item.Claimed = true;
            return true;
        }
    }

    public bool Complete(Guid vaultId, Guid requestId, byte[] bytes)
    {
        lock (gate)
            return pending.TryGetValue(requestId, out var item) && item.VaultId == vaultId && item.Completion.TrySetResult(bytes);
    }

    public void Release(Guid vaultId, Guid requestId)
    {
        lock (gate)
            if (pending.TryGetValue(requestId, out var item) && item.VaultId == vaultId) item.Claimed = false;
    }
}
