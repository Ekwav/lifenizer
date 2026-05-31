import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 120_000,
  expect: { timeout: 20_000 },
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1:5174',
    trace: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  webServer: [
    {
      command: 'rm -f lifenizer-e2e.db lifenizer-e2e.db-shm lifenizer-e2e.db-wal && ASPNETCORE_URLS=http://127.0.0.1:5075 ConnectionStrings__Lifenizer="Data Source=lifenizer-e2e.db" Auth__AllowDevLogin=true Jwt__Secret=test-secret-for-lifenizer-next-playwright dotnet run --project ../backend/Lifenizer.Api/Lifenizer.Api.csproj --no-launch-profile',
      url: 'http://127.0.0.1:5075/health',
      timeout: 120_000,
      reuseExistingServer: !process.env.CI,
    },
    {
      command: 'node serve-static.mjs ../app/build/web',
      url: 'http://127.0.0.1:5174',
      timeout: 30_000,
      reuseExistingServer: !process.env.CI,
    },
  ],
});
