import { resolve } from 'node:path';
import { defineConfig, devices } from '@playwright/test';

const whisperUrl = process.env.WHISPER_URL ?? 'http://127.0.0.1:19000';
// Absolute, because the backend resolves relative SQLite paths against its project directory.
const database = resolve(__dirname, 'lifenizer-e2e.db');

export default defineConfig({
  testDir: './tests',
  workers: 2,
  timeout: 120_000,
  expect: { timeout: 20_000 },
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1:5175',
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
      command: `rm -f "${database}" "${database}-shm" "${database}-wal" && dotnet run --project ../backend/Lifenizer.Api/Lifenizer.Api.csproj --no-launch-profile`,
      env: {
        ASPNETCORE_URLS: 'http://127.0.0.1:5076',
        ConnectionStrings__Lifenizer: `Data Source=${database}`,
        Cors__AllowedOrigins__0: 'http://127.0.0.1:5175',
        Auth__AllowDevLogin: 'true',
        Jwt__Secret: 'test-secret-for-lifenizer-next-playwright',
        Whisper__BaseUrl: whisperUrl,
      },
      url: 'http://127.0.0.1:5076/health',
      timeout: 120_000,
      reuseExistingServer: false,
    },
    {
      command: 'node serve-static.mjs ../app/build/web',
      env: { PORT: '5175' },
      url: 'http://127.0.0.1:5175',
      timeout: 30_000,
      reuseExistingServer: false,
    },
  ],
});
