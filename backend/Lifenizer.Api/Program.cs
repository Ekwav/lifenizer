using System.Text.Json;
using System.Text.Json.Serialization;
using Coflnet.Payments.Client.Api;
using FirebaseAdmin;
using Google.Apis.Auth.OAuth2;
using Lifenizer.Api.Data;
using Lifenizer.Api.Endpoints;
using Lifenizer.Api.Security;
using Lifenizer.Api.Services;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
    options.SerializerOptions.Converters.Add(new JsonStringEnumConverter());
});

builder.Services.AddOpenApi();
builder.Services.AddHttpContextAccessor();
builder.Services.AddMemoryCache();
builder.Services.AddHttpClient("imports");
builder.Services.AddScoped<ClaimsPrincipalUser>();
builder.Services.AddScoped<UserAccountService>();
builder.Services.AddScoped<PlainImapImportClient>();
builder.Services.AddScoped<ProviderHttpImportClient>();
builder.Services.AddScoped<ImportOrchestrator>();
builder.Services.AddScoped<PremiumService>();
builder.Services.AddLifenizerAuth(builder.Configuration);

// Coflnet Payments API client – gracefully skipped when Payments:BaseUrl is absent.
var paymentsBaseUrl = builder.Configuration["Payments:BaseUrl"];
if (!string.IsNullOrWhiteSpace(paymentsBaseUrl))
{
    builder.Services.AddHttpClient<IUserApi, UserApi>(client =>
    {
        client.BaseAddress = new Uri(paymentsBaseUrl.TrimEnd('/') + "/");
    });
}
else
{
    // Register a no-op stub so DI resolves without crashing when payments is unconfigured.
    builder.Services.AddSingleton<IUserApi>(new UserApi("http://localhost:8000"));
}

builder.Services.AddDbContext<LifenizerDbContext>(options =>
{
    var connectionString = builder.Configuration.GetConnectionString("Lifenizer")
        ?? $"Data Source={Path.Combine(AppContext.BaseDirectory, "lifenizer-next.db")}";
    options.UseSqlite(connectionString);
});

builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy => policy
        .WithOrigins(
            "http://localhost:5173",
            "http://localhost:5174",
            "http://127.0.0.1:5173",
            "http://127.0.0.1:5174")
        .AllowAnyHeader()
        .AllowAnyMethod());
});

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.UseCors();
app.UseAuthentication();
app.UseAuthorization();

using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
    await db.Database.EnsureCreatedAsync();
}

if (Environment.GetEnvironmentVariable("GOOGLE_APPLICATION_CREDENTIALS") is { Length: > 0 })
{
    try
    {
        FirebaseApp.Create(new AppOptions { Credential = GoogleCredential.GetApplicationDefault() });
    }
    catch (InvalidOperationException)
    {
        // Firebase was already initialized by the host.
    }
}
else
{
    app.Logger.LogWarning("GOOGLE_APPLICATION_CREDENTIALS is not set; /api/auth/firebase requires FirebaseAdmin initialization.");
}

app.MapGet("/health", () => Results.Ok(new { status = "ok", app = "lifenizer-next" })).AllowAnonymous();
app.MapAuthEndpoints();
app.MapSyncEndpoints();
app.MapAnalysisEndpoints();
app.MapImportEndpoints();
app.MapUsageEndpoints();
app.MapImageEndpoints();
app.MapPremiumEndpoints();

app.Run();

public partial class Program;

