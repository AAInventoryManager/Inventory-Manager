import { defineConfig } from 'vitest/config';

const skipDb = process.env.VITEST_SKIP_DB === '1';

export default defineConfig({
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: ['./tests/setup/vitest.setup.ts'],
    globalSetup: skipDb ? undefined : './tests/setup/global-setup.ts',
    globalTeardown: skipDb ? undefined : './tests/setup/global-teardown.ts',
    include: ['tests/unit/**/*.test.ts', 'tests/integration/**/*.test.ts'],
    exclude: ['tests/e2e/**', 'node_modules/**'],
    testTimeout: 30000,
    hookTimeout: 60000,
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      reportsDirectory: './coverage',
      exclude: ['node_modules/**', 'tests/**', '**/*.config.*']
    },
    reporters: ['verbose'],
    pool: 'forks',
    poolOptions: {
      forks: {
        singleFork: true
      }
    }
  }
});
