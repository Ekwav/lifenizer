using Lifenizer.Api.Services;

namespace Lifenizer.Api.Endpoints;

public static class TrainingEndpoints
{
    public static IEndpointRouteBuilder MapTrainingEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/training/tab").WithTags("Training").RequireAuthorization();
        group.MapGet("/notice", (TabTrainingClient tab, CancellationToken ct) => RespondAsync(async () => await tab.NoticeAsync(ct)));
        group.MapPost("/consents", (TabConsentRequest request, TabTrainingClient tab, CancellationToken ct) => RespondAsync(async () => await tab.ConsentAsync(request, ct)));
        group.MapPost("/corrections", (TabCorrectionRequest request, TabTrainingClient tab, CancellationToken ct) => RespondAsync(() => tab.CorrectAsync(request, ct)));
        group.MapPost("/consents/{id}/withdraw", (string id, TabWithdrawalRequest request, TabTrainingClient tab, CancellationToken ct) => RespondAsync(async () => await tab.WithdrawAsync(id, request, ct)));
        return app;
    }

    private static async Task<IResult> RespondAsync(Func<Task<object>> action)
    {
        try { return Results.Ok(await action()); }
        catch (ArgumentException exception) { return Results.BadRequest(new { error = "invalid_training_contribution", message = exception.Message }); }
        catch (Exception exception) when (exception is InvalidOperationException or HttpRequestException or System.Text.Json.JsonException or TaskCanceledException)
        { return Results.Json(new { error = "training_provider_unavailable", message = "TAB could not complete this request. Your local recording and correction were preserved." }, statusCode: 503); }
    }
}
