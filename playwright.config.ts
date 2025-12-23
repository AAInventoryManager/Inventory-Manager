import { defineConfig, devices } from '@playwright/test';
import dotenv from 'dotenv';

const envPath = process.env.CI ? '.env.test.ci' : '.env.test';
dotenv.config({ path: envPath });

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: [['html', { outputFolder: 'playwright-report' }], ['list']],
  use: {
    baseURL: process.env.TEST_APP_URL || 'http://127.0.0.1:5173',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'on-first-retry',
    actionTimeout: 10000,
    navigationTimeout: 30000
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] }
    }
  ],
  webServer: {
    command: process.env.TEST_SERVER_CMD || 'node dev-server.mjs --host 127.0.0.1 --port 5173',
    url: process.env.TEST_APP_URL || 'http://127.0.0.1:5173',
    reuseExistingServer: !process.env.CI,
    timeout: 120000
  }
});
