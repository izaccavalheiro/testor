import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, it } from "vitest";

// testor gives every recorded run a folder for images: $env:SCREENSHOT_DIR. A browser test
// would save its screenshots there (or under test-results/, which run.ps1 also collects).
it("saves a screenshot for the dashboard", () => {
  const dir = process.env.SCREENSHOT_DIR;
  if (!dir) return; // not run through testor
  // A 1x1 PNG, so the dashboard has something to preview.
  const png = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
    "base64",
  );
  writeFileSync(join(dir, "screenshot.test-example.png"), png);
  expect(png.length).toBeGreaterThan(0);
});
