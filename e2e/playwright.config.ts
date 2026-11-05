import { defineConfig, devices } from '@playwright/test';

const port = 8931;

/**
 * Tests a fresh build of the example: starting the web server builds it, on
 * every run, however the suite is started, and never reuses a server. A publish
 * gate must not pass on what an older build happened to do.
 */
export default defineConfig({
  testDir: './tests',
  // Each test starts Flutter and fills in its own calls: one at a time keeps
  // CPU pressure, and so timing, the same on every machine.
  workers: 1,
  fullyParallel: false,
  // A failure here is a bug or a flake to fix; neither is hidden by a retry.
  // All network is local (see tests/support.ts), so there is no public network
  // to retry for.
  retries: 0,
  forbidOnly: !!process.env.CI,
  timeout: 90_000,
  expect: { timeout: 15_000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: `http://localhost:${port}`,
    ...devices['Desktop Chrome'],
    viewport: { width: 1280, height: 800 },
    permissions: ['clipboard-read', 'clipboard-write'],
    serviceWorkers: 'block',
    trace: 'retain-on-failure',
  },
  webServer: {
    command:
      'cd ../example && flutter build web --profile --dart-define=PROXIE=true && ' +
      `cd ../e2e && npx http-server ../example/build/web -p ${port} -c-1 --silent`,
    url: `http://localhost:${port}`,
    reuseExistingServer: false,
    // The build, then the server.
    timeout: 300_000,
  },
});
