import { resolve } from 'node:path';
import { defineConfig, devices } from '@playwright/test';

const whisperUrl = process.env.WHISPER_URL ?? 'http://127.0.0.1:19000';
// Absolute, because the backend resolves relative SQLite paths against its project directory.
const database = resolve(__dirname, 'lifenizer-e2e.db');

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
      command: `rm -f "${database}" "${database}-shm" "${database}-wal" && ASPNETCORE_URLS=http://127.0.0.1:5075 ConnectionStrings__Lifenizer="Data Source=${database}" Auth__AllowDevLogin=true Jwt__Secret=test-secret-for-lifenizer-next-playwright Whisper__BaseUrl=${whisperUrl} dotnet run --project ../backend/Lifenizer.Api/Lifenizer.Api.csproj --no-launch-profile`,
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
