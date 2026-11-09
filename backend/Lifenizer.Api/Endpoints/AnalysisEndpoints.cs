using Lifenizer.Core;
using Microsoft.AspNetCore.Mvc;

namespace Lifenizer.Api.Endpoints;

public static class AnalysisEndpoints
{
    public static IEndpointRouteBuilder MapAnalysisEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/analysis").RequireAuthorization().WithTags("Analysis");

        group.MapPost("/relations/extract", ([FromBody] RelationExtractionRequest request) =>
        {
            var relations = RelationExtractor.Extract(request);
            return Results.Ok(new RelationExtractionResponse(
                PlaintextCompute: true,
                Compromise: "This endpoint receives plaintext by explicit client action. Store returned relations as encrypted sync envelopes.",
                Relations: relations));
        });

        return app;
    }
}