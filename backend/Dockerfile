# ---------------------------------------------------------------------------- #
#  Build stage                                                                  #
# ---------------------------------------------------------------------------- #
FROM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS build
WORKDIR /src

# Copy solution and project files first so layer cache is reused when only
# source files change.
COPY LifenizerNext.slnx ./
COPY Lifenizer.Core/Lifenizer.Core.csproj  Lifenizer.Core/
COPY Lifenizer.Api/Lifenizer.Api.csproj    Lifenizer.Api/

RUN dotnet restore Lifenizer.Api/Lifenizer.Api.csproj

# Copy remaining source and publish a self-contained, trimmed release build.
COPY . .
RUN dotnet publish Lifenizer.Api/Lifenizer.Api.csproj \
      --configuration Release \
      --no-restore \
      --output /app/publish

# ---------------------------------------------------------------------------- #
#  Runtime stage                                                                #
# ---------------------------------------------------------------------------- #
FROM mcr.microsoft.com/dotnet/aspnet:10.0-alpine AS runtime

# Harden: create a dedicated non-root user and group.
RUN addgroup -S lifenizer && adduser -S -G lifenizer -u 1001 lifenizer

WORKDIR /app

# Copy published output.
COPY --from=build --chown=lifenizer:lifenizer /app/publish .

# Artifact storage: use an ephemeral tmpfs directory.
# In production, mount a persistent volume or configure object storage.
ENV Artifacts__StorePath=/tmp/lifenizer-artifacts
RUN mkdir -p /tmp/lifenizer-artifacts && \
    chown lifenizer:lifenizer /tmp/lifenizer-artifacts

# Listen on unprivileged port 8080.
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080

# Drop privileges.
USER lifenizer

# Health check for container orchestrators.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

ENTRYPOINT ["dotnet", "Lifenizer.Api.dll"]
