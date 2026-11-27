// The dashboard's end-to-end tests (scripts/dashboard-e2e.sh starts and seeds testor). Every
// test keeps a screenshot of its end, as testor keeps a run's screenshots: run through testor,
// they appear with the run (test-results/<test>/test-finished-1.png).
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "tests",
  globalSetup: "./global-setup.mjs",
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  timeout: 30_000,
  expect: { timeout: 10_000 },
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: {
    baseURL: process.env.TESTOR_URL,
    httpCredentials: { username: process.env.TESTOR_USER ?? "ada", password: process.env.TESTOR_PASSWORD ?? "" },
    colorScheme: "light",
    screenshot: { mode: "on", fullPage: true },
    trace: "retain-on-failure",
    video: "retain-on-failure",
  },
  projects: [
    // Every page and what it shows, read only, on a desktop and on a phone.
    { name: "desktop", testMatch: /pages\.spec/, use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } } },
    { name: "phone", testMatch: /pages\.spec/, use: { ...devices["Pixel 7"] } },
    // The documentation's tour (website/docs/features/dashboard.md): its images, DOCS_SHOTS=1 only.
    { name: "docs", testMatch: /tour\.spec/, use: { ...devices["Desktop Chrome"], viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 } },
    // What changes testor: approving, cancelling, deleting, cleaning; once, after the others.
    // Not retried: each step uses up what the seed made (an approval, the live run).
    { name: "actions", testMatch: /actions\.spec/, retries: 0, dependencies: ["desktop", "phone", "docs"], use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } } },
  ],
});
