// Every page of the dashboard and what it shows, over the seeded runs (seed.mjs): read only, so
// the desktop and phone projects both run it.
import { expect, test } from "@playwright/test";

const ids = () => JSON.parse(process.env.SEED);
const run = (id) => `/#/run/${encodeURIComponent(id)}`;

// The dashboard is connected (its event stream's snapshot arrived) and the page painted.
async function open(page, path) {
  await page.goto(path);
  await expect(page.locator("#conn-text")).toContainText("live", { timeout: 30_000 });
}

// Nothing is wider than the window: wide tables scroll inside their panel, not the page.
async function fits(page) {
  const [scroll, width] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  expect(scroll, "the page scrolls sideways").toBeLessThanOrEqual(width);
}

test.describe("navigation", () => {
  test("the header links every page and marks the one shown", async ({ page }) => {
    await open(page, "/");
    await expect(page.locator("#version")).toHaveText(/^v\d+\.\d+\.\d+/);
    for (const [name, label, hash] of [["artifacts", "Artifacts", "#/artifacts"], ["shots", "Screenshots", "#/shots"], ["device", "Device", "#/device"],
      ["maintenance", "Maintenance", "#/maintenance"], ["hub", "Hub", "#/hub"], ["runs", "Runs", "#/"]]) {
      const link = page.locator(`[data-nav="${name}"]`);
      await expect(link).toBeVisible();
      await expect(link).toHaveText(label);
      await link.click();
      await expect(page).toHaveURL(new RegExp(`${hash.replace("/", "\\/")}$`));
      await expect(link).toHaveClass(/active/);
      await expect(page.locator("[data-nav].active")).toHaveCount(1);
      await fits(page);
    }
  });

  test("a run's page keeps Runs marked; back returns to the history where it was left", async ({ page }) => {
    await open(page, "/");
    const row = page.locator(`tr[data-run="${ids()["ml-test-aborted"]}"]`);
    await row.scrollIntoViewIfNeeded();
    const y = await page.evaluate(() => window.scrollY);
    expect(y).toBeGreaterThan(0);
    await row.click();
    await expect(page.getByRole("link", { name: "← All runs" })).toBeVisible();
    await expect(page.locator('[data-nav="runs"]')).toHaveClass(/active/);
    expect(await page.evaluate(() => window.scrollY)).toBe(0);
    await page.goBack();
    await expect(row).toBeVisible();
    await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(y - 40);
  });

  test("a run that does not exist says so", async ({ page }) => {
    await open(page, run("20000101-000000-000000"));
    await expect(page.getByText("No such run.")).toBeVisible();
    await page.getByRole("link", { name: "All runs" }).click();
    await expect(page.getByRole("heading", { name: "History" })).toBeVisible();
  });

  test("the header shows the machine, its load, its free disk and the connection", async ({ page }) => {
    await open(page, "/");
    await expect(page.locator("#title")).toHaveText(/^testor · \S+/);
    await expect(page.locator("#disk")).toContainText("free");
    await expect(page.locator("#usage")).toContainText(/CPU \d+% · RAM \d+%/);
    await expect(page.locator("#conn")).toHaveClass(/live/);
    await expect(page).toHaveTitle(/\(1\) testor/);
  });
});

test.describe("runs", () => {
  test("tiles: running now, the last 24 hours, the last run, storage and the device", async ({ page }) => {
    await open(page, "/");
    const tile = (label) => page.locator(".tile", { has: page.locator(".label", { hasText: new RegExp(`^${label}$`) }) });
    await expect(tile("Running now").locator(".value")).toHaveText("1");
    await expect(tile("Last 24 h")).toContainText("passed");
    await expect(tile("Last 24 h")).toContainText("1 failed");
    await expect(tile("Last run")).toContainText("shop");
    await expect(tile("Screenshots").locator(".value")).toHaveText("7");
    await expect(tile("Artifacts").locator(".value")).toHaveText("2 runs");
    await expect(tile("Disk free").locator(".value")).toHaveText(/GB|MB|TB/);
    for (const label of ["CPU", "Memory", "Disk", "Network"]) await expect(page.locator(".dev-strip .tile", { hasText: label }).first()).toBeVisible();
    await page.locator(".dev-strip .tile").first().click();
    await expect(page).toHaveURL(/#\/device$/);
  });

  test("the run in progress: its spec count grows, its last lines, its usage, a cancel button", async ({ page }) => {
    await open(page, "/");
    const card = page.locator(`.card[data-run="${ids().live}"]`);
    await expect(card).toContainText("api");
    await expect(card).toContainText("npx vitest run --reporter=verbose");
    await expect(card.locator("pre")).toContainText("tests/orders/case-");
    await expect(card.getByRole("button", { name: "Cancel" })).toBeVisible();
    const specs = async () => Number((await card.locator(".meta", { hasText: "passed" }).textContent()).match(/(\d+) passed/)[1]);
    const before = await specs();
    await expect.poll(specs).toBeGreaterThan(before);
    await card.locator(".top b").click();
    await expect(page).toHaveURL(new RegExp(`#/run/${ids().live}$`));
  });

  test("latest by task: one chip per project and task, coloured by its status", async ({ page }) => {
    await open(page, "/");
    const board = page.locator(".board");
    for (const project of ["api", "docs", "ml", "shop"]) await expect(board.locator("b", { hasText: new RegExp(`^${project}$`) })).toBeVisible();
    await expect(board.locator(".chip")).toHaveCount(7);
    await board.locator(".chip", { hasText: "unit" }).click();
    await expect(page).toHaveURL(new RegExp(`#/run/${ids().unit}$`));
  });

  test("history: every finished run, filtered by project, type, status and text", async ({ page }) => {
    await open(page, "/");
    const rows = page.locator("tbody tr.click");
    await expect(rows).toHaveCount(14);
    await page.locator("#f-project").selectOption("shop");
    await expect(rows).toHaveCount(8);
    await page.locator("#f-kind").selectOption("e2e");
    await expect(rows).toHaveCount(6);
    await page.locator("#f-status").selectOption("failed");
    await expect(rows).toHaveCount(1);
    await page.locator("#f-status").selectOption("");
    await page.locator("#f-q").fill("shard=2");
    await expect(rows).toHaveCount(1);
    await expect(rows.first()).toContainText("shard 2/3");
    await page.locator("#f-q").fill("no run has this");
    await expect(page.getByText("No finished runs match the filters.")).toBeVisible();
    await page.locator("#f-q").fill("");
    for (const key of ["project", "kind"]) await page.locator(`#f-${key}`).selectOption("");
    await expect(rows).toHaveCount(14);
  });

  test("history rows: specs, coverage, mutation score, screenshots and batches", async ({ page }) => {
    await open(page, "/");
    const row = (id) => page.locator(`tr[data-run="${id}"]`);
    await expect(row(ids().e2e)).toContainText("5 passed");
    await expect(row(ids().e2e).locator(".tag", { hasText: "📷 5" })).toBeVisible();
    await expect(row(ids().unit)).toContainText("1 failed");
    await expect(row(ids().unit)).toContainText("exit 1");
    await expect(row(ids().unit).locator(".tag", { hasText: "☂" })).toContainText("87.71%");
    await expect(row(ids().mutation).locator(".tag", { hasText: "🧬" })).toContainText("80%");
    await expect(row(ids().batch)).toContainText("3 shards");
    await expect(row(ids()["docs-build-cancelled"]).locator(".badge")).toHaveText("cancelled");
    await expect(row(ids()["ml-test-aborted"]).locator(".badge")).toHaveText("aborted");
    await fits(page);
  });
});

test.describe("a run", () => {
  test("a passed end-to-end run: details, spec files, screenshots, a video, a report, the log", async ({ page }) => {
    await open(page, run(ids().e2e));
    await expect(page.locator(".kv")).toContainText("npx playwright test --reporter=list");
    await expect(page.locator(".kv")).toContainText("ada (as ci)");
    await expect(page.locator(".kv").getByRole("link", { name: "signed" })).toBeVisible();
    const specs = page.locator("h2", { hasText: "Spec files" }).locator("+ .panel tbody tr");
    await expect(specs).toHaveCount(5);
    await expect(specs.locator("img.thumb")).toHaveCount(5);
    await expect(page.locator("h2", { hasText: "Screenshots (5)" })).toBeVisible();
    const shots = page.locator(".grid .shot img");
    await expect(shots).toHaveCount(5);
    // The images are real and load.
    await expect.poll(() => shots.evaluateAll((list) => list.filter((i) => i.complete && i.naturalWidth > 0).length)).toBe(5);
    await expect(page.locator(".grid .shot", { hasText: "tests/checkout.spec.ts" })).toBeVisible();
    const artifacts = page.locator("#run-artifacts tbody tr");
    await expect(artifacts).toHaveCount(2);
    await expect(artifacts.getByRole("link", { name: "playwright-report" })).toHaveAttribute("href", /playwright-report\/index\.html/);
    await expect(page.locator("#run-artifacts video")).toHaveCount(1);
    await expect.poll(() => page.locator("#run-artifacts video").evaluate((v) => v.readyState)).toBeGreaterThan(0);
    await expect(page.locator("#log")).toContainText("9 passed (1.5m)");
    await expect(page.locator("#log .ok").first()).toBeVisible();
    await expect(page.locator("#log-head").getByRole("link", { name: "full log" })).toHaveAttribute("href", /\/log\?tail=/);
    await expect(page.getByRole("button", { name: "Delete run" })).toBeVisible();
    await fits(page);
  });

  test("a screenshot opens in the lightbox and closes with Escape or a click", async ({ page }) => {
    await open(page, run(ids().e2e));
    const lightbox = page.locator("#lightbox");
    await page.locator(".grid .shot img").first().click();
    await expect(lightbox).toHaveClass(/open/);
    await expect(lightbox.locator(".cap")).toContainText("test-finished-1.png");
    await expect(lightbox.getByRole("link", { name: "open" })).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(lightbox).not.toHaveClass(/open/);
    await page.locator("img.thumb").first().click();
    await expect(lightbox).toHaveClass(/open/);
    await lightbox.click({ position: { x: 5, y: 5 } });
    await expect(lightbox).not.toHaveClass(/open/);
  });

  test("a failed unit run: its error, coverage, the failing spec first, failures in red", async ({ page }) => {
    await open(page, run(ids().unit));
    await expect(page.locator(".badge").first()).toHaveText("failed");
    await expect(page.locator(".kv")).toContainText("1 test failed: tests/price.test.ts");
    await expect(page.locator("h2", { hasText: "Coverage" })).toContainText("87.71%");
    await expect(page.locator("h2", { hasText: "Coverage" }).locator("+ .panel tbody tr")).toHaveCount(4);
    const first = page.locator("h2", { hasText: "Spec files" }).locator("+ .panel tbody tr").first();
    await expect(first).toContainText("tests/price.test.ts");
    await expect(first.locator(".badge")).toHaveText("failed");
    await expect(page.locator("#log .fail", { hasText: "AssertionError" })).toBeVisible();
    await expect(page.getByRole("link", { name: "coverage" })).toBeVisible();
  });

  test("a mutation run: its score, each file, the surviving mutants", async ({ page }) => {
    await open(page, run(ids().mutation));
    const head = page.locator("h2", { hasText: "Mutation testing" });
    await expect(head).toContainText("80%");
    const panel = head.locator("+ .panel");
    await expect(panel.locator("dt", { hasText: "Killed" }).locator("+ dd")).toHaveText("8");
    await expect(panel.getByText("10 in 2 files")).toBeVisible();
    await expect(panel.getByRole("heading", { name: "Surviving mutants (2)" })).toBeVisible();
    await expect(panel.getByText("EqualityOperator")).toBeVisible();
    await expect(panel.locator("del", { hasText: "sum > 100" })).toBeVisible();
  });

  test("a batch: one bar per shard, each linking to its run", async ({ page }) => {
    await open(page, run(ids().batch));
    await expect(page.locator("h2", { hasText: "Shards" })).toContainText("3 · 46s wall clock");
    const rows = page.locator("h2", { hasText: "Shards" }).locator("+ .panel tbody tr");
    await expect(rows).toHaveCount(3);
    await expect(page.locator(".kv")).not.toContainText("pid");
    await rows.first().getByRole("link", { name: "#1" }).click();
    await expect(page.locator(".kv")).toContainText("--shard=1/3");
  });

  test("a run in progress: its log streams, it can be cancelled", async ({ page }) => {
    await open(page, run(ids().live));
    await expect(page.locator(".badge").first()).toHaveText("running");
    await expect(page.locator("#log-head")).toContainText("streaming");
    await expect(page.getByRole("button", { name: "Cancel run" })).toBeVisible();
    const lines = () => page.locator("#log div").count();
    const before = await lines();
    await expect.poll(lines).toBeGreaterThan(before);
    await expect(page.locator(".res")).toContainText("processes");
  });
});

test.describe("artifacts", () => {
  test("every run's artifacts, filtered by project, with the folder's use", async ({ page }) => {
    await open(page, "/#/artifacts");
    await expect(page.getByText("Artifacts folder")).toBeVisible();
    await expect(page.locator("#arts-view")).toContainText("2 runs · 4 files");
    const groups = page.locator("h3.group");
    await expect(groups).toHaveCount(2);
    await expect(page.getByRole("link", { name: "test-results/checkout-chromium/video.webm" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Clean up now" })).toBeVisible();
    await groups.first().getByRole("link").click();
    await expect(page).toHaveURL(/#\/run\//);
    await page.goBack();
    await page.locator("#a-project").selectOption("shop");
    await expect(groups).toHaveCount(2);
    await fits(page);
  });
});

test.describe("screenshots", () => {
  test("every screenshot, with its run and spec, filtered by project", async ({ page }) => {
    await open(page, "/#/shots");
    await expect(page.getByText("Screenshots folder")).toBeVisible();
    const cards = page.locator(".grid .shot");
    await expect(cards).toHaveCount(7);
    await expect(cards.filter({ hasText: "dropped in the folder" })).toHaveCount(1);
    await expect(cards.filter({ hasText: "failed" })).toContainText("tests/checkout.spec.ts");
    await page.locator("#s-project").selectOption("shop");
    await expect(cards).toHaveCount(6);
    await cards.first().locator("img").click();
    await expect(page.locator("#lightbox")).toHaveClass(/open/);
    await page.keyboard.press("Escape");
    await cards.first().getByRole("link").first().click();
    await expect(page).toHaveURL(/#\/run\//);
  });
});

test.describe("device", () => {
  test("the machine, its CPU cores, memory, storage, network and processes", async ({ page }) => {
    await open(page, "/#/device");
    for (const card of ["System", "CPU", "Memory", "GPU", "Storage", "Network"]) await expect(page.locator(".dev-card h3", { hasText: card })).toBeVisible();
    await expect(page.locator(".dev-card", { hasText: "System" })).toContainText("OS");
    await expect(page.locator(".core").first()).toBeVisible();
    const procs = page.locator("h2", { hasText: "Processes" }).locator("+ .panel tbody tr");
    await expect(procs.first()).toBeVisible();
    await page.locator('[data-sort="mem"]').click();
    await expect(page.locator('[data-sort="mem"]')).toHaveClass(/on/);
    const mem = await procs.locator("td:nth-child(4)").allTextContents();
    expect(mem.length).toBeGreaterThan(1);
    await page.locator('[data-sort="cpu"]').click();
    await expect(page.locator('[data-sort="cpu"]')).toHaveClass(/on/);
    await fits(page);
  });
});

test.describe("maintenance", () => {
  test("a scan measures what could be reclaimed, nothing is deleted", async ({ page }) => {
    test.setTimeout(120_000);
    await open(page, "/#/maintenance");
    // Not scanned yet, or scanned by the other project's run of this test.
    const scan = page.getByRole("button", { name: /^Scan( again)?$/ });
    await expect(scan).toBeEnabled();
    if ((await scan.textContent()) === "Scan") await expect(page.getByText("Not scanned yet.")).toBeVisible();
    await scan.click();
    await expect(page.locator("h2", { hasText: "Targets" })).toContainText("scanned", { timeout: 100_000 });
    const table = page.locator("#maint-view table");
    if (await table.count()) {
      await expect(page.getByRole("button", { name: "Clean chosen" })).toBeVisible();
      await expect(page.locator("#maint-view")).toContainText("chosen");
    } else {
      await expect(page.getByText("Nothing to reclaim.")).toBeVisible();
    }
    await expect(page.getByRole("button", { name: "Scan again" })).toBeVisible();
    await fits(page);
  });
});

test.describe("hub", () => {
  test("the testors of hub.json: one answering with its board, one that is down saying why", async ({ page }) => {
    await open(page, "/#/hub");
    await expect(page.locator("#hub-view")).toContainText("2 testors (1 answering)");
    const lab = page.locator("h3.group", { hasText: "linux-lab" });
    await expect(lab).toContainText("testor ");
    await expect(lab.locator(".tag", { hasText: "linux" })).toBeVisible();
    await expect(page.locator("#hub-view .chip", { hasText: "shop · e2e" })).toBeVisible();
    await expect(page.locator("h3.group", { hasText: "mac-mini" })).toContainText("it cannot be reached (connection refused)");
    await expect(page.locator("#hub-view .chip", { hasText: "shop · e2e" })).toHaveAttribute("href", /#\/run\//);
  });
});

test.describe("approvals", () => {
  test("what an AI agent asks waits on every page, naming the run", async ({ page }) => {
    for (const path of ["/", "/#/shots", "/#/device"]) {
      await open(page, path);
      const box = page.locator("#approvals");
      await expect(box).toBeVisible();
      await expect(box.locator(".item")).toHaveCount(2);
      await expect(box.locator(".item", { hasText: "cancel_run" })).toContainText("api · test");
      await expect(box.locator(".item", { hasText: "delete_run" })).toContainText("docs · build");
      await expect(box.getByRole("button", { name: "Approve" })).toHaveCount(2);
    }
  });
});
