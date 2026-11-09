using System.Globalization;

namespace Lifenizer.Api.Configuration;

/// <summary>
/// Validates critical startup configuration and provides helpful error messages.
/// </summary>
public static class StartupConfigurationValidator
{
    /// <summary>
    /// Validates all required configuration values and logs clear error messages.
    /// </summary>
    /// <exception cref="InvalidOperationException">Thrown when critical configuration is missing or invalid.</exception>
    public static void Validate(IConfiguration configuration, ILogger logger, bool isDevelopment = false)
    {
        var errors = new List<string>();

        // Validate JWT Secret
        var jwtSecret = configuration["Jwt:Secret"];
        if (string.IsNullOrWhiteSpace(jwtSecret))
        {
            errors.Add("Missing configuration: Jwt:Secret (required for authentication)");
        }
        else if (jwtSecret.Length < 32)
        {
            errors.Add($"Jwt:Secret must be at least 32 characters (currently {jwtSecret.Length}). Set in appsettings.json or environment variable 'Jwt__Secret'");
        }

        if (!isDevelopment && jwtSecret == "replace-this-development-secret-with-a-host-secret-please")
            errors.Add("Set a private Jwt:Secret before running in production; the shipped development example is unsafe.");

        // Validate Premium Products (these are product identifiers/SKUs, not prices)
        var premiumId = configuration["Products:Premium"];
        if (string.IsNullOrWhiteSpace(premiumId))
        {
            errors.Add("Missing configuration: Products:Premium (product ID/SKU for premium tier)");
        }

        var premiumPlusId = configuration["Products:PremiumPlus"];
        if (string.IsNullOrWhiteSpace(premiumPlusId))
        {
            errors.Add("Missing configuration: Products:PremiumPlus (product ID/SKU for premium plus tier)");
        }

        // Validate Artifacts Store Path
        var artifactsPath = configuration["Artifacts:StorePath"];
        if (!string.IsNullOrWhiteSpace(artifactsPath))
        {
            try
            {
                if (!Path.IsPathRooted(artifactsPath) && !artifactsPath.StartsWith(".", StringComparison.Ordinal))
                {
                    // Allow relative paths, but warn
                    logger.LogWarning("Artifacts:StorePath is relative '{Path}'. Consider using an absolute path", artifactsPath);
                }
            }
            catch (ArgumentException)
            {
                errors.Add($"Artifacts:StorePath contains invalid path characters: '{artifactsPath}'");
            }
        }

        // Validate Database Connection
        var connectionString = configuration.GetConnectionString("Lifenizer");
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            logger.LogInformation("ConnectionString 'Lifenizer' not configured. Using default SQLite database in application directory");
        }

        if (errors.Count > 0)
        {
            var message = "Critical configuration errors:\n  - " + string.Join("\n  - ", errors);
            logger.LogError("{Message}", message);
            throw new InvalidOperationException(message);
        }

        logger.LogInformation("Startup configuration validation passed");
    }
}
