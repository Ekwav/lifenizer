namespace Lifenizer.Core;

public sealed record UsageEventRequest(
    string Kind,
    double Quantity,
    string Unit,
    Dictionary<string, string>? Metadata = null);

public sealed record UsageEventResponse(Guid Id, DateTimeOffset CreatedAt);