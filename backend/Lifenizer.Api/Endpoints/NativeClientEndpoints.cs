namespace Lifenizer.Api.Endpoints;

public static class NativeClientEndpoints
{
    private static readonly (string Name, string ContentType)[] Downloads =
    [
        ("lifenizer.apk", "application/vnd.android.package-archive"),
        ("lifenizer-linux-x64.tar.gz", "application/gzip"),
        ("lifenizer-history-sync-chromium.zip", "application/zip"),
        ("lifenizer-history-sync-firefox.zip", "application/zip")
    ];

    public static IEndpointRouteBuilder MapNativeClientEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/downloads", (IWebHostEnvironment environment, IConfiguration configuration, HttpResponse response) =>
        {
            response.Headers.CacheControl = "no-store";
            var root = DownloadRoot(environment, configuration);
            return Results.Ok(Downloads.Select(file => new
            {
                name = file.Name,
                url = $"/downloads/{file.Name}",
                available = File.Exists(Path.Combine(root, file.Name))
            }));
        }).AllowAnonymous();

        foreach (var file in Downloads)
        {
            app.MapGet($"/downloads/{file.Name}", (IWebHostEnvironment environment, IConfiguration configuration, HttpResponse response) =>
            {
                response.Headers.CacheControl = "no-store";
                response.Headers.XContentTypeOptions = "nosniff";
                var path = Path.Combine(DownloadRoot(environment, configuration), file.Name);
                return File.Exists(path)
                    ? Results.File(path, file.ContentType, file.Name, enableRangeProcessing: true)
                    : Results.NotFound(new { message = "This download is not available yet. Please try again later." });
            }).AllowAnonymous();
        }

        foreach (var asset in new[] { "index.html", "extension.html", "styles.css", "landing.js", "security.html", "privacy.html", "imports.html", "hosted.html" })
        {
            IResult Serve(HttpResponse response)
            {
                response.Headers.CacheControl = "no-cache";
                response.Headers.XContentTypeOptions = "nosniff";
                response.Headers.ContentSecurityPolicy = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'";
                var stream = typeof(NativeClientEndpoints).Assembly.GetManifestResourceStream($"Lifenizer.Landing.{asset}")!;
                return Results.Stream(stream, asset.EndsWith(".css") ? "text/css" : asset.EndsWith(".js") ? "text/javascript" : "text/html");
            }
            app.MapGet($"/{asset}", Serve).AllowAnonymous();
            if (asset == "index.html") app.MapGet("/", Serve).AllowAnonymous();
            if (asset == "extension.html") app.MapGet("/extension", Serve).AllowAnonymous();
        }
        return app;
    }

    private static string DownloadRoot(IWebHostEnvironment environment, IConfiguration configuration)
    {
        var root = configuration["Downloads:Path"] ?? Path.Combine(environment.ContentRootPath, "downloads");
        var current = Path.Combine(root, "current");
        return Directory.Exists(current) ? current : root;
    }
}
