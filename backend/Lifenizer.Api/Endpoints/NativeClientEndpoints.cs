namespace Lifenizer.Api.Endpoints;

public static class NativeClientEndpoints
{
    public static IEndpointRouteBuilder MapNativeClientEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/downloads/lifenizer.apk", (IWebHostEnvironment environment, HttpResponse response) =>
        {
            response.Headers.CacheControl = "no-store";
            var path = Path.Combine(environment.ContentRootPath, "downloads", "lifenizer.apk");
            return File.Exists(path)
                ? Results.File(path, "application/vnd.android.package-archive", "lifenizer.apk", enableRangeProcessing: true)
                : Results.NotFound();
        }).AllowAnonymous();
        return app;
    }
}
