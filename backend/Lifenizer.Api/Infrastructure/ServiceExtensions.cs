using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.RateLimiting;
using System.Text.Json;
using System.Text.Json.Serialization;
using Coflnet.Payments.Client.Api;
using Lifenizer.Api.Data;
using Lifenizer.Api.Endpoints;
using Lifenizer.Api.Security;
using Lifenizer.Api.Services;
using Lifenizer.Api.Services.Parsers;
using Microsoft.EntityFrameworkCore;

namespace Lifenizer.Api.Infrastructure;

/// <summary>
/// Service registration extension methods for organizing dependency injection setup in Program.cs.
/// </summary>
public static class ServiceExtensions
{
    /// <summary>
    /// Registers core infrastructure services: JSON serialization, HTTP context, caching, and OpenAPI.
    /// </summary>
    public static IServiceCollection AddCoreServices(this IServiceCollection services)
    {
        services.ConfigureHttpJsonOptions(options =>
        {
            options.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
            options.SerializerOptions.Converters.Add(new JsonStringEnumConverter());
        });

        services.AddOpenApi();
        services.AddHttpContextAccessor();
        services.AddMemoryCache();
        services.AddHttpClient("imports").ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });

        // CPU-based whisper-trained transcription is slow for longer recordings, so this client
        // gets a generous timeout distinct from the "imports" client used by fast provider calls.
        services.AddHttpClient(WhisperTranscriptionClient.HttpClientName, client =>
        {
            client.Timeout = TimeSpan.FromMinutes(10);
        }).ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });

        return services;
    }

    /// <summary>
    /// Registers database-related services with validation and migration support.
    /// </summary>
    public static IServiceCollection AddDataServices(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddDbContext<LifenizerDbContext>(options =>
        {
            var connectionString = configuration.GetConnectionString("Lifenizer")
                ?? $"Data Source={Path.Combine(AppContext.BaseDirectory, "lifenizer-next.db")}";
            options.UseSqlite(connectionString);
        });

        return services;
    }

    /// <summary>
    /// Registers authentication and authorization services with JWT validation.
    /// </summary>
    public static IServiceCollection AddAuthenticationServices(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddLifenizerAuth(configuration);
        services.AddScoped<IPasswordHasher<UserAccount>, PasswordHasher<UserAccount>>();
        services.Configure<PasswordHasherOptions>(options => options.IterationCount = 220_000);
        services.AddRateLimiter(options =>
        {
            options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
            options.AddPolicy("account-auth", context => RateLimitPartition.GetFixedWindowLimiter(
                context.Connection.RemoteIpAddress?.ToString() ?? "local",
                _ => new FixedWindowRateLimiterOptions { PermitLimit = 10, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
        });
        services.AddScoped<ClaimsPrincipalUser>();

        return services;
    }

    /// <summary>
    /// Registers import-related services: orchestrator, parsers, and HTTP clients.
    /// Registers all format-specific parsers with the ParserRegistry for extensible import handling.
    /// </summary>
    public static IServiceCollection AddImportServices(this IServiceCollection services)
    {
        services.AddScoped<UserAccountService>();
        services.AddScoped<PlainImapImportClient>();
        services.AddScoped<WhisperTranscriptionClient>();
        services.AddScoped<ProviderHttpImportClient>();
        services.AddScoped<ImportOrchestrator>();

        // Register ParserRegistry and all import format parsers
        services.AddSingleton(provider => BuildParserRegistry());

        return services;
    }

    /// <summary>
    /// Builds the parser registry with all supported import format parsers.
    /// </summary>
    private static ParserRegistry BuildParserRegistry()
    {
        var registry = new ParserRegistry();

        // Simple text parsers
        registry.Register(new ManualTextParser());
        registry.Register(new ScannedPdfParser());
        registry.Register(new RecordingTranscriptParser());

        // Chat line parsers
        registry.Register(new WhatsAppParser());
        registry.Register(new IMessageParser());

        // Chat JSON parsers
        registry.Register(new SignalParser());
        registry.Register(new TelegramParser());
        registry.Register(new DiscordParser());
        registry.Register(new SlackParser());
        registry.Register(new TeamsParser());

        // Social media parsers
        registry.Register(new FacebookMessengerParser());
        registry.Register(new InstagramParser());

        // Email parser
        registry.Register(new MboxParser());

        // Development/version control parsers
        registry.Register(new GitParser());

        // Browser/web parsers
        registry.Register(new BrowserHistoryParser());
        registry.Register(new BrowserCaptureParser());
        registry.Register(new BookmarksParser());
        registry.Register(new GoogleSearchHistoryParser());

        // Data backup parsers
        registry.Register(new LifenizerBackupParser());
        registry.Register(new TranscriptParser());

        return registry;
    }

    /// <summary>
    /// Registers payment and premium-related services.
    /// </summary>
    public static IServiceCollection AddPaymentServices(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddScoped<PremiumService>();

        // Coflnet Payments API client – gracefully skipped when Payments:BaseUrl is absent.
        var paymentsBaseUrl = configuration["Payments:BaseUrl"];
        if (!string.IsNullOrWhiteSpace(paymentsBaseUrl))
        {
            services.AddHttpClient<IUserApi, UserApi>(client =>
            {
                client.BaseAddress = new Uri(paymentsBaseUrl.TrimEnd('/') + "/");
            });
        }
        else
        {
            // Register a no-op stub so DI resolves without crashing when payments is unconfigured.
            services.AddSingleton<IUserApi>(new UserApi("http://localhost:8000"));
        }

        return services;
    }

    /// <summary>
    /// Registers CORS policy with specific methods, headers, and origins.
    /// </summary>
    public static IServiceCollection AddConfiguredCors(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddCors(options =>
        {
            options.AddDefaultPolicy(policy =>
            {
                var origins = configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? new[]
                {
                    "http://localhost:5173",
                    "http://localhost:5174",
                    "http://127.0.0.1:5173",
                    "http://127.0.0.1:5174"
                };

                policy
                    .WithOrigins(origins)
                    .WithMethods("GET", "POST", "PUT", "DELETE", "OPTIONS")
                    .WithHeaders("Content-Type", "Authorization")
                    .WithExposedHeaders("X-Total-Count")
                    .AllowCredentials()
                    .SetPreflightMaxAge(TimeSpan.FromHours(24));
            });
        });

        return services;
    }
}
