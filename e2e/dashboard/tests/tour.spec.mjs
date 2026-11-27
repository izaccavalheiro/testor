// The images of the documentation's dashboard tour (website/docs/features/dashboard.md), taken
// from the seeded testor: DOCS_SHOTS=1 scripts/dashboard-e2e.sh writes them to
// website/static/img/dashboard. Without DOCS_SHOTS, skipped.
import { fileURLToPath } from "node:url";
import { devices, expect, test } from "@playwright/test";

const OUT = fileURLToPath(new URL("../../../website/static/img/dashboard/", import.meta.url));
const ids = () => JSON.parse(process.env.SEED);
test.skip(!process.env.DOCS_SHOTS, "DOCS_SHOTS=1 writes the documentation's images");
test.describe.configure({ mode: "serial" });

async function open(page, path) {
  await page.goto(path);
  await expect(page.locator("#conn-text")).toContainText("live", { timeout: 30_000 });
  // Sparklines and the run's stream fill in over a second or two.
  await page.waitForTimeout(2500);
}
const shot = (target, name, options = {}) => target.screenshot({ path: `${OUT}${name}.png`, animations: "disabled", ...options });

test("runs", async ({ page }) => {
  await open(page, "/");
  await shot(page, "runs");
  await page.locator("h2", { hasText: "History" }).scrollIntoViewIfNeeded();
  await shot(page, "history");
  await shot(page.locator("#approvals"), "approvals");
});

test("a run", async ({ page }) => {
  await open(page, `/#/run/${ids().e2e}`);
  await shot(page, "run");
  await page.locator("h2", { hasText: "Screenshots" }).scrollIntoViewIfNeeded();
  await shot(page, "run-screenshots");
  await page.locator(".grid .shot img").nth(2).click();
  await shot(page, "lightbox");
  await page.keyboard.press("Escape");
  await open(page, `/#/run/${ids().unit}`);
  await page.locator("h2", { hasText: "Coverage" }).scrollIntoViewIfNeeded();
  await shot(page, "run-coverage");
  await open(page, `/#/run/${ids().mutation}`);
  await page.locator("h2", { hasText: "Mutation testing" }).scrollIntoViewIfNeeded();
  await shot(page, "run-mutation");
  await open(page, `/#/run/${ids().batch}`);
  await shot(page, "run-batch");
  await open(page, `/#/run/${ids().live}`);
  await shot(page, "run-live");
});

test("the other pages", async ({ page }) => {
  test.setTimeout(150_000);
  for (const [name, path] of [["artifacts", "/#/artifacts"], ["screenshots", "/#/shots"], ["hub", "/#/hub"]]) {
    await open(page, path);
    await shot(page, name);
  }
  // The machine that took them is nobody's business: its model, CPU, GPU and disks are masked.
  await open(page, "/#/device");
  const card = (name) => page.locator(".dev-card", { has: page.locator("h3", { hasText: name }) });
  await shot(page, "device", {
    maskColor: "#e3e6ea",
    mask: [card("System").locator("dt:text-is('Machine') + dd"), card("CPU").locator(":scope > div").first(),
      card("Memory").locator("dt:text-is('Modules') + dd"), card("GPU").locator(":scope > div"), card("Storage").locator(".facts")],
  });
  await open(page, "/#/maintenance");
  await page.getByRole("button", { name: /^Scan( again)?$/ }).click();
  await expect(page.locator("h2", { hasText: "Targets" })).toContainText("scanned", { timeout: 100_000 });
  await shot(page, "maintenance");
});

test("on a phone", async ({ browser }) => {
  const context = await browser.newContext({ ...devices["Pixel 7"], httpCredentials: { username: process.env.TESTOR_USER, password: process.env.TESTOR_PASSWORD }, colorScheme: "light" });
  const page = await context.newPage();
  await open(page, `${process.env.TESTOR_URL}/`);
  await shot(page, "phone-runs");
  await context.close();
});

test("in dark mode", async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, httpCredentials: { username: process.env.TESTOR_USER, password: process.env.TESTOR_PASSWORD }, colorScheme: "dark" });
  const page = await context.newPage();
  await open(page, `${process.env.TESTOR_URL}/`);
  await shot(page, "dark");
  await context.close();
});
