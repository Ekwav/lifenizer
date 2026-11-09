namespace Lifenizer.Api.Services;

/// <summary>The audio needs more memory than the server's whole audio budget; maps to a 400.</summary>
public sealed class AudioMemoryBudgetExceededException(long neededMb, long budgetMb)
    : InvalidOperationException($"Audio needs about {neededMb} MB of memory, more than the server's audio budget of {budgetMb} MB.");

/// <summary>
/// Process-wide async counting gate (in MB) for decoded audio held in memory.
/// Requests wait in FIFO order for budget; a request larger than the whole budget is rejected.
/// </summary>
public sealed class AudioMemoryBudget(long totalMb)
{
    private const int BytesPerMb = 1 << 20;
    private readonly object gate = new();
    private readonly LinkedList<Waiter> waiters = new();
    private long usedMb;

    public long TotalMb => totalMb;

    /// <summary>Highest simultaneous usage seen (for diagnostics and tests).</summary>
    public long PeakUsedMb { get; private set; }

    public static AudioMemoryBudget FromConfiguration(IConfiguration configuration) =>
        new(Math.Max(1, configuration.GetValue("Imports:AudioMemoryBudgetMb", 600L)));

    /// <summary>Waits until <paramref name="bytes"/> fit in the budget; dispose the lease to give them back.</summary>
    public async Task<IDisposable> AcquireAsync(long bytes, CancellationToken cancellationToken)
    {
        var mb = Math.Max(1, (bytes + BytesPerMb - 1) / BytesPerMb);
        if (mb > totalMb) throw new AudioMemoryBudgetExceededException(mb, totalMb);

        var waiter = new Waiter(mb);
        if (TryTakeOrEnqueue(waiter)) return new Lease(this, mb);

        using var registration = cancellationToken.Register(() => Abandon(waiter, cancellationToken));
        await waiter.Granted.Task;
        return new Lease(this, mb);
    }

    private bool TryTakeOrEnqueue(Waiter waiter)
    {
        lock (gate)
        {
            if (waiters.Count == 0 && usedMb + waiter.Mb <= totalMb)
            {
                Take(waiter.Mb);
                return true;
            }
            waiter.Node = waiters.AddLast(waiter);
            return false;
        }
    }

    private void Abandon(Waiter waiter, CancellationToken cancellationToken)
    {
        lock (gate)
        {
            if (waiter.Node is null) return;
            waiters.Remove(waiter.Node);
            waiter.Node = null;
            GrantWaiting();
        }
        waiter.Granted.TrySetCanceled(cancellationToken);
    }

    private void Release(long mb)
    {
        lock (gate)
        {
            usedMb -= mb;
            GrantWaiting();
        }
    }

    private void GrantWaiting()
    {
        while (waiters.First is { Value: var next } && usedMb + next.Mb <= totalMb)
        {
            waiters.RemoveFirst();
            next.Node = null;
            Take(next.Mb);
            next.Granted.TrySetResult();
        }
    }

    private void Take(long mb)
    {
        usedMb += mb;
        PeakUsedMb = Math.Max(PeakUsedMb, usedMb);
    }

    private sealed class Waiter(long mb)
    {
        public long Mb { get; } = mb;
        public LinkedListNode<Waiter>? Node { get; set; }
        public TaskCompletionSource Granted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class Lease(AudioMemoryBudget budget, long mb) : IDisposable
    {
        private int released;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref released, 1) == 0) budget.Release(mb);
        }
    }
}
