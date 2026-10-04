using FirebaseAdmin;
using Google.Apis.Auth.OAuth2;
using Lifenizer.Api.Configuration;
using Lifenizer.Api.Data;
using Lifenizer.Api.Endpoints;
using Lifenizer.Api.Infrastructure;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

// Register services in logical groups
builder.Services.AddCoreServices();
builder.Services.AddDataServices(builder.Configuration);
builder.Services.AddAuthenticationServices(builder.Configuration);
builder.Services.AddImportServices();
builder.Services.AddPaymentServices(builder.Configuration);
builder.Services.AddConfiguredCors(builder.Configuration);

var app = builder.Build();

// Validate critical configuration after building the app
StartupConfigurationValidator.Validate(app.Configuration, app.Services.GetRequiredService<ILogger<Program>>(), app.Environment.IsDevelopment());

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.UseForwardedHeaders();
app.UseCors();
app.UseAuthentication();
app.UseAuthorization();
app.UseRateLimiter();

// Kestrel's default MaxRequestBodySize (~28.6 MB) is too small for base64-encoded audio uploads
// (a 30-minute recording is easily 30+ MB before the ~33% base64 inflation). Raise it just for the
// imports route; every other endpoint keeps the platform default.
var importsMaxRequestBytes = app.Configuration.GetValue<long?>("Imports:MaxRequestBytes") ?? 200_000_000L;
app.Use(async (context, next) =>
{
    if (context.Request.Path.StartsWithSegments("/api/imports", StringComparison.OrdinalIgnoreCase))
    {
        var sizeFeature = context.Features.Get<IHttpMaxRequestBodySizeFeature>();
        if (sizeFeature is { IsReadOnly: false })
        {
            sizeFeature.MaxRequestBodySize = importsMaxRequestBytes;
        }
    }

    await next();
});

// Apply database migrations
using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
    var logger = scope.ServiceProvider.GetRequiredService<ILogger<Program>>();

    try
    {
        logger.LogInformation("Applying database schema...");
        await DatabaseSchema.UpgradeAsync(db);
        logger.LogInformation("Database schema ready");
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Database migration failed. Ensure database is accessible and schema is valid");
        throw;
    }
}

// Initialize Firebase if credentials are available
if (app.Configuration.GetValue<bool>("Auth:EnableFirebase"))
{
    try
    {
        app.Logger.LogInformation("Initializing opt-in Firebase authentication");
        FirebaseApp.Create(new AppOptions { Credential = GoogleCredential.GetApplicationDefault() });
        app.Logger.LogInformation("Firebase initialized successfully");
    }
    catch (InvalidOperationException ex) when (ex.Message.Contains("already initialized", StringComparison.OrdinalIgnoreCase))
    {
        // Firebase was already initialized by the host
        app.Logger.LogInformation("Firebase was already initialized");
    }
    catch (Exception ex)
    {
        app.Logger.LogError(ex, "Failed to initialize Firebase");
        if (!app.Environment.IsDevelopment())
        {
            throw;
        }
    }
}
else
{
    app.Logger.LogInformation("Firebase authentication is disabled");
}

app.MapGet("/health", () => Results.Ok(new { status = "ok", app = "lifenizer-next" })).AllowAnonymous();
app.MapNativeClientEndpoints();
app.MapAuthEndpoints();
app.MapPairingEndpoints();
app.MapSyncEndpoints();
app.MapAnalysisEndpoints();
app.MapImportEndpoints();
app.MapUsageEndpoints();
app.MapImageEndpoints();
app.MapPremiumEndpoints();

app.Run();

public partial class Program;
